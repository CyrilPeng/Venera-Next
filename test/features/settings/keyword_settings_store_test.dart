import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/keyword_settings_store.dart';
import 'package:venera_next/foundation/keyword_filter.dart';
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
  const newRule = KeywordRule('bl', mode: KeywordMatchMode.wholeWord);
  test(
    'quick rules capture their options and keep concurrently existing rules',
    () async {
      final draft = _Settings()
        ..['blockedWords'] = ['BL']
        ..['blockedWordRules'] = {'BL': 'contains:sensitive'};
      final admission = Completer<void>();
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async {
          await admission.future;
          change(draft);
        },
      );
      final selection = [
        KeywordRule.suggested('BL'),
        KeywordRule.suggested('genre:bl', tag: true),
        KeywordRule.suggested('GL'),
      ];
      final save = store.blockRules(BlockedKeywordList.comics, selection);
      selection.add(const KeywordRule('late'));
      draft['blockedWords'] = ['BL', 'GL'];
      draft['blockedWordRules'] = {
        'BL': 'contains:sensitive',
        'GL': 'wholeWord:sensitive',
      };
      admission.complete();
      await save;
      expect(draft['blockedWords'], ['BL', 'GL', 'genre:bl']);
      expect(draft['blockedWordRules'], {
        'BL': 'contains:sensitive',
        'GL': 'wholeWord:sensitive',
        'genre:bl': 'exactTag:insensitive',
      });
      await store.blockRules(BlockedKeywordList.comics, [
        KeywordRule.suggested('BL'),
      ]);
      expect(
        store.ruleFor(BlockedKeywordList.comics, 'BL')?.caseSensitive,
        isTrue,
      );
    },
  );
  test(
    'unchanged legacy edits preserve unknown option data and duplicate words',
    () async {
      final draft = _Settings()
        ..['blockedWords'] = [' bl ', 'bl', 'bl']
        ..['blockedWordRules'] = {'bl': 'future:unknown', 'other': 'keep'};
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async => change(draft),
      );
      final original = store.ruleFor(BlockedKeywordList.comics, 'bl')!;
      expect(
        await store.saveRule(
          BlockedKeywordList.comics,
          original,
          replacing: original,
        ),
        KeywordRuleSaveResult.saved,
      );
      expect(draft['blockedWords'], [' bl ', 'bl', 'bl']);
      expect(draft['blockedWordRules'], {
        'bl': 'future:unknown',
        'other': 'keep',
      });
    },
  );
  test(
    'new rule options accompany strings and leave unrelated settings alone',
    () async {
      final draft = _Settings()
        ..['blockedWords'] = ['old', 'old']
        ..['blockedWordRules'] = {
          'old': 'contains:sensitive',
          'future': 'unknown:option',
        }
        ..['blockedCommentWordRules'] = {'comment': 'contains:insensitive'}
        ..['extension'] = {'enabled': true};
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async => change(draft),
      );
      expect(
        await store.saveRule(BlockedKeywordList.comics, newRule),
        KeywordRuleSaveResult.saved,
      );
      expect(draft['blockedWords'], ['old', 'old', 'bl']);
      expect(draft['blockedWordRules'], {
        'old': 'contains:sensitive',
        'future': 'unknown:option',
        'bl': 'wholeWord:insensitive',
      });
      expect(draft['blockedCommentWordRules'], {
        'comment': 'contains:insensitive',
      });
      expect(draft['extension'], {'enabled': true});
      expect(store.ruleFor(BlockedKeywordList.comics, 'bl'), newRule);
    },
  );

  test(
    'editing renames the captured rule while retaining its list position',
    () async {
      final draft = _Settings()
        ..['blockedWords'] = ['first', 'bl', 'bl', 'last'];
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async => change(draft),
      );
      const replacement = KeywordRule('BL', mode: KeywordMatchMode.wholeWord);
      expect(
        await store.saveRule(
          BlockedKeywordList.comics,
          replacement,
          replacing: const KeywordRule.legacy('bl'),
        ),
        KeywordRuleSaveResult.saved,
      );
      expect(draft['blockedWords'], ['first', 'BL', 'BL', 'last']);
      expect(draft['blockedWordRules'], {'BL': 'wholeWord:insensitive'});
      expect(
        await store.saveRule(
          BlockedKeywordList.comics,
          const KeywordRule('first'),
          replacing: replacement,
        ),
        KeywordRuleSaveResult.duplicate,
      );
      expect(draft['blockedWords'], ['first', 'BL', 'BL', 'last']);
    },
  );

  for (final deleted in [false, true]) {
    test(
      'stale rule edits cannot overwrite or recreate a rule: deleted=$deleted',
      () async {
        final draft = _Settings()..['blockedWords'] = ['bl', 'keep'];
        final admission = Completer<void>();
        final store = KeywordSettingsStore(
          readSettings: () => draft,
          updateSettings: (change) async {
            await admission.future;
            change(draft);
          },
        );
        final save = store.saveRule(
          BlockedKeywordList.comics,
          newRule,
          replacing: const KeywordRule.legacy('bl'),
        );
        if (deleted) {
          draft['blockedWords'] = ['keep'];
        } else {
          draft['blockedWordRules'] = {'bl': 'exactTag:insensitive'};
        }
        admission.complete();
        expect(await save, KeywordRuleSaveResult.changed);
        expect(draft['blockedWords'], deleted ? ['keep'] : ['bl', 'keep']);
        expect(
          draft['blockedWordRules'],
          deleted ? null : {'bl': 'exactTag:insensitive'},
        );
      },
    );
  }

  test(
    'a failed rename retries the final value and preserves subsequent edits',
    () async {
      final draft = _Settings()..['blockedWords'] = ['bl'];
      var failSave = true;
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async {
          change(draft);
          if (failSave) throw StateError('disk failed after publishing');
        },
      );
      const replacement = KeywordRule('BL', mode: KeywordMatchMode.wholeWord);
      Future<KeywordRuleSaveResult> save() => store.saveRule(
        BlockedKeywordList.comics,
        replacement,
        replacing: const KeywordRule.legacy('bl'),
      );
      await expectLater(save(), throwsStateError);
      draft['blockedWords'] = ['concurrent', ...draft['blockedWords'] as List];
      failSave = false;
      expect(await save(), KeywordRuleSaveResult.saved);
      expect(draft['blockedWords'], ['concurrent', 'BL']);
      expect(draft['blockedWordRules'], {'BL': 'wholeWord:insensitive'});
      draft['blockedWordRules'] = {'BL': 'exactTag:insensitive'};
      expect(await save(), KeywordRuleSaveResult.changed);
      expect(draft['blockedWordRules'], {'BL': 'exactTag:insensitive'});
    },
  );

  test(
    'captured deletion protects a changed rule and retries without side effects',
    () async {
      final draft = _Settings()
        ..['blockedWords'] = ['bl', 'keep']
        ..['blockedWordRules'] = {
          'bl': 'exactTag:insensitive',
          'keep': 'wholeWord:sensitive',
        };
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async => change(draft),
      );
      expect(
        await store.removeRule(BlockedKeywordList.comics, newRule),
        isFalse,
      );
      expect(draft['blockedWords'], ['bl', 'keep']);
      const expected = KeywordRule('bl', mode: KeywordMatchMode.exactTag);
      expect(
        await store.removeRule(BlockedKeywordList.comics, expected),
        isTrue,
      );
      expect(
        await store.removeRule(BlockedKeywordList.comics, expected),
        isTrue,
      );
      expect(draft['blockedWords'], ['keep']);
      expect(draft['blockedWordRules'], {'keep': 'wholeWord:sensitive'});
    },
  );

  test(
    'quick blocking preserves customized existing rules and removes their options on unblock',
    () async {
      final draft = _Settings()
        ..['blockedWords'] = ['bl']
        ..['blockedWordRules'] = {'bl': 'wholeWord:insensitive'};
      final store = KeywordSettingsStore(
        readSettings: () => draft,
        updateSettings: (change) async => change(draft),
      );
      await store.blockAll(BlockedKeywordList.comics, ['bl', 'new']);
      expect(store.ruleFor(BlockedKeywordList.comics, 'bl'), newRule);
      expect(store.ruleFor(BlockedKeywordList.comics, 'new')?.isLegacy, isTrue);
      await store.setBlocked(BlockedKeywordList.comics, 'bl', false);
      expect(draft['blockedWords'], ['new']);
      expect(draft['blockedWordRules'], isEmpty);
    },
  );
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
