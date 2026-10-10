import 'dart:io';
import 'package:venera_next/features/sync/data_sync_ownership.dart';

void main(List<String> args) {
  final directory = args.first;
  final ownership = args.length == 2 && args[1] == 'application'
      ? SqliteDataSyncOwnership.applicationData(() => directory)
      : SqliteDataSyncOwnership(() => directory);
  ownership.acquire();
  try {
    File('$directory/owner-ready.tmp').writeAsStringSync('$pid', flush: true);
    File('$directory/owner-ready.tmp').renameSync('$directory/owner-ready');
    stdin.readLineSync();
    throw StateError('Parent must kill this process');
  } finally {
    ownership.release();
  }
}
