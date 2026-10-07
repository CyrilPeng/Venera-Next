import 'package:flutter/widgets.dart';
import 'gesture.dart';
import 'reader_page.dart';

/// UI composition for gesture capabilities and the owning shell.
class ReaderGestureHost extends StatelessWidget {
  const ReaderGestureHost({
    super.key,
    required this.reader,
    required this.child,
  });
  final ReaderState reader;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shell = context.readerScaffold;
    return ReaderGestureDetector(
      imageWork: reader.imageWork,
      changes: reader.shellChanges,
      createRequest: reader.createGestureRequest,
      onPortChanged: shell.onGesturePortChanged,
      isMenuOpen: () => shell.mounted && shell.isOpen,
      toggleMenu: () {
        if (shell.mounted) shell.openOrClose();
      },
      openSettings: () {
        if (shell.mounted) shell.openSetting();
      },
      openChapters: () {
        if (shell.mounted) shell.openChapterDrawer();
      },
      child: child,
    );
  }
}
