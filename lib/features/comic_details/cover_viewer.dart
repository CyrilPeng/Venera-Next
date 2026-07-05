import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera_next/components/effects.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/file_interaction.dart';
import 'package:venera_next/foundation/file_type.dart';
import 'package:venera_next/foundation/translations.dart';

class ComicCoverViewer extends StatefulWidget {
  const ComicCoverViewer({
    super.key,
    required this.imageProvider,
    required this.title,
    required this.heroTag,
  });

  final ImageProvider imageProvider;
  final String title;
  final String heroTag;

  @override
  State<ComicCoverViewer> createState() => _ComicCoverViewerState();
}

class _ComicCoverViewerState extends State<ComicCoverViewer> {
  bool isAppBarShow = true;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: context.colorScheme.surface,
        body: Stack(
          children: [
            Positioned.fill(
              child: PhotoView(
                imageProvider: widget.imageProvider,
                minScale: PhotoViewComputedScale.contained * 1.0,
                maxScale: PhotoViewComputedScale.covered * 3.0,
                backgroundDecoration: BoxDecoration(
                  color: context.colorScheme.surface,
                ),
                loadingBuilder: (context, event) => Center(
                  child: SizedBox(
                    width: 24.0,
                    height: 24.0,
                    child: CircularProgressIndicator(
                      value: event == null || event.expectedTotalBytes == null
                          ? null
                          : event.cumulativeBytesLoaded /
                                event.expectedTotalBytes!,
                    ),
                  ),
                ),
                onTapUp: (context, details, controllerValue) {
                  setState(() {
                    isAppBarShow = !isAppBarShow;
                  });
                },
                heroAttributes: PhotoViewHeroAttributes(tag: widget.heroTag),
              ),
            ),
            AnimatedPositioned(
              top: isAppBarShow ? 0 : -(context.padding.top + 52),
              left: 0,
              right: 0,
              duration: const Duration(milliseconds: 180),
              child: _buildAppBar(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Material(
      color: context.colorScheme.surface.toOpacity(0.72),
      child: BlurEffect(
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: context.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(fontSize: 18),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.save_alt),
                onPressed: _saveCover,
              ),
              const SizedBox(width: 8),
            ],
          ),
        ).paddingTop(context.padding.top),
      ),
    );
  }

  void _saveCover() async {
    try {
      final imageStream = widget.imageProvider.resolve(
        const ImageConfiguration(),
      );
      final completer = Completer<Uint8List>();

      imageStream.addListener(
        ImageStreamListener((ImageInfo info, bool _) async {
          final byteData = await info.image.toByteData(
            format: ImageByteFormat.png,
          );
          if (byteData != null) {
            completer.complete(byteData.buffer.asUint8List());
          }
        }),
      );

      final data = await completer.future;
      final fileType = detectFileType(data);
      await saveFile(
        filename: "cover_${widget.title}${fileType.ext}",
        data: data,
      );
    } catch (e) {
      if (mounted) {
        context.showMessage(message: "Error".tl);
      }
    }
  }
}
