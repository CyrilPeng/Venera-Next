import 'dart:ui' as ui;

class TrackedImageCodec implements ui.Codec {
  TrackedImageCodec(this.frame);
  final Future<ui.FrameInfo> frame;
  int reads = 0;
  int disposals = 0;
  @override
  int get frameCount => 1;
  @override
  int get repetitionCount => 0;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    reads++;
    return frame;
  }

  @override
  void dispose() => disposals++;
}

Future<ui.Image> opaqueTestImage() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff00ff00), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(1, 1);
  } finally {
    picture.dispose();
  }
}
