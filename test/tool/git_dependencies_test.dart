import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import '../../tool/check_git_dependencies.dart';

void main() {
  late Map spec;
  late Map lock;
  late Map inventory;

  setUp(() {
    // Round-trip YAML to obtain mutable fixture maps.
    spec =
        jsonDecode(
              jsonEncode(loadYaml(File('pubspec.yaml').readAsStringSync())),
            )
            as Map;
    lock =
        jsonDecode(
              jsonEncode(loadYaml(File('pubspec.lock').readAsStringSync())),
            )
            as Map;
    inventory =
        jsonDecode(
              File('doc/development/git_dependencies.json').readAsStringSync(),
            )
            as Map;
  });

  test('current declarations and transitive packages match review', () {
    expect(checkGitDependencies(spec, lock, inventory), isEmpty);
  });

  test('rejects a floating branch and changed dependency origin', () {
    spec['dependencies']['flutter_qjs']['git']['ref'] = 'main';
    spec['dependencies']['webdav_client']['git']['url'] =
        'https://example.com/fork';
    final errors = checkGitDependencies(spec, lock, inventory);
    expect(errors.any((e) => e.startsWith('flutter_qjs:')), isTrue);
    expect(errors.any((e) => e.startsWith('webdav_client:')), isTrue);
  });

  test('detects platform package left on upstream and resolved SHA drift', () {
    final packages = lock['packages'];
    packages['flutter_inappwebview_windows']['description']['url'] =
        'https://github.com/venera-app/flutter_inappwebview';
    packages['flutter_inappwebview_ios']['description']['resolved-ref'] =
        'other';
    final errors = checkGitDependencies(spec, lock, inventory);
    expect(
      errors.any((e) => e.startsWith('flutter_inappwebview_windows:')),
      isTrue,
    );
    expect(
      errors.any((e) => e.startsWith('flutter_inappwebview_ios:')),
      isTrue,
    );
  });

  test('rejects unreviewed packages and missing locked packages', () {
    spec['dependencies']['new_plugin'] = {'git': 'https://example.com/new'};
    lock['packages']['unknown'] = {
      'source': 'git',
      'description': {'url': 'https://example.com/new'},
    };
    lock['packages'].remove('flutter_qjs');
    final errors = checkGitDependencies(spec, lock, inventory);
    expect(errors.any((e) => e.startsWith('new_plugin:')), isTrue);
    expect(errors.any((e) => e.startsWith('unknown:')), isTrue);
    expect(errors.any((e) => e.startsWith('flutter_qjs:')), isTrue);
  });
}
