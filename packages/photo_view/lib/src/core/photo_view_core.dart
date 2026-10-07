import 'package:flutter/widgets.dart';
import 'package:photo_view/photo_view.dart'
    show
        PhotoViewHeroAttributes,
        PhotoViewImageScaleEndCallback,
        PhotoViewImageTapDownCallback,
        PhotoViewImageTapUpCallback,
        PhotoViewScaleState,
        ScaleStateCycle;
import 'package:photo_view/src/controller/photo_view_controller.dart';
import 'package:photo_view/src/controller/photo_view_controller_delegate.dart';
import 'package:photo_view/src/controller/photo_view_scalestate_controller.dart';
import 'package:photo_view/src/core/image.dart';
import 'package:photo_view/src/core/photo_view_gesture_detector.dart';
import 'package:photo_view/src/core/photo_view_hit_corners.dart';
import 'package:photo_view/src/utils/photo_view_utils.dart';

const _defaultDecoration = const BoxDecoration(
  color: const Color.fromRGBO(0, 0, 0, 1.0),
);

/// Internal widget in which controls all animations lifecycle, core responses
/// to user gestures, updates to  the controller state and mounts the entire PhotoView Layout
class PhotoViewCore extends StatefulWidget {
  const PhotoViewCore({
    Key? key,
    required this.imageProvider,
    required this.backgroundDecoration,
    required this.semanticLabel,
    required this.gaplessPlayback,
    required this.heroAttributes,
    required this.enableRotation,
    required this.onTapUp,
    required this.onTapDown,
    required this.onScaleEnd,
    required this.gestureDetectorBehavior,
    required this.controller,
    required this.scaleBoundaries,
    required this.scaleStateCycle,
    required this.scaleStateController,
    required this.basePosition,
    required this.tightMode,
    required this.filterQuality,
    required this.disableGestures,
    required this.enablePanAlways,
    required this.strictScale,
    required this.onScaleUpdate,
    required this.fit,
  })  : customChild = null,
        super(key: key);

  const PhotoViewCore.customChild({
    Key? key,
    required this.customChild,
    required this.backgroundDecoration,
    this.heroAttributes,
    required this.enableRotation,
    this.onTapUp,
    this.onTapDown,
    this.onScaleEnd,
    this.gestureDetectorBehavior,
    required this.onScaleUpdate,
    required this.controller,
    required this.scaleBoundaries,
    required this.scaleStateCycle,
    required this.scaleStateController,
    required this.basePosition,
    required this.tightMode,
    required this.filterQuality,
    required this.disableGestures,
    required this.enablePanAlways,
    required this.strictScale,
  })  : imageProvider = null,
        semanticLabel = null,
        gaplessPlayback = false,
        fit = BoxFit.contain,
        super(key: key);

  final Decoration? backgroundDecoration;
  final ImageProvider? imageProvider;
  final String? semanticLabel;
  final bool? gaplessPlayback;
  final PhotoViewHeroAttributes? heroAttributes;
  final bool enableRotation;
  final Widget? customChild;

  final PhotoViewControllerBase controller;
  final PhotoViewScaleStateController scaleStateController;
  final ScaleBoundaries scaleBoundaries;
  final ScaleStateCycle scaleStateCycle;
  final Alignment basePosition;

  final PhotoViewImageTapUpCallback? onTapUp;
  final PhotoViewImageTapDownCallback? onTapDown;
  final PhotoViewImageScaleEndCallback? onScaleEnd;
  final bool Function()? onScaleUpdate;

  final HitTestBehavior? gestureDetectorBehavior;
  final bool tightMode;
  final bool disableGestures;
  final bool enablePanAlways;
  final bool strictScale;

  final FilterQuality filterQuality;

  final BoxFit fit;

  @override
  State<StatefulWidget> createState() {
    return PhotoViewCoreState();
  }

  bool get hasCustomChild => customChild != null;
}

class PhotoViewCoreState extends State<PhotoViewCore>
    with
        TickerProviderStateMixin,
        PhotoViewControllerDelegate,
        HitCornersDetector {
  Offset? _normalizedPosition;
  double? _scaleBefore;
  double? _rotationBefore;
  int _gestureGeneration = 0;
  int _callbackGeneration = 0;
  bool _disposed = false;
  VoidCallback? _removeControllerCallbacks;

  late final AnimationController _scaleAnimationController;
  Animation<double>? _scaleAnimation;

  late final AnimationController _positionAnimationController;
  Animation<Offset>? _positionAnimation;

  late final AnimationController _rotationAnimationController =
      AnimationController(vsync: this)..addListener(handleRotationAnimation);
  Animation<double>? _rotationAnimation;

  PhotoViewHeroAttributes? get heroAttributes => widget.heroAttributes;

  late ScaleBoundaries cachedScaleBoundaries = widget.scaleBoundaries;

  late final Size imageSize;
  late final double imageScale;

  void handleScaleAnimation() {
    scale = _scaleAnimation!.value;
  }

  void handlePositionAnimate() {
    controller.position = _positionAnimation!.value;
  }

  void handleRotationAnimation() {
    controller.rotation = _rotationAnimation!.value;
  }

  void onScaleStart(ScaleStartDetails details) {
    _gestureGeneration++;
    _rotationBefore = controller.rotation;
    _scaleBefore = scale;
    _normalizedPosition = details.focalPoint - controller.position;
    _scaleAnimationController.stop();
    _positionAnimationController.stop();
    _rotationAnimationController.stop();
  }

  void onScaleUpdate(ScaleUpdateDetails details) {
    if (stateChanged) {
      _scaleBefore = scale;
      stateChanged = false;
    }
    if (widget.onScaleUpdate?.call() == true) {
      return;
    }
    double newScale = _scaleBefore! * details.scale;
    Offset delta = details.focalPoint - _normalizedPosition!;

    if (widget.strictScale &&
        (newScale > widget.scaleBoundaries.maxScale ||
            newScale < widget.scaleBoundaries.minScale)) {
      if (newScale > widget.scaleBoundaries.maxScale) {
        newScale = widget.scaleBoundaries.maxScale;
      } else if (newScale < widget.scaleBoundaries.minScale) {
        newScale = widget.scaleBoundaries.minScale;
      }
      if (newScale == scale) {
        return;
      }
    }

    if (details.pointerCount == 1 && newScale != scale) {
      final screenSize = MediaQuery.of(context).size;
      delta = Offset(screenSize.width / 2 - _normalizedPosition!.dx,
          screenSize.height / 2 - _normalizedPosition!.dy);
    }

    updateScaleStateFromNewScale(newScale);

    updateMultiple(
      scale: newScale,
      position: widget.enablePanAlways
          ? delta
          : clampPosition(position: delta * details.scale),
      rotation:
          widget.enableRotation ? _rotationBefore! + details.rotation : null,
      rotationFocusPoint: widget.enableRotation ? details.focalPoint : null,
    );
  }

  void onScaleEnd(ScaleEndDetails details) async {
    final generation = _gestureGeneration;
    final original = controller;
    final originalScale = scaleStateController;
    bool isCurrent() =>
        mounted &&
        !_disposed &&
        generation == _gestureGeneration &&
        identical(controller, original) &&
        identical(scaleStateController, originalScale);
    if (stateChanged) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!isCurrent()) {
      return;
    }
    final double _scale = scale;
    final double maxScale = scaleBoundaries.maxScale;
    final double minScale = scaleBoundaries.minScale;

    if (widget.onScaleEnd?.call(context, details, controller.value) == true) {
      return;
    }
    if (!isCurrent()) {
      return;
    }
    final Offset _position = controller.position;

    //animate back to maxScale if gesture exceeded the maxScale specified
    if (_scale > maxScale) {
      final double scaleComebackRatio = maxScale / _scale;
      animateScale(_scale, maxScale);
      final Offset clampedPosition = clampPosition(
        position: _position * scaleComebackRatio,
        scale: maxScale,
      );
      animatePosition(_position, clampedPosition);
      return;
    }

    //animate back to minScale if gesture fell smaller than the minScale specified
    if (_scale < minScale) {
      final double scaleComebackRatio = minScale / _scale;
      animateScale(_scale, minScale);
      animatePosition(
        _position,
        clampPosition(
          position: _position * scaleComebackRatio,
          scale: minScale,
        ),
      );
      return;
    }
    // get magnitude from gesture velocity
    final double magnitude = details.velocity.pixelsPerSecond.distance;

    // animate velocity only if there is no scale change and a significant magnitude
    if (_scaleBefore! / _scale == 1.0 && magnitude >= 400.0) {
      final Offset direction = details.velocity.pixelsPerSecond / magnitude;
      print(details.velocity.pixelsPerSecond);
      animatePosition(
        _position,
        clampPosition(position: _position + direction * 200.0),
      );
    }
  }

  void onDoubleTap() {
    nextScaleState();
  }

  Future<void> animateScale(double from, double to) async {
    _scaleAnimation = Tween<double>(
      begin: from,
      end: to,
    ).animate(_scaleAnimationController);
    await (_scaleAnimationController..value = 0.0).fling(velocity: 0.4);
  }

  void animatePosition(Offset from, Offset to) {
    _positionAnimation = Tween<Offset>(begin: from, end: to)
        .animate(_positionAnimationController);
    _positionAnimationController
      ..value = 0.0
      ..fling(velocity: 0.4);
  }

  void animateRotation(double from, double to) {
    _rotationAnimation = Tween<double>(begin: from, end: to)
        .animate(_rotationAnimationController);
    _rotationAnimationController
      ..value = 0.0
      ..fling(velocity: 0.4);
  }

  void onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      onAnimationStatusCompleted();
    }
  }

  /// Check if scale is equal to initial after scale animation update
  void onAnimationStatusCompleted() {
    if (scaleStateController.scaleState != PhotoViewScaleState.initial &&
        scale == scaleBoundaries.initialScale) {
      scaleStateController.setInvisibly(PhotoViewScaleState.initial);
    }
  }

  double? initialScale;

  @override
  void initState() {
    super.initState();
    initDelegate();
    addAnimateOnScaleStateUpdate(animateOnScaleStateUpdate);

    cachedScaleBoundaries = widget.scaleBoundaries;

    _scaleAnimationController = AnimationController(vsync: this)
      ..addListener(handleScaleAnimation)
      ..addStatusListener(onAnimationStatus);
    _positionAnimationController = AnimationController(vsync: this)
      ..addListener(handlePositionAnimate);
    Future.microtask(() {
      if (mounted && !_disposed) {
        initialScale = controller.scale;
      }
    });
  }

  @override
  void didUpdateWidget(covariant PhotoViewCore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, controller) ||
        !identical(oldWidget.scaleStateController, scaleStateController) ||
        oldWidget.scaleBoundaries != widget.scaleBoundaries ||
        oldWidget.imageProvider != widget.imageProvider) {
      _gestureGeneration++;
    }
    if (!identical(oldWidget.controller, controller) ||
        !identical(oldWidget.scaleStateController, scaleStateController)) {
      _scaleAnimationController.stop();
      _positionAnimationController.stop();
      _rotationAnimationController.stop();
      initialScale = controller.scale;
      _removeControllerCallbacks?.call();
      _callbackGeneration++;
    }
  }

  void animateOnScaleStateUpdate(double prevScale, double nextScale) {
    animateScale(prevScale, nextScale);
    animatePosition(controller.position, Offset.zero);
    animateRotation(controller.rotation, 0.0);
  }

  @override
  void dispose() {
    _disposed = true;
    _gestureGeneration++;
    _callbackGeneration++;
    _removeControllerCallbacks?.call();
    _removeControllerCallbacks = null;
    _scaleAnimationController.removeStatusListener(onAnimationStatus);
    _scaleAnimationController.dispose();
    _positionAnimationController.dispose();
    _rotationAnimationController.dispose();
    super.dispose();
  }

  void onTapUp(TapUpDetails details) {
    widget.onTapUp?.call(context, details, controller.value);
  }

  void onTapDown(TapDownDetails details) {
    widget.onTapDown?.call(context, details, controller.value);
  }

  bool stateChanged = false;

  void _bindControllerCallbacks() {
    _removeControllerCallbacks?.call();
    final original = controller;
    final generation = ++_callbackGeneration;
    bool isCurrent() =>
        mounted &&
        !_disposed &&
        generation == _callbackGeneration &&
        identical(controller, original);
    void doubleClick() {
      if (!isCurrent()) {
        return;
      }
      _gestureGeneration++;
      nextScaleState();
    }

    void move(Offset from, Offset to) {
      if (isCurrent()) {
        animatePosition(from, to);
      }
    }

    void update(PhotoViewScaleState? state) {
      if (!isCurrent()) {
        return;
      }
      _gestureGeneration++;
      if (state != null) {
        scaleStateController.scaleState = state;
      }
      stateChanged = true;
    }

    void zoom(double value, [Offset? newPosition]) {
      if (!isCurrent()) {
        return;
      }
      _gestureGeneration++;
      if (position != clampPosition(scale: value, position: newPosition)) {
        animatePosition(
            position, clampPosition(scale: value, position: newPosition));
      }
      animateScale(scale, value);
    }

    double? initial() => isCurrent() ? initialScale : null;
    double? fit(BoxFit value) => isCurrent() ? getScaleWithFit(value) : null;
    original.onDoubleClick = doubleClick;
    original.animatePosition = move;
    original.updateState = update;
    original.animateScale = zoom;
    original.getInitialScale = initial;
    if (original is PhotoViewController) {
      original.getScaleWithFit = fit;
    }
    _removeControllerCallbacks = () {
      if (original.onDoubleClick == doubleClick) {
        original.onDoubleClick = null;
      }
      if (original.animatePosition == move) {
        original.animatePosition = null;
      }
      if (original.updateState == update) {
        original.updateState = null;
      }
      if (original.animateScale == zoom) {
        original.animateScale = null;
      }
      if (original.getInitialScale == initial) {
        original.getInitialScale = null;
      }
      if (original is PhotoViewController && original.getScaleWithFit == fit) {
        original.getScaleWithFit = null;
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    // Check if we need a recalc on the scale
    if (widget.scaleBoundaries != cachedScaleBoundaries) {
      markNeedsScaleRecalc = true;
      cachedScaleBoundaries = widget.scaleBoundaries;
    }

    _bindControllerCallbacks();

    return StreamBuilder(
        stream: controller.outputStateStream,
        initialData: controller.prevValue,
        builder: (
          BuildContext context,
          AsyncSnapshot<PhotoViewControllerValue> snapshot,
        ) {
          if (snapshot.hasData) {
            final PhotoViewControllerValue value = snapshot.data!;
            final useImageScale = widget.filterQuality != FilterQuality.none;

            final computedScale = useImageScale ? 1.0 : scale;

            final matrix = Matrix4.identity()
              ..translateByDouble(
                  value.position.dx, value.position.dy, 0.0, 1.0)
              ..scaleByDouble(computedScale, computedScale, computedScale, 1.0)
              ..rotateZ(value.rotation);

            final Widget customChildLayout = CustomSingleChildLayout(
              delegate: _CenterWithOriginalSizeDelegate(
                scaleBoundaries.childSize,
                basePosition,
                useImageScale,
              ),
              child: _buildHero(),
            );

            final child = Container(
              constraints: widget.tightMode
                  ? BoxConstraints.tight(scaleBoundaries.childSize * scale)
                  : null,
              child: Center(
                child: Transform(
                  child: customChildLayout,
                  transform: matrix,
                  alignment: basePosition,
                ),
              ),
              decoration: widget.backgroundDecoration ?? _defaultDecoration,
            );

            if (widget.disableGestures) {
              return child;
            }

            return PhotoViewGestureDetector(
              child: child,
              onDoubleTap: nextScaleState,
              onScaleStart: onScaleStart,
              onScaleUpdate: onScaleUpdate,
              onScaleEnd: onScaleEnd,
              hitDetector: this,
              onTapUp: widget.onTapUp != null
                  ? (details) => widget.onTapUp!(context, details, value)
                  : null,
              onTapDown: widget.onTapDown != null
                  ? (details) => widget.onTapDown!(context, details, value)
                  : null,
            );
          } else {
            return Container();
          }
        });
  }

  Widget _buildHero() {
    return heroAttributes != null
        ? Hero(
            tag: heroAttributes!.tag,
            createRectTween: heroAttributes!.createRectTween,
            flightShuttleBuilder: heroAttributes!.flightShuttleBuilder,
            placeholderBuilder: heroAttributes!.placeholderBuilder,
            transitionOnUserGestures: heroAttributes!.transitionOnUserGestures,
            child: _buildChild(),
          )
        : _buildChild();
  }

  double? getScaleWithFit(BoxFit fit) {
    final screenSize = MediaQuery.of(context).size;
    final size = imageSize;
    if (fit == BoxFit.fitHeight &&
        (screenSize.width / screenSize.height < size.width / size.height)) {
      var newScale =
          screenSize.height / (size.height / size.width * screenSize.width);
      assert(newScale > 1);
      newScale *= imageScale;
      return newScale;
    } else if (fit == BoxFit.fitWidth &&
        (screenSize.width / screenSize.height > size.width / size.height)) {
      var newScale =
          screenSize.width / (size.width / size.height * screenSize.height);
      assert(newScale > 1);
      newScale *= imageScale;
      return newScale;
    }
    return null;
  }

  /// callback when loading image completely, update scale using [widget.fit] and image's size.
  void _onLoadEnd(Size size) {
    imageSize = size;
    imageScale = scale;
    if (widget.hasCustomChild) {
      return;
    }
    final screenSize = MediaQuery.of(context).size;
    if (widget.fit == BoxFit.fitHeight &&
        (screenSize.width / screenSize.height < size.width / size.height)) {
      var newScale =
          screenSize.height / (size.height / size.width * screenSize.width);
      assert(newScale > 1);
      newScale *= scale;
      updateScaleStateFromNewScale(newScale);
      updateMultiple(scale: newScale);
      if (controller is PhotoViewController) {
        (controller as PhotoViewController).initial = PhotoViewControllerValue(
            position: controller.position,
            scale: newScale,
            rotation: controller.rotation,
            rotationFocusPoint: controller.rotationFocusPoint);
      }
    } else if (widget.fit == BoxFit.fitWidth &&
        (screenSize.width / screenSize.height > size.width / size.height)) {
      var newScale =
          screenSize.width / (size.width / size.height * screenSize.height);
      assert(newScale > 1);
      newScale *= scale;
      updateScaleStateFromNewScale(newScale);
      updateMultiple(scale: newScale);
      if (controller is PhotoViewController) {
        (controller as PhotoViewController).initial = PhotoViewControllerValue(
            position: controller.position,
            scale: newScale,
            rotation: controller.rotation,
            rotationFocusPoint: controller.rotationFocusPoint);
      }
    }
  }

  Widget _buildChild() {
    return widget.hasCustomChild
        ? widget.customChild!
        : PhotoViewImage(
            image: widget.imageProvider!,
            semanticLabel: widget.semanticLabel,
            gaplessPlayback: widget.gaplessPlayback ?? false,
            filterQuality: widget.filterQuality,
            width: scaleBoundaries.childSize.width * scale,
            fit: BoxFit.contain,
            onLoadEnd: _onLoadEnd,
          );
  }
}

class _CenterWithOriginalSizeDelegate extends SingleChildLayoutDelegate {
  const _CenterWithOriginalSizeDelegate(
    this.subjectSize,
    this.basePosition,
    this.useImageScale,
  );

  final Size subjectSize;
  final Alignment basePosition;
  final bool useImageScale;

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final childWidth = useImageScale ? childSize.width : subjectSize.width;
    final childHeight = useImageScale ? childSize.height : subjectSize.height;

    final halfWidth = (size.width - childWidth) / 2;
    final halfHeight = (size.height - childHeight) / 2;

    final double offsetX = halfWidth * (basePosition.x + 1);
    final double offsetY = halfHeight * (basePosition.y + 1);
    return Offset(offsetX, offsetY);
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return useImageScale
        ? const BoxConstraints()
        : BoxConstraints.tight(subjectSize);
  }

  @override
  bool shouldRelayout(_CenterWithOriginalSizeDelegate oldDelegate) {
    return oldDelegate != this;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _CenterWithOriginalSizeDelegate &&
          runtimeType == other.runtimeType &&
          subjectSize == other.subjectSize &&
          basePosition == other.basePosition &&
          useImageScale == other.useImageScale;

  @override
  int get hashCode =>
      subjectSize.hashCode ^ basePosition.hashCode ^ useImageScale.hashCode;
}
