import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum ReaderOrientation {
  system([]),
  portrait([DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]),
  landscape([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  const ReaderOrientation(this.orientations);

  final List<DeviceOrientation> orientations;
}

mixin ReaderOrientationState<T extends StatefulWidget> on State<T> {
  // Route transitions can keep an old reader alive after a new one opens.
  static final _activeReaders = <ReaderOrientationState>[];

  ReaderOrientation _readerOrientation = ReaderOrientation.system;

  ReaderOrientation get readerOrientation => _readerOrientation;

  late final bool _orientationEnabled;

  @override
  void initState() {
    super.initState();
    _orientationEnabled = defaultTargetPlatform == TargetPlatform.android;
    if (_orientationEnabled) {
      _activeReaders.add(this);
      _applyOrientation(ReaderOrientation.system);
    }
  }

  void cycleReaderOrientation() {
    if (!_orientationEnabled || !identical(_activeReaders.lastOrNull, this)) {
      return;
    }
    setState(() {
      _readerOrientation = switch (_readerOrientation) {
        ReaderOrientation.system => ReaderOrientation.portrait,
        ReaderOrientation.portrait => ReaderOrientation.landscape,
        ReaderOrientation.landscape => ReaderOrientation.system,
      };
    });
    _applyOrientation(_readerOrientation);
  }

  void _applyOrientation(ReaderOrientation orientation) {
    unawaited(SystemChrome.setPreferredOrientations(orientation.orientations));
  }

  @override
  void dispose() {
    if (_orientationEnabled) {
      final wasActive = identical(_activeReaders.lastOrNull, this);
      _activeReaders.remove(this);
      if (wasActive) {
        // An empty list releases the last reader's lock to the operating system.
        _applyOrientation(
          _activeReaders.lastOrNull?.readerOrientation ??
              ReaderOrientation.system,
        );
      }
    }
    super.dispose();
  }
}
