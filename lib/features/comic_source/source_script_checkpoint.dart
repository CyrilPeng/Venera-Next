import 'dart:io';

import 'source_transaction_journal.dart';

/// The live mutation's script checkpoint and durable transaction owner. Its
/// original.js remains available for diagnostics; version 1 legacy directories
/// are not interpreted or deleted by this protocol.
class SourceScriptCheckpoint {
  SourceScriptCheckpoint._(this.target, this.transaction);
  final File target;
  final SourceTransactionJournal transaction;
  Directory get directory => transaction.directory;

  static Future<SourceScriptCheckpoint> prepare({
    required String dataPath,
    required File target,
    required List<int>? before,
    required List<int>? after,
  }) async => SourceScriptCheckpoint._(
    target,
    await SourceTransactionJournal.begin(
      dataPath: dataPath,
      script: target,
      before: before,
      after: after,
    ),
  );

  Future<void> verifyOriginal() => transaction.verifyScript(expected: false);
  Future<void> verifyExpected() => transaction.verifyScript(expected: true);
  Future<void> writeExpected() => transaction.writeScript();
  Future<void> restore() => transaction.restoreScript();

  /// Live callers must own the settings persistence queue. Unresolved recovery
  /// cannot discard its evidence merely because an error has been reported.
  Future<void> discard() async {
    await transaction.recoverCurrent();
    await transaction.close();
  }

  Future<void> close() => transaction.close();
}
