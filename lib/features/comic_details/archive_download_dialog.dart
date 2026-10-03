import 'package:flutter/material.dart';
import 'package:venera_next/components/button.dart';
import 'package:venera_next/components/loading.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'archive_download.dart';

class ArchiveDownloadSelection {
  const ArchiveDownloadSelection.normal() : url = null;
  const ArchiveDownloadSelection.archive(this.url);
  final String? url;
}

class ArchiveDownloadDialog extends StatefulWidget {
  const ArchiveDownloadDialog({
    super.key,
    required this.downloader,
    required this.comicId,
  });
  final ArchiveDownloader downloader;
  final String comicId;
  @override
  State<ArchiveDownloadDialog> createState() => _ArchiveDownloadDialogState();
}

class _ArchiveDownloadDialogState extends State<ArchiveDownloadDialog> {
  List<ArchiveInfo>? archives;
  int selected = -1;
  bool isLoading = false;
  bool isGettingLink = false;
  String? error;

  Future<void> load() async {
    if (isLoading || isGettingLink) return;
    setState(() {
      isLoading = true;
      archives = null;
      error = null;
      selected = -1;
    });
    final result = await loadArchiveOptions(widget.downloader, widget.comicId);
    if (!mounted) return;
    setState(() {
      isLoading = false;
      archives = result.dataOrNull ?? [];
      error = result.error
          ? result.errorMessage
          : (archives!.isEmpty ? "No archive options available" : null);
    });
  }

  Future<void> confirm() async {
    if (isGettingLink) return;
    if (selected == -1) {
      Navigator.of(context).pop(const ArchiveDownloadSelection.normal());
      return;
    }
    if (archives == null || selected < 0 || selected >= archives!.length) {
      return;
    }
    final archiveId = archives![selected].id;
    setState(() => isGettingLink = true);
    final result = await loadArchiveDownloadLink(
      widget.downloader,
      widget.comicId,
      archiveId,
    );
    if (!mounted) return;
    setState(() => isGettingLink = false);
    if (result.error) {
      context.showMessage(message: (result.errorMessage ?? "Error").tl);
    } else {
      Navigator.of(context).pop(ArchiveDownloadSelection.archive(result.data));
    }
  }

  @override
  Widget build(BuildContext context) => ContentDialog(
    title: "Download".tl,
    content: RadioGroup<int>(
      groupValue: selected,
      onChanged: (value) {
        if (!isGettingLink) setState(() => selected = value ?? selected);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioListTile<int>(value: -1, title: Text("Normal".tl)),
          ExpansionTile(
            title: Text("Archive".tl),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
            collapsedShape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
            onExpansionChanged: (expanded) {
              if (expanded && (archives == null || error != null)) load();
            },
            children: [
              if (archives == null)
                const Center(child: ListLoadingIndicator())
              else if (error != null)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(title: Text(error!.tl)),
                    Button.text(onPressed: load, child: Text("Retry".tl)),
                  ],
                )
              else
                for (var i = 0; i < archives!.length; i++)
                  RadioListTile<int>(
                    value: i,
                    title: Text(archives![i].title),
                    subtitle: Text(archives![i].description),
                  ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      Button.filled(
        isLoading: isGettingLink,
        onPressed: confirm,
        child: Text("Confirm".tl),
      ),
    ],
  );
}
