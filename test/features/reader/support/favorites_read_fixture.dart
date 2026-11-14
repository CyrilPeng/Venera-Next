import 'package:flutter/foundation.dart';
import 'package:venera_next/features/favorites/favorites_manager.dart';
import 'package:venera_next/foundation/comic_type.dart';

class ReaderFavoritesStub extends ChangeNotifier
    implements LocalFavoritesManager {
  @override
  int get connectionGeneration => 1;

  @override
  Future<void> onRead(
    String id,
    ComicType type, {
    int? generation,
    void Function()? checkActive,
  }) async {
    checkActive?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
