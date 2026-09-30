import 'package:flutter/services.dart';

const _volumeChannel = EventChannel('venera/volume');

/// Android emits 1 for volume up and 2 for volume down.
Stream<Object?> readerVolumeEvents() => _volumeChannel.receiveBroadcastStream();
