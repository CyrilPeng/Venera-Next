import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:venera_next/features/reader/reader_tap_scope.dart';
import 'package:venera_next/features/reader/image_position.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/image_provider/base_image_provider.dart';
import 'package:venera_next/foundation/translations.dart';
import 'image_dimensions.dart';
import 'auto_reading.dart';
import 'white_border_crop.dart';

class ComicImage extends StatefulWidget {
  /// Modified from flutter Image
  ComicImage({
    required ImageProvider image,
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.medium,
    this.isAntiAlias = false,
    this.splitWideImage = false,
    this.splitWideImageInvert = false,
    this.showImageDimensions = false,
    this.whiteBorderCrop,
    this.cropIdentity,
    Map<String, String>? headers,
    int? cacheWidth,
    int? cacheHeight,
    this.onInit,
    this.onDispose,
  }) : image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, image),
       assert(cacheWidth == null || cacheWidth > 0),
       assert(cacheHeight == null || cacheHeight > 0);

  final ImageProvider image;

  final String? semanticLabel;

  final bool excludeFromSemantics;

  final double? width;

  final double? height;

  final bool gaplessPlayback;

  final bool matchTextDirection;

  final Rect? centerSlice;

  final ImageRepeat repeat;

  final AlignmentGeometry alignment;

  final BoxFit? fit;

  final BlendMode? colorBlendMode;

  final FilterQuality filterQuality;

  final Animation<double>? opacity;

  final Color? color;

  final bool isAntiAlias;

  final bool splitWideImage;

  final bool splitWideImageInvert;
  final bool showImageDimensions;
  final ReaderWhiteBorderCrop? whiteBorderCrop;
  final Object? cropIdentity;

  final void Function(State<ComicImage> state)? onInit;

  final void Function(State<ComicImage> state)? onDispose;

  static void clear() => ComicImageState.clear();

  @override
  State<ComicImage> createState() => ComicImageState();
}

@visibleForTesting
bool shouldSplitWideImage(Size imageSize) => imageSize.width > imageSize.height;

@visibleForTesting
Size splitWideImageDisplaySize(Size imageSize) {
  if (!shouldSplitWideImage(imageSize)) {
    return imageSize;
  }
  return Size(imageSize.width / 2, imageSize.height * 2);
}

@visibleForTesting
List<Rect> splitWideImageSourceRects(Size imageSize, {required bool invert}) {
  return [
    for (final slice in splitWideImageSlices(invert: invert))
      Rect.fromLTWH(
        imageSize.width * slice.sourceLeft,
        0,
        imageSize.width * slice.sourceWidth,
        imageSize.height,
      ),
  ];
}

class ComicImageState extends State<ComicImage> with WidgetsBindingObserver {
  ImageStream? _imageStream;
  ImageInfo? _imageInfo;
  ImageChunkEvent? _loadingProgress;
  ImageChunkEvent? _pendingProgress;
  int? _progressFrame;
  bool _isListeningToStream = false;
  late bool _invertColors;
  int? _frameNumber;
  bool _wasSynchronouslyLoaded = false;
  late DisposableBuildContext<State<ComicImage>> _scrollAwareContext;
  Object? _lastException;
  ImageStreamCompleterHandle? _completerHandle;
  ui.Rect? _cropRect;
  int _cropGeneration = 0;
  bool _cropPending = false;

  AutoReadingImageState get autoReadingImageState => _lastException != null
      ? AutoReadingImageState.failed
      : _imageInfo != null && _frameNumber != null
      ? AutoReadingImageState.ready
      : AutoReadingImageState.loading;

  bool get readyForAutoReading =>
      autoReadingImageState == AutoReadingImageState.ready;

  bool get visibleInReader {
    if (!mounted) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final bounds = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    final visible = bounds.intersect(screen);
    return visible.width > 1 && visible.height > 1;
  }

  static final Map<int, Size> _cache = {};

  static void clear() => _cache.clear();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollAwareContext = DisposableBuildContext<State<ComicImage>>(this);
    widget.whiteBorderCrop?.addListener(_requestCrop);
    widget.onInit?.call(this);
  }

  @override
  void dispose() {
    assert(_imageStream != null);
    _cancelProgressUpdate();
    WidgetsBinding.instance.removeObserver(this);
    _stopListeningToStream();
    _completerHandle?.dispose();
    _scrollAwareContext.dispose();
    widget.whiteBorderCrop?.removeListener(_requestCrop);
    _cropGeneration++;
    _replaceImage(info: null);
    widget.onDispose?.call(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    _updateInvertColors();
    _resolveImage();

    if (TickerMode.valuesOf(context).enabled) {
      _listenToStream();
    } else {
      _stopListeningToStream(keepStreamAlive: true);
    }

    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(ComicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _resolveImage();
    }
    if (widget.whiteBorderCrop != oldWidget.whiteBorderCrop ||
        widget.cropIdentity != oldWidget.cropIdentity) {
      oldWidget.whiteBorderCrop?.removeListener(_requestCrop);
      widget.whiteBorderCrop?.addListener(_requestCrop);
      _cropGeneration++;
      _cropPending = false;
      _cropRect = null;
      _requestCrop();
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    super.didChangeAccessibilityFeatures();
    setState(() {
      _updateInvertColors();
    });
  }

  @override
  void reassemble() {
    _resolveImage(); // in case the image cache was flushed
    super.reassemble();
  }

  bool containsPoint(Offset point) {
    if (!mounted) {
      return false;
    }
    var renderBox = context.findRenderObject() as RenderBox;
    var localPoint = renderBox.globalToLocal(point);
    return renderBox.paintBounds.contains(localPoint);
  }

  void _updateInvertColors() {
    _invertColors =
        MediaQuery.maybeInvertColorsOf(context) ??
        SemanticsBinding.instance.accessibilityFeatures.invertColors;
  }

  void _resolveImage() {
    final ScrollAwareImageProvider provider = ScrollAwareImageProvider<Object>(
      context: _scrollAwareContext,
      imageProvider: widget.image,
    );
    final ImageStream newStream = provider.resolve(
      createLocalImageConfiguration(
        context,
        size: widget.width != null && widget.height != null
            ? Size(widget.width!, widget.height!)
            : null,
      ),
    );
    _updateSourceStream(newStream);
  }

  ImageStreamListener? _imageStreamListener;

  ImageStreamListener _getListener({bool recreateListener = false}) {
    if (_imageStreamListener == null || recreateListener) {
      _lastException = null;
      _imageStreamListener = ImageStreamListener(
        _handleImageFrame,
        onChunk: _handleImageChunk,
        onError: (Object error, StackTrace? stackTrace) {
          _cancelProgressUpdate();
          setState(() {
            _lastException = error;
          });
        },
      );
    }
    return _imageStreamListener!;
  }

  void _handleImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    _cancelProgressUpdate();
    setState(() {
      _replaceImage(info: imageInfo);
      _loadingProgress = null;
      _lastException = null;
      _frameNumber = _frameNumber == null ? 0 : _frameNumber! + 1;
      _wasSynchronouslyLoaded = _wasSynchronouslyLoaded | synchronousCall;
    });
    _requestCrop();
  }

  void _requestCrop() {
    final crop = widget.whiteBorderCrop;
    final image = _imageInfo?.image;
    final completer = _imageStream?.completer;
    final decoded = completer is ImageDecodeInfo
        ? completer as ImageDecodeInfo
        : null;
    final decodeIdentity = decoded?.decodeIdentity;
    // Animated images retain their complete frames and stable geometry.
    if (!mounted ||
        crop == null ||
        image == null ||
        _cropPending ||
        _cropRect != null ||
        decoded?.frameCount != 1 ||
        decodeIdentity == null) {
      return;
    }
    final generation = ++_cropGeneration;
    final retryRevision = crop.retryRevision;
    _cropPending = true;
    // A new decode after eviction/retry can contain different pixels even when
    // the provider key and dimensions match. Cache only that decode's bounds.
    final result = crop.detect(image, (
      widget.cropIdentity ?? widget.image,
      decodeIdentity,
    ));
    // Cached detections may complete synchronously during widget updates.
    Future<ui.Rect?>.value(result).then((rect) {
      if (!mounted ||
          generation != _cropGeneration ||
          widget.whiteBorderCrop != crop ||
          _imageInfo?.image != image) {
        return;
      }
      setState(() {
        _cropPending = false;
        _cropRect = rect;
      });
      if (rect == null && retryRevision != crop.retryRevision) {
        _requestCrop();
      }
    });
  }

  void _handleImageChunk(ImageChunkEvent event) {
    _pendingProgress = event;
    _progressFrame ??= SchedulerBinding.instance.scheduleFrameCallback((_) {
      _progressFrame = null;
      final progress = _pendingProgress;
      _pendingProgress = null;
      if (!mounted || progress == null) return;
      setState(() {
        _loadingProgress = progress;
        _lastException = null;
      });
    });
  }

  void _cancelProgressUpdate() {
    if (_progressFrame case final frame?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
    }
    _progressFrame = null;
    _pendingProgress = null;
  }

  void _replaceImage({required ImageInfo? info}) {
    final ImageInfo? oldImageInfo = _imageInfo;
    final samePixels =
        info != null &&
        oldImageInfo != null &&
        info.image.isCloneOf(oldImageInfo.image);
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => oldImageInfo?.dispose(),
    );
    _imageInfo = info;
    _cropGeneration++;
    _cropPending = false;
    if (!samePixels) _cropRect = null;
  }

  // Updates _imageStream to newStream, and moves the stream listener
  // registration from the old stream to the new stream (if a listener was
  // registered).
  void _updateSourceStream(ImageStream newStream) {
    if (_imageStream?.key == newStream.key) {
      return;
    }
    _cancelProgressUpdate();

    if (_isListeningToStream) {
      _imageStream!.removeListener(_getListener());
    }

    if (!widget.gaplessPlayback) {
      setState(() {
        _replaceImage(info: null);
      });
    }

    setState(() {
      _loadingProgress = null;
      _lastException = null;
      _frameNumber = null;
      _wasSynchronouslyLoaded = false;
    });

    _imageStream = newStream;
    if (_isListeningToStream) {
      _imageStream!.addListener(_getListener());
    }
  }

  void _listenToStream() {
    if (_isListeningToStream) {
      return;
    }

    _imageStream!.addListener(_getListener());
    _completerHandle?.dispose();
    _completerHandle = null;

    _isListeningToStream = true;
  }

  /// Stops listening to the image stream, if this state object has attached a
  /// listener.
  ///
  /// If the listener from this state is the last listener on the stream, the
  /// stream will be disposed. To keep the stream alive, set `keepStreamAlive`
  /// to true, which create [ImageStreamCompleterHandle] to keep the completer
  /// alive and is compatible with the [TickerMode] being off.
  void _stopListeningToStream({bool keepStreamAlive = false}) {
    _cancelProgressUpdate();
    if (!_isListeningToStream) {
      return;
    }

    if (keepStreamAlive &&
        _completerHandle == null &&
        _imageStream?.completer != null) {
      _completerHandle = _imageStream!.completer!.keepAlive();
    }

    _imageStream!.removeListener(_getListener());
    _isListeningToStream = false;
  }

  Rect _sourceRect(Size imageSize) {
    final crop = _cropRect;
    if (crop == null) return Offset.zero & imageSize;
    if (widget.splitWideImage && shouldSplitWideImage(imageSize)) {
      // Preserve the original spread's center when the two margins differ.
      final margin = math.min(crop.left, imageSize.width - crop.right);
      return Rect.fromLTRB(
        margin,
        0,
        imageSize.width - margin,
        imageSize.height,
      );
    }
    return crop;
  }

  @override
  Widget build(BuildContext context) {
    if (_lastException != null) {
      // display error and retry button on screen
      return SizedBox(
        height: widget.height == null ? 300 : null,
        width: widget.width == null ? 300 : null,
        child: Center(
          child: SizedBox(
            height: 300,
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Text(_lastException.toString(), maxLines: 3),
                  ),
                ),
                const SizedBox(height: 4),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Listener(
                    onPointerDown: (details) {
                      ReaderTapScope.maybeOf(context)?.ignoreNextTap();
                      _cancelProgressUpdate();
                      setState(() {
                        _loadingProgress = null;
                        _lastException = null;
                      });
                      _resolveImage();
                    },
                    child: SizedBox(
                      width: 84,
                      height: 36,
                      child: Center(
                        child: Text(
                          "Retry".tl,
                          style: TextStyle(color: Colors.blue),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constrains) {
        var width = widget.width;
        var height = widget.height;

        if (_imageInfo != null) {
          // Record the height and the width of the image
          _cache[widget.image.hashCode] = Size(
            _imageInfo!.image.width.toDouble(),
            _imageInfo!.image.height.toDouble(),
          );
        }

        Size? cacheSize = _cache[widget.image.hashCode];
        if (cacheSize != null) {
          final sourceSize = _sourceRect(cacheSize).size;
          final displaySize =
              widget.splitWideImage && shouldSplitWideImage(cacheSize)
              ? Size(sourceSize.width / 2, sourceSize.height * 2)
              : sourceSize;
          if (width == double.infinity) {
            width = constrains.maxWidth;
            height = width * displaySize.height / displaySize.width;
          } else if (height == double.infinity) {
            height = constrains.maxHeight;
            width = height * displaySize.width / displaySize.height;
          }
        } else {
          if (width == double.infinity) {
            width = constrains.maxWidth;
            height = 300;
          } else if (height == double.infinity) {
            height = constrains.maxHeight;
            width = 300;
          }
        }

        if (_imageInfo != null) {
          final imageSize = Size(
            _imageInfo!.image.width.toDouble(),
            _imageInfo!.image.height.toDouble(),
          );
          final shouldSplit =
              widget.splitWideImage && shouldSplitWideImage(imageSize);
          // build image
          final sourceRect = _sourceRect(imageSize);
          Widget result = shouldSplit || sourceRect != Offset.zero & imageSize
              ? _SplitWideImage(
                  image: _imageInfo!.image,
                  sourceRect: sourceRect,
                  split: shouldSplit,
                  scale: _imageInfo!.scale,
                  width: width,
                  height: height,
                  color: widget.color,
                  opacity: widget.opacity,
                  colorBlendMode: widget.colorBlendMode,
                  fit: widget.fit,
                  alignment: widget.alignment,
                  matchTextDirection: widget.matchTextDirection,
                  invertColors: _invertColors,
                  isAntiAlias: widget.isAntiAlias,
                  filterQuality: widget.filterQuality,
                  splitInvert: widget.splitWideImageInvert,
                )
              : RawImage(
                  // Do not clone the image, because RawImage is a stateless wrapper.
                  // The image will be disposed by this state object when it is not needed
                  // anymore, such as when it is unmounted or when the image stream pushes
                  // a new image.
                  image: _imageInfo?.image,
                  debugImageLabel: _imageInfo?.debugLabel,
                  width: width,
                  height: height,
                  scale: _imageInfo?.scale ?? 1.0,
                  color: widget.color,
                  opacity: widget.opacity,
                  colorBlendMode: widget.colorBlendMode,
                  fit: widget.fit,
                  alignment: widget.alignment,
                  repeat: widget.repeat,
                  centerSlice: widget.centerSlice,
                  matchTextDirection: widget.matchTextDirection,
                  invertColors: _invertColors,
                  isAntiAlias: widget.isAntiAlias,
                  filterQuality: widget.filterQuality,
                );

          if (!widget.excludeFromSemantics) {
            result = Semantics(
              container: widget.semanticLabel != null,
              image: true,
              label: widget.semanticLabel ?? '',
              child: result,
            );
          }
          result = SizedBox(
            width: width,
            height: height,
            child: Center(child: result),
          );
          return widget.showImageDimensions
              ? ImageDimensionsOverlay(
                  size: decodedOriginalSize(_imageStream, _imageInfo!),
                  child: result,
                )
              : result;
        } else {
          // build progress
          return SizedBox(
            width: width,
            height: height,
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  backgroundColor: context.colorScheme.surfaceContainer,
                  value:
                      (_loadingProgress != null &&
                          _loadingProgress!.expectedTotalBytes != null &&
                          _loadingProgress!.expectedTotalBytes! != 0)
                      ? _loadingProgress!.cumulativeBytesLoaded /
                            _loadingProgress!.expectedTotalBytes!
                      : 0,
                ),
              ),
            ),
          );
        }
      },
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<ImageStream>('stream', _imageStream));
    properties.add(DiagnosticsProperty<ImageInfo>('pixels', _imageInfo));
    properties.add(
      DiagnosticsProperty<ImageChunkEvent>('loadingProgress', _loadingProgress),
    );
    properties.add(DiagnosticsProperty<int>('frameNumber', _frameNumber));
    properties.add(
      DiagnosticsProperty<bool>(
        'wasSynchronouslyLoaded',
        _wasSynchronouslyLoaded,
      ),
    );
  }
}

class _SplitWideImage extends StatelessWidget {
  const _SplitWideImage({
    required this.image,
    required this.sourceRect,
    required this.split,
    required this.scale,
    required this.width,
    required this.height,
    required this.color,
    required this.opacity,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
    required this.splitInvert,
  });

  final ui.Image image;
  final Rect sourceRect;
  final bool split;
  final double scale;

  final double? width;

  final double? height;

  final Color? color;

  final Animation<double>? opacity;

  final BlendMode? colorBlendMode;

  final BoxFit? fit;

  final AlignmentGeometry alignment;

  final bool matchTextDirection;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  final bool splitInvert;

  @override
  Widget build(BuildContext context) {
    Widget result = CustomPaint(
      size: Size(
        width ?? sourceRect.width / scale / (split ? 2 : 1),
        height ?? sourceRect.height / scale * (split ? 2 : 1),
      ),
      painter: _SplitWideImagePainter(
        image: image,
        sourceRect: sourceRect,
        split: split,
        scale: scale,
        color: color,
        colorBlendMode: colorBlendMode,
        fit: fit,
        alignment: alignment.resolve(Directionality.maybeOf(context)),
        matchTextDirection: matchTextDirection,
        textDirection: Directionality.maybeOf(context),
        invertColors: invertColors,
        isAntiAlias: isAntiAlias,
        filterQuality: filterQuality,
        splitInvert: splitInvert,
      ),
    );
    if (opacity != null) {
      result = FadeTransition(opacity: opacity!, child: result);
    }
    return SizedBox(width: width, height: height, child: result);
  }
}

class _SplitWideImagePainter extends CustomPainter {
  const _SplitWideImagePainter({
    required this.image,
    required this.sourceRect,
    required this.split,
    required this.scale,
    required this.color,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.textDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
    required this.splitInvert,
  });

  final ui.Image image;
  final Rect sourceRect;
  final bool split;
  final double scale;

  final Color? color;

  final BlendMode? colorBlendMode;

  final BoxFit? fit;

  final Alignment alignment;

  final bool matchTextDirection;

  final TextDirection? textDirection;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  final bool splitInvert;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final imageSize = sourceRect.size;
    final displaySize =
        (split ? Size(imageSize.width / 2, imageSize.height * 2) : imageSize) /
        scale;
    final fitted = applyBoxFit(fit ?? BoxFit.scaleDown, displaySize, size);
    final destination = alignment.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final paint = Paint()
      ..isAntiAlias = isAntiAlias
      ..filterQuality = filterQuality
      ..invertColors = invertColors;
    if (color != null) {
      paint.colorFilter = ColorFilter.mode(
        color!,
        colorBlendMode ?? BlendMode.srcIn,
      );
    }

    if (!split) {
      final source = alignment.inscribe(fitted.source * scale, sourceRect);
      final flip = matchTextDirection && textDirection == TextDirection.rtl;
      canvas.save();
      if (flip) {
        canvas.translate(size.width, 0);
        canvas.scale(-1, 1);
      }
      canvas.drawImageRect(image, source, destination, paint);
      canvas.restore();
      return;
    }
    for (final slice in splitWideImageSlices(
      invert:
          splitInvert ^
          (matchTextDirection && textDirection == TextDirection.rtl),
    )) {
      final source = Rect.fromLTWH(
        sourceRect.left + imageSize.width * slice.sourceLeft,
        sourceRect.top,
        imageSize.width * slice.sourceWidth,
        imageSize.height,
      );
      final target = Rect.fromLTWH(
        destination.left,
        destination.top + destination.height * slice.displayTop,
        destination.width,
        destination.height * slice.displayHeight,
      );
      canvas.drawImageRect(image, source, target, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SplitWideImagePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.sourceRect != sourceRect ||
        oldDelegate.split != split ||
        oldDelegate.scale != scale ||
        oldDelegate.color != color ||
        oldDelegate.colorBlendMode != colorBlendMode ||
        oldDelegate.fit != fit ||
        oldDelegate.alignment != alignment ||
        oldDelegate.matchTextDirection != matchTextDirection ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.invertColors != invertColors ||
        oldDelegate.isAntiAlias != isAntiAlias ||
        oldDelegate.filterQuality != filterQuality ||
        oldDelegate.splitInvert != splitInvert;
  }
}
