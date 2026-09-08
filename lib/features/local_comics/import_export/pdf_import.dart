import 'dart:math' as math;

import 'package:image/image.dart' as image;
import 'package:pdfrx/pdfrx.dart';
import 'package:venera_next/features/local_comics/import_export/document_import.dart';
import 'package:venera_next/features/local_comics/local.dart';
import 'package:venera_next/foundation/file_system.dart';

const double _pdfRenderScale = 3;
const int _pdfRenderMaxEdge = 3000;

class PdfRenderSize {
  const PdfRenderSize(this.width, this.height);

  final int width;
  final int height;
}

class PdfPageRenderException implements Exception {
  const PdfPageRenderException(this.page);

  final int page;

  @override
  String toString() => 'Failed to render PDF page $page';
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
    String? title,
    DocumentImportProgress? onProgress,
    DocumentImportCancellation? cancellation,
    Future<void> Function(LocalComic comic)? registerComic,
  }) async {
    cancellation?.throwIfCancelled();
    await pdfrxFlutterInitialize();
    late final PdfDocument document;
    try {
      document = await PdfDocument.openFile(file.path);
    } on PdfPasswordException {
      throw const FormatException(
        'Password-protected PDF files are not supported',
      );
    }
    return importDocument(
      document,
      title: title ?? file.basenameWithoutExt,
      onProgress: onProgress,
      cancellation: cancellation,
      registerComic: registerComic,
    );
  }

  /// Takes ownership of [document] and closes it even if conversion fails.
  /// The output is committed only after [registerComic] succeeds, when supplied.
  static Future<LocalComic> importDocument(
    PdfDocument document, {
    required String title,
    DocumentImportProgress? onProgress,
    DocumentImportCancellation? cancellation,
    Future<void> Function(LocalComic comic)? registerComic,
  }) async {
    DocumentImportSession? session;
    try {
      cancellation?.throwIfCancelled();
      if (document.pages.isEmpty) {
        throw const FormatException('PDF contains no pages');
      }

      session = DocumentImportSession.start(title);
      final total = document.pages.length;
      onProgress?.call(0, total);
      for (var i = 0; i < total; i++) {
        cancellation?.throwIfCancelled();
        final page = document.pages[i];
        final size = calculatePdfRenderSize(page.width, page.height);
        final rendered = await page.render(
          fullWidth: size.width.toDouble(),
          fullHeight: size.height.toDouble(),
        );
        if (rendered == null) {
          cancellation?.throwIfCancelled();
          throw PdfPageRenderException(i + 1);
        }
        try {
          cancellation?.throwIfCancelled();
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

      cancellation?.throwIfCancelled();
      final comic = session.finish(
        author: '',
        tags: const [],
        cover: 'cover.jpg',
      );
      await registerComic?.call(comic);
      return comic;
    } catch (_) {
      await session?.abort();
      rethrow;
    } finally {
      await document.dispose();
    }
  }
}
