import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

YamlMap workflow(String name) =>
    loadYaml(File('.github/workflows/$name.yml').readAsStringSync()) as YamlMap;

List<YamlMap> steps(YamlMap job) => (job['steps'] as YamlList).cast<YamlMap>();

List<String> runs(YamlMap job) => steps(job)
    .where((step) => step.containsKey('run'))
    .map((step) => step['run'] as String)
    .toList();

int commandIndex(YamlMap job, String command) {
  final matches = steps(job).indexed
      .where(
        (entry) =>
            entry.$2['run'] is String &&
            (entry.$2['run'] as String).contains(command),
      )
      .toList();
  expect(matches, hasLength(1), reason: 'Expected one step for $command');
  return matches.single.$1;
}

YamlMap commandStep(YamlMap job, String command) =>
    steps(job)[commandIndex(job, command)];

Set<String> needs(YamlMap job) => switch (job['needs']) {
  String value => {value},
  YamlList values => values.cast<String>().toSet(),
  _ => <String>{},
};

void main() {
  final main = workflow('main');
  final mainJobs = main['jobs'] as YamlMap;
  final release = mainJobs['Release'] as YamlMap;
  final harmony = workflow('harmonyos-release');
  final harmonyJobs = (harmony['jobs'] as YamlMap).values
      .cast<YamlMap>()
      .toList();

  test('release waits for quality, every platform and the mandatory HAP', () {
    expect(needs(release), {
      'Release_Metadata',
      'Quality',
      'Build',
      'HarmonyOS',
    });
    final hap = mainJobs['HarmonyOS'] as YamlMap;
    expect(needs(hap), {'Release_Metadata', 'Quality'});
    expect(hap['uses'], './.github/workflows/harmonyos-release.yml');
    expect(hap.containsKey('if'), isFalse);
    expect(hap.containsKey('continue-on-error'), isFalse);
    expect((mainJobs['Build'] as YamlMap)['with']['quality_checked'], isTrue);
    expect(
      (main['on'] as YamlMap).keys,
      containsAll(['push', 'workflow_dispatch']),
    );
  });

  test(
    'release source, HAP source, notes and collected assets remain bound',
    () {
      expect(release['defaults']['run']['working-directory'], 'release-source');
      final checkouts = steps(release)
          .where(
            (step) =>
                step['uses'] is String &&
                (step['uses'] as String).startsWith('actions/checkout@'),
          )
          .toList();
      expect(checkouts.map((step) => step['with']['path']), [
        'release-source',
        'harmonyos-source',
      ]);
      expect(
        commandStep(release, '--write-notes')['run'],
        contains('--write-notes ../release_notes.md'),
      );
      final draft = commandStep(release, 'prepare-draft')['run'] as String;
      expect(
        draft,
        contains(
          '--source-root ../harmonyos-source --artifacts ../outputs/harmonyos',
        ),
      );
      expect(draft, contains('--notes-file ../release_notes.md'));
      expect(draft, contains(r'--release-files "${files[@]}"'));
      expect(draft, contains('../outputs/harmonyos/*'));
      expect(
        commandStep(release, 'android_tv_build.py verify-release')['run'],
        contains('--directory ../outputs'),
      );
      expect(
        commandIndex(release, 'android_tv_build.py verify-release'),
        lessThan(commandIndex(release, 'prepare-draft')),
      );
    },
  );

  test(
    'draft and runtime verification precede publication and postchecks follow',
    () {
      final publication = commandIndex(release, '--draft=false');
      expect(commandIndex(release, 'verify-draft'), lessThan(publication));
      expect(commandIndex(release, 'verify-runtime'), lessThan(publication));
      expect(
        commandIndex(release, 'verify-published'),
        greaterThan(publication),
      );
      final runtime = commandStep(release, 'verify-runtime');
      expect(runtime['id'], 'harmonyos_runtime');
      expect(
        runtime['run'],
        contains(r'--allow-pending --github-output "$GITHUB_OUTPUT"'),
      );
      final gated = steps(release)
          .where(
            (step) =>
                step['if'] is String &&
                (step['if'] as String).contains(
                  "steps.harmonyos_runtime.outputs.ready == 'true'",
                ),
          )
          .toList();
      expect(gated, hasLength(3));
      expect(
        commandStep(release, '--draft=false')['if'],
        contains("steps.harmonyos_runtime.outputs.ready == 'true'"),
      );
      expect(
        commandStep(release, 'verify-published')['if'],
        contains("steps.harmonyos_runtime.outputs.ready == 'true'"),
      );
    },
  );

  test(
    'HAP uses pinned source, complete history and read-only mandatory uploads',
    () {
      expect(harmony['permissions']['contents'], 'read');
      expect((harmony['on'] as YamlMap).containsKey('workflow_call'), isTrue);
      final checkouts = harmonyJobs
          .expand(steps)
          .where(
            (step) =>
                step['uses'] is String &&
                (step['uses'] as String).startsWith('actions/checkout@'),
          )
          .toList();
      expect(
        checkouts.every((step) => step['with']['fetch-depth'] == 0),
        isTrue,
      );
      expect(
        checkouts.any(
          (step) =>
              step['with']['ref'] == r'${{ steps.pin.outputs.source_commit }}',
        ),
        isTrue,
      );
      for (final job in harmonyJobs) {
        expect(job.containsKey('continue-on-error'), isFalse);
        expect(job['secrets'], isNot('inherit'));
        expect(job['permissions']?['contents'], isNot('write'));
        for (final step in steps(job)) {
          expect(step.containsKey('continue-on-error'), isFalse);
        }
      }
      final upload = harmonyJobs
          .expand(steps)
          .firstWhere((step) => step['with']?['name'] == 'harmonyos-release');
      expect(upload['with']['if-no-files-found'], 'error');
    },
  );

  test(
    'device acceptance stays a separate exact-HAP template and no issue messages are sent',
    () {
      final template = harmonyJobs
          .expand(steps)
          .firstWhere(
            (step) =>
                step['with']?['name'] ==
                'harmonyos-runtime-acceptance-template',
          );
      expect(
        template['with']['path'],
        contains('ci/runtime-acceptance/harmonyos-runtime-acceptance.json'),
      );
      expect(template['with']['if-no-files-found'], 'error');
      final commands = [
        ...mainJobs.values
            .cast<YamlMap>()
            .where((job) => job.containsKey('steps'))
            .expand(runs),
        ...harmonyJobs.expand(runs),
      ];
      expect(commands.every((run) => !run.contains('gh issue')), isTrue);
    },
  );

  test(
    'mobile and TV builds use real flavors, quality and separate asset manifests',
    () {
      final build = workflow('build');
      final android = (build['jobs'] as YamlMap)['Build_Android'] as YamlMap;
      expect((android['strategy']['matrix']['flavor'] as YamlList).toSet(), {
        'mobile',
        'tv',
      });
      expect(
        runs(android).join('\n'),
        contains('flutter build apk --release --flavor mobile'),
      );
      expect(
        runs(android).join('\n'),
        contains('flutter build apk --release --flavor tv'),
      );
      expect(runs(android).join('\n'), isNot(contains('--build-number')));
      expect(build.toString(), isNot(contains('inputs.android_flavor')));
      expect(
        steps(android).any(
          (step) =>
              step['with']?['name'] == r'android-${{ matrix.flavor }}-manifest',
        ),
        isTrue,
      );
      final quality = (build['jobs'] as YamlMap)['Manual_Quality'] as YamlMap;
      expect(
        quality['if'],
        contains('inputs.build_android && !inputs.quality_checked'),
      );
      expect(quality['uses'], './.github/workflows/analyze.yml');
      expect(needs(android), {'Manual_Quality'});
      expect(
        android['if'],
        contains("needs.Manual_Quality.result == 'success'"),
      );
      final patterns = steps(
        release,
      ).map((step) => step['with']?['pattern']).whereType<String>().toSet();
      expect(
        patterns,
        containsAll(['apk-*', 'tv-apk-*', 'android-*-manifest']),
      );
      expect(
        File('pubspec.yaml').readAsStringSync(),
        isNot(contains('default-flavor:')),
      );
    },
  );

  test(
    'platform gate depends on every build and executes the checked state contract',
    () {
      final smoke = workflow('pr_build');
      final jobs = smoke['jobs'] as YamlMap;
      expect(
        (jobs['android']['strategy']['matrix']['flavor'] as YamlList).toSet(),
        {'mobile', 'tv'},
      );
      final gate = jobs['platform_gate'] as YamlMap;
      expect(
        needs(gate),
        containsAll(['changes', 'android', 'windows', 'desktop']),
      );
      expect(gate['if'], contains('always()'));
      expect(runs(gate), contains('bash .github/scripts/pr_platform_gate.sh'));
      expect(File('.github/scripts/pr_platform_gate.sh').existsSync(), isTrue);
      final gateStep = commandStep(
        gate,
        'bash .github/scripts/pr_platform_gate.sh',
      );
      expect(gateStep['env'], {
        'CHANGES_RESULT': r'${{ needs.changes.result }}',
        'PLATFORM_REQUIRED': r'${{ needs.changes.outputs.platform }}',
        'DESKTOP_REQUIRED': r'${{ needs.changes.outputs.desktop }}',
        'ANDROID_RESULT': r'${{ needs.android.result }}',
        'WINDOWS_RESULT': r'${{ needs.windows.result }}',
        'DESKTOP_RESULT': r'${{ needs.desktop.result }}',
      });
      expect(
        steps(gate)
            .take(
              commandIndex(gate, 'bash .github/scripts/pr_platform_gate.sh'),
            )
            .any(
              (step) =>
                  step['uses'] is String &&
                  (step['uses'] as String).startsWith('actions/checkout@'),
            ),
        isTrue,
      );
      final windows = jobs['windows'] as YamlMap;
      final ownership = commandStep(
        windows,
        'cmake -S packages/share_plus/windows/tests',
      );
      expect(ownership['shell'], 'pwsh');
      expect(
        ownership['run'],
        contains(r'$PSNativeCommandUseErrorActionPreference = $true'),
      );
      expect(
        ownership['run'],
        contains(
          'ctest --test-dir build/share-plus-tests -C Debug --output-on-failure',
        ),
      );
      expect(
        commandIndex(windows, 'flutter build windows --debug'),
        lessThan(
          commandIndex(windows, 'cmake -S packages/share_plus/windows/tests'),
        ),
      );
    },
  );
  test('default coverage keeps every group behind a stable always gate', () {
    final jobs = workflow('analyze')['jobs'] as YamlMap;
    final gate = jobs['flutter-tests'] as YamlMap;
    expect(gate['name'], 'Flutter 测试与覆盖率');
    expect(gate['if'], contains('always()'));
    expect(needs(gate), {
      'flutter-fast',
      'flutter-native',
      'flutter-full',
      'flutter-tv',
    });
    expect(gate.containsKey('continue-on-error'), isFalse);
    final aggregation = commandStep(gate, 'aggregate_flutter_tests.py');
    expect(aggregation['if'], contains('always()'));
    expect(aggregation['env']['REQUIRED_RESULTS'], r'${{ toJSON(needs) }}');
    expect(aggregation.containsKey('continue-on-error'), isFalse);
    final download = steps(
      gate,
    ).firstWhere((step) => step['with']?['pattern'] == 'flutter-default-*');
    expect(download['with']['merge-multiple'], isFalse);
    expect(download['with']['path'], 'build/test-audit/collected');
    final tvDownload = steps(
      gate,
    ).singleWhere((step) => step['with']?['name'] == 'flutter-tv-test-runs');
    expect(
      tvDownload['with']['path'],
      'build/test-audit/collected/flutter-tv-test-runs',
    );
    expect(
      steps(gate).indexOf(tvDownload),
      lessThan(commandIndex(gate, 'aggregate_flutter_tests.py')),
    );
    final full = jobs['flutter-full'] as YamlMap;
    expect(full['strategy']['fail-fast'], isFalse);
    final config =
        jsonDecode(File('test/suites.json').readAsStringSync())
            as Map<String, dynamic>;
    final count = config['default_execution']['shards'] as int;
    expect((full['strategy']['matrix']['partition'] as YamlList).toSet(), {
      for (var index = 1; index <= count; index++) 'shard-$index',
    });
    for (final name in ['flutter-fast', 'flutter-full']) {
      final run =
          commandStep(jobs[name] as YamlMap, 'run_flutter_tests.py')['run']
              as String;
      expect(run, contains('--partition'));
      expect(run, contains('--coverage'));
      expect(run, contains('--coverage-path'));
    }
  });

  test(
    'native ABI, memory safety and real TV retain verified libraries and the pinned SDK',
    () {
      final jobs = workflow('analyze')['jobs'] as YamlMap;
      expect(needs(jobs['flutter-fast'] as YamlMap), isEmpty);
      final native = jobs['flutter-native'] as YamlMap;
      expect(needs(native), {'rhttp-native'});
      for (final name in [
        'flutter-fast',
        'flutter-native',
        'flutter-full',
        'flutter-tv',
      ]) {
        final job = jobs[name] as YamlMap;
        expect(job['env']['VENERA_REQUIRE_NATIVE_TEST_LIBRARIES'], '1');
        expect(job.containsKey('continue-on-error'), isFalse);
        final sdk = steps(job).singleWhere(
          (step) =>
              step['uses'] is String &&
              (step['uses'] as String).startsWith('subosito/flutter-action@'),
        );
        expect(sdk['with']['channel'], 'stable');
        expect(sdk['with']['flutter-version-file'], 'pubspec.yaml');
        expect(sdk['with']['architecture'], 'x64');
        for (final step in steps(job)) {
          expect(step.containsKey('continue-on-error'), isFalse);
        }
      }
      for (final flag in [
        '-DVENERA_NATIVE_BUILD_TESTS=ON',
        '-DVENERA_SAF_BUILD_TESTS=ON',
      ]) {
        final step = commandStep(native, flag);
        expect(step['run'], contains('-fsanitize=address,undefined'));
        expect(step['run'], contains('ctest'));
        expect(step['env']['ASAN_OPTIONS'], contains('halt_on_error=1'));
        expect(step['env']['UBSAN_OPTIONS'], contains('halt_on_error=1'));
        expect(step.containsKey('if'), isFalse);
      }
      for (final name in ['flutter-full', 'flutter-tv']) {
        final job = jobs[name] as YamlMap;
        expect(needs(job), {'flutter-native'});
        expect(
          steps(job).any(
            (step) => step['with']?['name'] == 'linux-flutter-test-libraries',
          ),
          isTrue,
        );
        expect(
          commandStep(job, 'prepare_linux_test_libraries.py')['run'],
          contains('--verify-only'),
        );
      }
      expect(
        commandStep(
          jobs['flutter-tv'] as YamlMap,
          'run_flutter_tests.py',
        )['run'],
        contains('--suite tv'),
      );
    },
  );
}
