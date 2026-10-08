import 'package:flutter/material.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:venera_next/components/gesture.dart';
import 'package:venera_next/components/message.dart';
import 'package:venera_next/routing/app_navigation.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/translations.dart';
import 'package:venera_next/foundation/widget_utils.dart';

import 'data_sync_controller.dart';
import 'data_sync_scope.dart';

class SyncStatusSummary extends StatelessWidget {
  const SyncStatusSummary({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = DataSyncScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => buildSummary(context, controller),
    );
  }

  Widget buildSummary(BuildContext context, DataSyncController controller) {
    final syncStatus = controller.statusSnapshot;
    Widget child;
    if (!syncStatus.shouldShow) {
      child = const SliverPadding(padding: EdgeInsets.zero);
    } else if (syncStatus.isSyncing) {
      child = SliverToBoxAdapter(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.primary),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListTile(
            leading: const Icon(Icons.sync),
            title: Text(syncStatus.title.tl),
            subtitle: buildSyncStatusSubtitle(syncStatus),
            trailing: const CircularProgressIndicator(
              strokeWidth: 2,
            ).fixWidth(18).fixHeight(18),
          ),
        ),
      );
    } else {
      child = SliverToBoxAdapter(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListTile(
            leading: const Icon(Icons.sync),
            title: Text(syncStatus.title.tl),
            subtitle: buildSyncStatusSubtitle(syncStatus),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (syncStatus.lastError != null)
                  ClickInkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      showDialogMessage(
                        appNavigation.rootContext,
                        "Error".tl,
                        syncStatus.lastError!,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: context.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: Colors.red,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Text('Error'.tl, style: ts.s12),
                        ],
                      ),
                    ),
                  ).paddingRight(4),
                IconButton(
                  icon: const Icon(Icons.cloud_upload_outlined),
                  tooltip: 'Upload'.tl,
                  onPressed: () async {
                    controller.uploadData();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.cloud_download_outlined),
                  tooltip: 'Download'.tl,
                  onPressed: () async {
                    controller.downloadData();
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }
    return SliverAnimatedPaintExtent(
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }

  String buildSyncStatusDetail(DataSyncStatusSnapshot status) {
    if (status.isUploading) return 'Uploading data...'.tl;
    if (status.isDownloading) return 'Downloading data...'.tl;
    if (status.lastError != null) {
      return '${'Last sync failed'.tl}: ${status.lastError}';
    }
    if (status.lastSyncTime <= 0) return 'Not synced yet'.tl;
    return '${'Last synced'.tl}: ${status.formattedLastSyncTime}';
  }

  Widget buildSyncStatusSubtitle(DataSyncStatusSnapshot status) {
    return Text(
      buildSyncStatusDetail(status),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
