import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const uiRegressionFont = 'UiRegressionQA';

Future<void> loadUiRegressionFonts() async {
  if (Platform.environment['UI_REGRESSION_QA_DIRECTORY'] == null) return;
  final font = Platform.environment['UI_REGRESSION_QA_FONT'];
  if (font != null) {
    await (FontLoader(
      uiRegressionFont,
    )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
  }
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

Future<void> captureUiRegression(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  final output = Platform.environment['UI_REGRESSION_QA_DIRECTORY'];
  if (output == null) return;
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$output/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
