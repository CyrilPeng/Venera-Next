import 'dart:math' as math;

import 'package:image/image.dart' as image;
import 'package:pdfrx/pdfrx.dart';
import 'package:venera_next/features/local_comics/import_export/document_import.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/file_interaction.dart';

const double _pdfRenderScale = 3;
const int _pdfRenderMaxEdge = 3000;

class PdfRenderSize {
  const PdfRenderSize(this.width, this.height);

  final int width;
  final int height;
}

PdfRenderSize calculatePdfRenderSize(
  double width,
  double height, {
  double scale = _pdfRenderScale,
  int maxEdge = _pdfRenderMaxEdge,
}) {
  if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
    throw const FormatException('PDF page has an invalid size');
  }
  final longestEdge = math.max(width, height);
  final actualScale = math.min(scale, maxEdge / longestEdge);
  return PdfRenderSize(
    math.max(1, (width * actualScale).round()),
    math.max(1, (height * actualScale).round()),
  );
}

abstract final class PdfComicImporter {
  static Future<LocalComic> import(
    File file, {
    DocumentImportProgress? onProgress,
  }) async {
    await pdfrxFlutterInitialize();
    late final PdfDocument document;
    try {
      document = await PdfDocument.openFile(file.path);
    } on PdfPasswordException {
      throw const FormatException(
        'Password-protected PDF files are not supported',
      );
    }
    DocumentImportSession? session;
    try {
      if (document.pages.isEmpty) {
        throw const FormatException('PDF contains no pages');
      }

      final title = file.basenameWithoutExt;
      session = DocumentImportSession.start(title);
      final total = document.pages.length;
      for (var i = 0; i < total; i++) {
        final page = document.pages[i];
        final size = calculatePdfRenderSize(page.width, page.height);
        final rendered = await page.render(
          fullWidth: size.width.toDouble(),
          fullHeight: size.height.toDouble(),
        );
        if (rendered == null) {
          throw Exception('Failed to render PDF page ${i + 1}');
        }
        try {
          final decoded = image.Image.fromBytes(
            width: rendered.width,
            height: rendered.height,
            bytes: rendered.pixels.buffer,
            bytesOffset: rendered.pixels.offsetInBytes,
            order: image.ChannelOrder.bgra,
          );
          final pageFile = File(
            session.pagePath(pageIndex: i + 1, extension: 'jpg'),
          );
          await pageFile.writeAsBytes(image.encodeJpg(decoded, quality: 92));
          if (i == 0) {
            await pageFile.copyMem(
              FilePath.join(session.directory.path, 'cover.jpg'),
            );
          }
        } finally {
          rendered.dispose();
        }
        onProgress?.call(i + 1, total);
      }

      return session.finish(author: '', tags: const [], cover: 'cover.jpg');
    } catch (_) {
      await session?.abort();
      rethrow;
    } finally {
      await document.dispose();
    }
  }
}
