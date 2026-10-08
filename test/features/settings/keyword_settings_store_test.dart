import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/keyword_settings_store.dart';
import 'package:venera_next/foundation/reader_preference_settings.dart';

// Only global reads/writes are valid for this service. Unexpected scoped calls
// reach Object.noSuchMethod and fail; no global application reset is needed.
class _Settings implements ReaderPreferenceSettings {
  final values = <String, Object?>{
    'blockedWords': <String>[],
    'blockedCommentWords': <String>[],
  };
  @override
  Object? operator [](String key) => values[key];
  @override
  void operator []=(String key, Object? value) => values[key] = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'batch captures selection before admission and retries membership without duplicates',
    () async {
      final draft = _Settings()..['blockedWords'] = ['old', 'old'];
      final admission = Completer<void>();
      var failSave = true;
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async {
          await admission.future;
          change(draft);
          if (failSave) throw StateError('published but not persisted');
        },
      );
      final selected = ['new', 'old', 'new', ''];
      final attempt = store.blockAll(BlockedKeywordList.comics, selected);
      final failed = expectLater(attempt, throwsStateError);
      selected.add('late');
      (draft['blockedWords'] as List).insert(0, 'concurrent');
      admission.complete();
      await failed;
      expect(draft['blockedWords'], ['concurrent', 'old', 'old', 'new', '']);
      draft['blockedWords'] = [
        'after failure',
        ...draft['blockedWords'] as List,
      ];
      failSave = false;
      await store.blockAll(BlockedKeywordList.comics, [
        'new',
        'old',
        'new',
        '',
      ]);
      expect(draft['blockedWords'], [
        'after failure',
        'concurrent',
        'old',
        'old',
        'new',
        '',
      ]);
      expect(draft['blockedCommentWords'], isEmpty);
    },
  );

  for (final target in BlockedKeywordList.values) {
    test(
      '${target.name} edits merge into the admitted draft and await persistence',
      () async {
        final visible = _Settings()..[target.key] = ['outdated'];
        final draft = _Settings()..[target.key] = ['keep', 'delete', 'delete'];
        final admission = Completer<void>();
        final persisted = Completer<void>();
        final store = KeywordSettingsStore(
          readSettings: () => visible,
          updateSettings: (change) async {
            await admission.future;
            change(draft);
            await persisted.future;
          },
        );
        var finished = false;
        final add = store
            .setBlocked(target, 'new', true)
            .then((_) => finished = true);
        final remove = store.setBlocked(target, 'delete', false);
        final duplicate = store.setBlocked(target, 'new', true);
        (draft[target.key] as List).insert(0, 'concurrent');
        expect(draft[target.key], ['concurrent', 'keep', 'delete', 'delete']);
        admission.complete();
        await Future<void>.delayed(Duration.zero);
        expect(draft[target.key], ['concurrent', 'keep', 'new']);
        expect(finished, isFalse);
        expect(visible[target.key], ['outdated']);
        persisted.complete();
        await Future.wait([add, remove, duplicate]);
        expect(finished, isTrue);
        expect(
          draft[target == BlockedKeywordList.comics
              ? 'blockedCommentWords'
              : 'blockedWords'],
          isEmpty,
        );
      },
    );
  }

  test('reads follow the injected owner and return a detached list', () {
    var current = _Settings()
      ..['blockedWords'] = [' first ', '', 'first', 'first'];
    final store = KeywordSettingsStore(
      readSettings: () => current,
      updateSettings: (_) => throw StateError('read only'),
    );
    final view = store.read(BlockedKeywordList.comics);
    expect(view, [' first ', '', 'first', 'first']);
    expect(store.contains(BlockedKeywordList.comics, ' first '), isTrue);
    expect(store.contains(BlockedKeywordList.comments, 'first'), isFalse);
    view.clear();
    expect(current['blockedWords'], [' first ', '', 'first', 'first']);
    current = _Settings()..['blockedWords'] = ['replacement'];
    expect(store.read(BlockedKeywordList.comics), ['replacement']);
  });

  test(
    'errors and stack survive; explicit retry reads the new draft',
    () async {
      final draft = _Settings()..['blockedWords'] = ['old'];
      final error = StateError('write failed');
      final stack = StackTrace.fromString('original persistence stack');
      var shouldFail = true;
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) {
          if (shouldFail) return Future<void>.error(error, stack);
          change(draft);
          return Future.value();
        },
      );
      try {
        await store.setBlocked(BlockedKeywordList.comics, 'new', true);
        fail('must propagate failure');
      } catch (caught, caughtStack) {
        expect(caught, same(error));
        expect(caughtStack.toString(), stack.toString());
      }
      expect(draft['blockedWords'], ['old']);
      draft['blockedWords'] = ['concurrent'];
      shouldFail = false;
      await store.setBlocked(BlockedKeywordList.comics, 'new', true);
      expect(draft['blockedWords'], ['concurrent', 'new']);
    },
  );

  test(
    'membership preserves case, whitespace, empty words and unrelated keys',
    () async {
      final draft = _Settings()..['extension'] = {'enabled': true};
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async => change(draft),
      );
      for (final word in [' A ', 'a', '', 'a']) {
        await store.setBlocked(BlockedKeywordList.comments, word, true);
      }
      await store.setBlocked(BlockedKeywordList.comments, 'missing', false);
      expect(draft['blockedCommentWords'], [' A ', 'a', '']);
      expect(draft['blockedWords'], isEmpty);
      expect(draft['extension'], {'enabled': true});
    },
  );

  test(
    'invalid legacy lists have a safe view and repair only the edited field',
    () async {
      final draft = _Settings();
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async => change(draft),
      );
      for (final value in [
        null,
        'invalid',
        <Object>['word', 1],
      ]) {
        draft['blockedWords'] = value;
        draft['blockedCommentWords'] = value;
        expect(
          store.read(BlockedKeywordList.comics),
          value is List ? ['word'] : [],
        );
        expect(
          store.contains(BlockedKeywordList.comics, 'word'),
          value is List,
        );
        expect(draft['blockedWords'], same(value));
        await store.setBlocked(BlockedKeywordList.comics, 'new', true);
        expect(draft['blockedWords'], [if (value is List) 'word', 'new']);
        expect(draft['blockedCommentWords'], same(value));
      }
    },
  );
}
