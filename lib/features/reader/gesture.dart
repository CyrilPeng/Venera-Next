import 'gesture_port.dart';
import 'image_action.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/components/menu.dart';
import 'package:venera_next/features/reader/clipboard_image.dart';
import 'package:venera_next/features/reader/reader_page.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/file_type.dart';
import 'package:venera_next/features/reader/reader_tap_scope.dart';
import 'package:venera_next/foundation/translations.dart';

class ReaderGestureDetector extends StatefulWidget {
  const ReaderGestureDetector({super.key, required this.child});

  final Widget child;

  @override
  State<ReaderGestureDetector> createState() => ReaderGestureDetectorState();
}

class ReaderGestureDetectorState extends State<ReaderGestureDetector>
    implements ReaderGesturePort {
  late TapGestureRecognizer _tapGestureRecognizer;

  static const _kDoubleTapMaxTime = Duration(milliseconds: 200);

  static const _kLongPressMinTime = Duration(milliseconds: 250);

  static const _kDoubleTapMaxDistanceSquared = 20.0 * 20.0;

  static const _kTapToTurnPagePercent = 0.3;

  final _dragListeners = <ReaderDragListener>[];

  int fingers = 0;

  late ReaderState reader;
  late final void Function() _detachFromScaffold;

  bool ignoreNextTag = false;

  @override
  void ignoreNextTap() {
    ignoreNextTag = true;
  }

  @override
  void cancelPendingTap() {
    _previousEvent = null;
  }

  @override
  void clearIgnoreNextTap() {
    ignoreNextTag = false;
  }

  @override
  void initState() {
    _tapGestureRecognizer = TapGestureRecognizer()
      ..onTapUp = onTapUp
      ..onSecondaryTapUp = (details) {
        onSecondaryTapUp(details.globalPosition);
      };
    super.initState();
    final scaffold = context.readerScaffold;
    scaffold.gestureDetectorState = this;
    _detachFromScaffold = () {
      if (identical(scaffold.gestureDetectorState, this)) {
        scaffold.gestureDetectorState = null;
      }
    };
    reader = context.reader;
  }

  @override
  void dispose() {
    _detachFromScaffold();
    _tapGestureRecognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.position == Offset.zero) {
          _previousEvent = null;
          return;
        }
        fingers++;
        reader.autoReading.pause('pointer', true);
        if (ignoreNextTag) {
          ignoreNextTag = false;
          return;
        }
        _lastTapPointer = event.pointer;
        _lastTapMoveDistance = Offset.zero;
        _tapGestureRecognizer.addPointer(event);
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onStart?.call(event.position);
          }
          _dragInProgress = false;
        }
        Future.delayed(_kLongPressMinTime, () {
          if (mounted && _lastTapPointer == event.pointer && fingers == 1) {
            if (_lastTapMoveDistance!.distanceSquared < 20.0 * 20.0) {
              onLongPressedDown(event.position);
              _longPressInProgress = true;
            } else {
              _dragInProgress = true;
              for (var dragListener in _dragListeners) {
                dragListener.onStart?.call(event.position);
                dragListener.onMove?.call(_lastTapMoveDistance!);
              }
            }
          }
        });
      },
      onPointerMove: (event) {
        if (event.pointer == _lastTapPointer) {
          _lastTapMoveDistance = event.delta + _lastTapMoveDistance!;
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onMove?.call(event.delta);
          }
        }
      },
      onPointerUp: (event) {
        fingers--;
        if (fingers <= 0) reader.autoReading.pause('pointer', false);
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onEnd?.call();
          }
          _dragInProgress = false;
        }
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
      },
      onPointerCancel: (event) {
        fingers--;
        if (fingers <= 0) reader.autoReading.pause('pointer', false);
        if (_longPressInProgress) {
          onLongPressedUp(event.position);
        }
        if (_dragInProgress) {
          for (var dragListener in _dragListeners) {
            dragListener.onEnd?.call();
          }
          _dragInProgress = false;
        }
        _lastTapPointer = null;
        _lastTapMoveDistance = null;
      },
      onPointerSignal: (event) {
        reader.autoReading.stop();
        if (event is PointerScrollEvent) {
          onMouseWheel(event.scrollDelta.dy > 0);
        }
      },
      child: ReaderTapScope(ignoreNextTap: ignoreNextTap, child: widget.child),
    );
  }

  void onMouseWheel(bool forward) {
    if (HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    if (context.reader.mode.key.startsWith('gallery')) {
      if (forward) {
        if (!context.reader.toNextPage() &&
            !context.reader.isLastChapterOfGroup) {
          context.reader.toNextChapter();
        }
      } else {
        if (!context.reader.toPrevPage() &&
            !context.reader.isFirstChapterOfGroup) {
          context.reader.toPrevChapter(toLastPage: true);
        }
      }
    }
  }

  TapUpDetails? _previousEvent;

  int? _lastTapPointer;

  Offset? _lastTapMoveDistance;

  bool _longPressInProgress = false;

  bool _dragInProgress = false;

  bool get _enableDoubleTapToZoom => reader.preferences.enableDoubleTapToZoom;

  void onTapUp(TapUpDetails event) {
    if (event.globalPosition == Offset.zero &&
        event.localPosition == Offset.zero) {
      _previousEvent = null;
      return;
    }
    if (_longPressInProgress) {
      _longPressInProgress = false;
      return;
    }
    final location = event.globalPosition;
    if (!_enableDoubleTapToZoom) {
      onTap(location);
      return;
    }
    final previousLocation = _previousEvent?.globalPosition;
    if (previousLocation != null) {
      if ((location - previousLocation).distanceSquared <
          _kDoubleTapMaxDistanceSquared) {
        onDoubleTap(location);
        _previousEvent = null;
        return;
      } else {
        onTap(previousLocation);
      }
    }
    _previousEvent = event;
    Future.delayed(_kDoubleTapMaxTime, () {
      if (_previousEvent == event) {
        onTap(location);
        _previousEvent = null;
      }
    });
  }

  void onTap(Offset location) {
    if (reader.imageViewController!.handleOnTap(location)) {
      return;
    } else if (context.readerScaffold.isOpen) {
      context.readerScaffold.openOrClose();
    } else {
      // Don't open toolbar on chapter comments page
      if (reader.isOnChapterCommentsPage) {
        return;
      }
      if (reader.preferences.enableTapToTurnPages) {
        bool isLeft = false, isRight = false, isTop = false, isBottom = false;
        final width = context.width;
        final height = context.height;
        final x = location.dx;
        final y = location.dy;
        if (x < width * _kTapToTurnPagePercent) {
          isLeft = true;
        } else if (x > width * (1 - _kTapToTurnPagePercent)) {
          isRight = true;
        }
        if (y < height * _kTapToTurnPagePercent) {
          isTop = true;
        } else if (y > height * (1 - _kTapToTurnPagePercent)) {
          isBottom = true;
        }
        bool isCenter = false;
        var prev = () => context.reader.toPrevPage();
        var next = () => context.reader.toNextPage();
        if (reader.preferences.reverseTapToTurnPages) {
          prev = () => context.reader.toNextPage();
          next = () => context.reader.toPrevPage();
        }
        switch (context.reader.mode) {
          case ReaderMode.galleryLeftToRight:
          case ReaderMode.continuousLeftToRight:
            if (isLeft) {
              prev();
            } else if (isRight) {
              next();
            } else {
              isCenter = true;
            }
          case ReaderMode.galleryRightToLeft:
          case ReaderMode.continuousRightToLeft:
            if (isLeft) {
              next();
            } else if (isRight) {
              prev();
            } else {
              isCenter = true;
            }
          case ReaderMode.galleryTopToBottom:
          case ReaderMode.continuousTopToBottom:
          case ReaderMode.waterfallTopToBottom:
            if (isTop) {
              prev();
            } else if (isBottom) {
              next();
            } else {
              isCenter = true;
            }
        }
        if (!isCenter) {
          return;
        }
      }
      context.readerScaffold.openOrClose();
    }
  }

  void onDoubleTap(Offset location) {
    context.reader.imageViewController?.handleDoubleTap(location);
  }

  void onSecondaryTapUp(Offset location) {
    showMenuX(context, location, [
      MenuEntry(
        icon: Icons.settings,
        text: "Settings".tl,
        onClick: () {
          context.readerScaffold.openSetting();
        },
      ),
      MenuEntry(
        icon: Icons.menu,
        text: "Chapters".tl,
        onClick: () {
          context.readerScaffold.openChapterDrawer();
        },
      ),
      MenuEntry(
        icon: Icons.fullscreen,
        text: "Fullscreen".tl,
        onClick: () {
          context.reader.fullscreen();
        },
      ),
      MenuEntry(
        icon: Icons.exit_to_app,
        text: "Exit".tl,
        onClick: () {
          context.pop();
        },
      ),
      if (App.isDesktop && !reader.isLoading)
        MenuEntry(
          icon: Icons.copy,
          text: "Copy Image".tl,
          onClick: () => copyImage(location),
        ),
      if (!reader.isLoading)
        MenuEntry(
          icon: Icons.download_outlined,
          text: "Save Image".tl,
          onClick: () => saveImage(location),
        ),
    ]);
  }

  String? _longPressAction;

  void onLongPressedUp(Offset location) {
    if (_longPressAction == 'zoom') {
      reader.imageViewController?.handleLongPressUp(location);
    }
    _longPressAction = null;
  }

  void onLongPressedDown(Offset location) {
    _longPressAction = reader.preferences.longPressAction;
    switch (_longPressAction) {
      case 'zoom':
        reader.imageViewController?.handleLongPressDown(location);
      case 'autoReading':
        reader.autoReading.toggle();
      default:
        break;
    }
  }

  @override
  void addDragListener(ReaderDragListener listener) {
    _dragListeners.add(listener);
  }

  @override
  void removeDragListener(ReaderDragListener listener) {
    _dragListeners.remove(listener);
  }

  Future<void> _useImage(
    Offset location,
    Future<void> Function(Uint8List) consume,
  ) async {
    if (!mounted || !reader.mounted) return;
    final viewport = reader.imageViewController;
    if (viewport == null) return;
    final images = reader.images;
    final chapter = reader.chapter;
    await useReaderImage(
      read: () => viewport.getImageByOffset(location),
      isCurrent: () =>
          mounted &&
          reader.mounted &&
          identical(viewport, reader.imageViewController) &&
          identical(images, reader.images) &&
          chapter == reader.chapter,
      consume: consume,
      onMissing: () {
        if (mounted) context.showMessage(message: "No Image".tl);
      },
      onError: (error) {
        if (mounted) context.showMessage(message: error.toString());
      },
    );
  }

  Future<void> copyImage(Offset location) =>
      _useImage(location, writeImageToClipboard);

  Future<void> saveImage(Offset location) => _useImage(location, (image) async {
    final filetype = detectFileType(image);
    await saveFile(filename: "image${filetype.ext}", data: image);
  });
}
