import 'dart:io';
import 'package:venera_next/features/sync/data_sync_ownership.dart';

void main(List<String> args) {
  final ownership = SqliteDataSyncOwnership(() => args.single)..acquire();
  try {
    File(
      '${args.single}/owner-ready.tmp',
    ).writeAsStringSync('$pid', flush: true);
    File(
      '${args.single}/owner-ready.tmp',
    ).renameSync('${args.single}/owner-ready');
    stdin.readLineSync();
    throw StateError('Parent must kill this process');
  } finally {
    ownership.release();
  }
}
