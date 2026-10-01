import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/app_data_operations.dart';

void main() {
  test(
    'queued actions wait for completion and preserve submission order',
    () async {
      final operations = AppDataOperations();
      final entered = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];
      final first = operations.run(() async {
        events.add('first start');
        entered.complete();
        await release.future;
        events.add('first end');
      });
      final second = operations.run(() async {
        events.add('second');
        return 2;
      });
      await entered.future;
      expect(events, ['first start']);
      release.complete();
      await first;
      expect(await second, 2);
      expect(events, ['first start', 'first end', 'second']);
    },
  );

  test(
    'both asynchronous and synchronous failures release later actions',
    () async {
      final operations = AppDataOperations();
      final first = operations.run<void>(() async {
        throw StateError('async');
      });
      final second = operations.run<void>(() {
        throw StateError('sync');
      });
      final finalAction = operations.run(() async => 'continued');
      await expectLater(first, throwsStateError);
      await expectLater(second, throwsStateError);
      expect(await finalAction, 'continued');
    },
  );
}
