import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_next/features/reader/volume_controller.dart';

final _owners = Expando<_VolumeChannelOwner>();

ReaderVolumeConnection connectReaderVolume(void Function(Object?) onEvent) {
  final messenger = ServicesBinding.instance.defaultBinaryMessenger;
  final owner = _owners[messenger] ??= _VolumeChannelOwner(messenger);
  return owner.connect(onEvent);
}

class _VolumeChannelOwner {
  _VolumeChannelOwner(BinaryMessenger messenger)
    : channel = MethodChannel(
        'venera/volume',
        const StandardMethodCodec(),
        messenger,
      ) {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'event') throw MissingPluginException();
      final arguments = call.arguments;
      if (arguments is! Map) return;
      final lease = leases[arguments['token']];
      if (lease != null && lease.accepting) lease.onEvent(arguments['value']);
    });
  }

  final MethodChannel channel;
  final leases = <String, _VolumeLease>{};

  _VolumeLease connect(void Function(Object?) onEvent) {
    final lease = _VolumeLease(this, const Uuid().v4(), onEvent);
    leases[lease.token] = lease;
    lease.start();
    return lease;
  }
}

class _VolumeLease implements ReaderVolumeConnection {
  _VolumeLease(this.owner, this.token, this.onEvent);
  final _VolumeChannelOwner owner;
  final String token;
  final void Function(Object?) onEvent;
  final _activation = Completer<void>();
  bool accepting = true;
  bool _released = false;
  Future<void>? _closing;

  @override
  Future<void> get ready => _activation.future;

  void start() {
    // Retain failed activations until cancellation acknowledges this token.
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    owner.channel
        .invokeMethod<void>('listen', {'token': token})
        .then(
          (_) => _activation.complete(),
          onError: (Object error, StackTrace stack) =>
              _activation.completeError(error, stack),
        );
  }

  @override
  Future<void> closeAndWait() {
    accepting = false;
    if (_closing case final closing?) return closing;
    if (_released) return Future.value();
    final closing = _closing = _close();
    unawaited(
      closing.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          _closing = null;
        },
      ),
    );
    return closing;
  }

  Future<void> _close() async {
    try {
      await ready;
    } catch (_) {
      // The activation caller retains its error. Cancel acknowledgement proves
      // release even when the activation acknowledgement was lost.
    }
    await owner.channel.invokeMethod<void>('cancel', {'token': token});
    _released = true;
    owner.leases.remove(token);
  }
}
