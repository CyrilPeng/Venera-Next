class MigratedReaderPosition {
  const MigratedReaderPosition({
    required this.chapter,
    required this.previousPage,
    required this.imagePage,
  });

  final int chapter;
  final int previousPage;
  final int imagePage;
}

/// Retains the original mapping when a cancelled view retries after persistence.
class ReaderPageOrderMigration {
  ReaderPageOrderMigration({
    required this.migrate,
    required this.initialChapter,
    required this.initialPage,
    required this.currentChapter,
    required this.displayPage,
    required this.restorePage,
  });

  final Future<MigratedReaderPosition?> Function() migrate;
  final int initialChapter;
  final int? initialPage;
  final int Function() currentChapter;
  final int Function(int imagePage) displayPage;
  final void Function(int page) restorePage;
  Future<MigratedReaderPosition?>? _pending;
  bool _applied = false;

  Future<MigratedReaderPosition?> _runMigration() async {
    try {
      return await Future.sync(migrate);
    } catch (_) {
      _pending = null;
      rethrow;
    }
  }

  Future<void> prepare({required bool Function() isCancelled}) async {
    if (_applied || isCancelled()) return;
    final position = await (_pending ??= _runMigration());
    if (_applied || isCancelled()) return;
    if (position != null &&
        currentChapter() == initialChapter &&
        initialChapter == position.chapter &&
        initialPage == position.previousPage) {
      restorePage(displayPage(position.imagePage));
    }
    _applied = true;
  }
}
