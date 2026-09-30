import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera_next/features/reader/orientation_controller.dart';
import 'package:venera_next/foundation/log.dart';

export 'orientation_controller.dart' show ReaderOrientation;

/// Install outside the Navigator so overlapping reader routes share ownership.
class ReaderOrientationScope extends StatefulWidget {
  const ReaderOrientationScope({super.key, required this.child});
  final Widget child;
  @override
  State<ReaderOrientationScope> createState() => _ReaderOrientationScopeState();
}

class _ReaderOrientationScopeState extends State<ReaderOrientationScope> {
  late final coordinator = ReaderOrientationCoordinator(
    apply: (orientation) =>
        SystemChrome.setPreferredOrientations(switch (orientation) {
          ReaderOrientation.system => const [],
          ReaderOrientation.portrait => const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ],
          ReaderOrientation.landscape => const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ],
        }),
    onError: (error, stack) =>
        Log.error('Reader', 'Failed to apply orientation: $error', stack),
  );

  @override
  Widget build(BuildContext context) =>
      _OrientationProvider(coordinator: coordinator, child: widget.child);

  @override
  void dispose() {
    coordinator.dispose();
    super.dispose();
  }
}

class _OrientationProvider extends InheritedWidget {
  const _OrientationProvider({required this.coordinator, required super.child});
  final ReaderOrientationCoordinator coordinator;
  @override
  bool updateShouldNotify(_OrientationProvider oldWidget) =>
      !identical(coordinator, oldWidget.coordinator);
}

mixin ReaderOrientationState<T extends StatefulWidget> on State<T> {
  ReaderOrientationCoordinator? _coordinator;
  ReaderOrientationHandle? _orientation;
  ReaderOrientation get readerOrientation =>
      _orientation?.orientation ?? ReaderOrientation.system;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final provider = context
        .dependOnInheritedWidgetOfExactType<_OrientationProvider>();
    if (provider == null) {
      throw StateError('ReaderOrientationScope must wrap the Navigator');
    }
    if (identical(provider.coordinator, _coordinator)) return;
    _orientation?.dispose();
    _coordinator = provider.coordinator;
    _orientation = _coordinator!.acquire();
  }

  void cycleReaderOrientation() {
    if (_orientation?.cycle() ?? false) setState(() {});
  }

  @override
  void dispose() {
    _orientation?.dispose();
    super.dispose();
  }
}
