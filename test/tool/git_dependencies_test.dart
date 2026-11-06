import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
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

  test('current Git and local packages, sources and licenses match review', () {
    expect(checkDependencyInventory(spec, lock, inventory), isEmpty);
  });

  test('rejects a floating branch and changed dependency origin', () {
    spec['dependencies']['flutter_qjs']['git']['ref'] = 'main';
    spec['dependencies']['desktop_webview_window']['git']['url'] =
        'https://example.com/fork';
    final errors = checkDependencyInventory(spec, lock, inventory);
    expect(errors.any((e) => e.startsWith('flutter_qjs:')), isTrue);
    expect(errors.any((e) => e.startsWith('desktop_webview_window:')), isTrue);
  });

  test('detects platform package left on upstream and resolved SHA drift', () {
    final packages = lock['packages'];
    packages['flutter_inappwebview_windows']['description']['url'] =
        'https://github.com/venera-app/flutter_inappwebview';
    packages['flutter_inappwebview_ios']['description']['resolved-ref'] =
        'other';
    final errors = checkDependencyInventory(spec, lock, inventory);
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
    final errors = checkDependencyInventory(spec, lock, inventory);
    expect(errors.any((e) => e.startsWith('new_plugin:')), isTrue);
    expect(errors.any((e) => e.startsWith('unknown:')), isTrue);
    expect(errors.any((e) => e.startsWith('flutter_qjs:')), isTrue);
  });

  Map local(String name) =>
      (inventory['local_packages'] as List).firstWhere(
            (record) => record['dependency'] == name,
          )
          as Map;

  test(
    'rejects direct, override and transitive local packages without review',
    () {
      spec['dependencies']['new_plugin'] = {'path': 'packages/new_plugin'};
      spec['dependency_overrides']['dio'] = {'path': 'packages/dio'};
      lock['packages']['unknown'] = {
        'source': 'path',
        'description': {'path': 'packages/unknown', 'relative': true},
        'version': '1.0.0',
      };
      final errors = checkDependencyInventory(spec, lock, inventory);
      for (final name in ['new_plugin', 'dio', 'unknown']) {
        expect(errors.any((error) => error.startsWith('$name:')), isTrue);
      }
    },
  );

  test('detects local declaration, locked path, version and source drift', () {
    spec['dependencies']['webdav_client']['path'] = 'packages/another_client';
    lock['packages']['photo_view']['version'] = '0.15.0';
    lock['packages']['share_plus']['description']['relative'] = false;
    lock['packages']['rhttp']['source'] = 'hosted';
    final errors = checkDependencyInventory(spec, lock, inventory);
    for (final name in ['webdav_client', 'photo_view', 'share_plus', 'rhttp']) {
      expect(errors.any((error) => error.startsWith('$name:')), isTrue);
    }
  });

  test('detects missing local review and missing local lock entries', () {
    (inventory['local_packages'] as List).removeWhere(
      (record) => record['dependency'] == 'share_plus',
    );
    lock['packages'].remove('webdav_client');
    final errors = checkDependencyInventory(spec, lock, inventory);
    expect(errors.any((error) => error.startsWith('share_plus:')), isTrue);
    expect(errors.any((error) => error.startsWith('webdav_client:')), isTrue);
  });

  test('requires immutable Git/archive provenance and a recorded upstream', () {
    local('photo_view')['source']['commit'] = 'main';
    local('rhttp')['source'].remove('sha256');
    local('webdav_client').remove('upstream');
    final errors = checkDependencyInventory(spec, lock, inventory);
    expect(
      errors,
      contains('photo_view: source must pin a full Git SHA and package path'),
    );
    expect(errors, contains('rhttp: source archive needs a SHA-256 checksum'));
    expect(errors, contains('webdav_client: record the original upstream URL'));
  });

  test('requires local maintenance, license and patch records', () {
    local('photo_view')['reason'] = ' ';
    local('share_plus')['status'] = 'license-review';
    local('rhttp').remove('license');
    local('webdav_client').remove('patches');
    final errors = checkDependencyInventory(spec, lock, inventory);
    for (final name in ['photo_view', 'share_plus', 'rhttp', 'webdav_client']) {
      expect(errors.any((error) => error.startsWith('$name:')), isTrue);
    }
  });

  for (final invalidPath in [
    '/tmp/external',
    'C:/external',
    'packages/../external',
    'packages//plugin',
    r'packages\plugin',
  ]) {
    test(
      'rejects local package path outside the reviewed tree: $invalidPath',
      () {
        local('webdav_client')['path'] = invalidPath;
        expect(
          checkDependencyInventory(spec, lock, inventory),
          contains(
            'webdav_client: local package path must stay under packages/',
          ),
        );
      },
    );
  }

  test('rejects traversal in license and patch paths', () {
    local('photo_view')['license']['file'] = '../LICENSE';
    local('share_plus')['patches'] = '../../CHANGELOG.md';
    final errors = checkDependencyInventory(spec, lock, inventory);
    expect(errors, contains('photo_view: invalid local file path ../LICENSE'));
    expect(
      errors,
      contains('share_plus: invalid local file path ../../CHANGELOG.md'),
    );
  });

  test('rejects duplicate local dependency and package path records', () {
    final duplicate = jsonDecode(jsonEncode(local('webdav_client'))) as Map;
    (inventory['local_packages'] as List).add(duplicate);
    final errors = checkDependencyInventory(spec, lock, inventory);
    expect(
      errors,
      contains('webdav_client: duplicate local inventory package'),
    );
    expect(errors, contains('webdav_client: duplicate local package path'));
  });

  group('local files', () {
    late _LocalFixture fixture;

    setUp(() {
      fixture = _LocalFixture(local('webdav_client'));
    });

    test('accepts a fresh source copy and canonical LF license hashes', () {
      final license = fixture.file('LICENSE');
      license.writeAsStringSync(
        license
            .readAsStringSync()
            .replaceAll('\r\n', '\n')
            .replaceAll('\n', '\r\n'),
      );
      expect(fixture.check(), isEmpty);
    });

    test('rejects missing license and patch files', () {
      fixture.file('LICENSE').deleteSync();
      fixture.file('LOCAL_PATCHES.md').deleteSync();
      final errors = fixture.check();
      expect(errors, contains('webdav_client: missing local file LICENSE'));
      expect(
        errors,
        contains('webdav_client: missing local file LOCAL_PATCHES.md'),
      );
    });

    test('rejects altered license and local package version', () {
      fixture.file('LICENSE').writeAsStringSync('different license');
      fixture
          .file('pubspec.yaml')
          .writeAsStringSync('name: webdav_client\nversion: 2.0.0\n');
      final errors = fixture.check();
      expect(
        errors,
        contains(
          'webdav_client: local license differs from the reviewed checksum',
        ),
      );
      expect(
        errors,
        contains(
          'webdav_client: local pubspec name or version differs from review',
        ),
      );
    });

    test('rejects patch notes that lose their source baseline', () {
      fixture.file('LOCAL_PATCHES.md').writeAsStringSync('Local patch 1.2.2');
      expect(
        fixture.check(),
        contains(
          'webdav_client: patch notes must identify the source and version',
        ),
      );
    });

    test('rejects changed runtime source and unrecorded Dart files', () {
      fixture
          .file('lib/src/client.dart')
          .writeAsStringSync('// changed runtime');
      fixture.file('lib/unreviewed.dart').writeAsStringSync('// extra runtime');
      final errors = fixture.check();
      expect(
        errors,
        contains(
          'webdav_client: local source changed without review: lib/src/client.dart',
        ),
      );
      expect(
        errors,
        contains(
          'webdav_client: local Dart file has no source record: lib/unreviewed.dart',
        ),
      );
    });

    test('rejects source manifests with a different original commit', () {
      final file = fixture.file('UPSTREAM_MANIFEST.json');
      final manifest = jsonDecode(file.readAsStringSync()) as Map;
      manifest['source']['commit'] = '0000000000000000000000000000000000000000';
      file.writeAsStringSync(jsonEncode(manifest));
      expect(
        fixture.check(),
        contains(
          'webdav_client: source manifest does not match reviewed provenance',
        ),
      );
    });

    test('reports malformed source and package manifests without throwing', () {
      fixture.file('UPSTREAM_MANIFEST.json').writeAsStringSync('{');
      fixture.file('pubspec.yaml').writeAsStringSync('name: [');
      final errors = fixture.check();
      expect(errors, contains('webdav_client: cannot parse source manifest'));
      expect(errors, contains('webdav_client: cannot parse local pubspec'));
    });

    test(
      'rejects a symlink outside the reviewed package',
      () {
        final outside = File(path.join(fixture.root.path, 'outside-license'));
        outside.writeAsStringSync(fixture.file('LICENSE').readAsStringSync());
        final license = fixture.file('LICENSE');
        license.deleteSync();
        Link(license.path).createSync(outside.absolute.path);
        final outsideLib = Directory(
          path.join(fixture.root.path, 'outside-lib'),
        )..createSync();
        File(
          path.join(outsideLib.path, 'unreviewed.dart'),
        ).writeAsStringSync('// external source');
        Link(
          fixture.file('lib/extra').path,
        ).createSync(outsideLib.absolute.path);
        final errors = fixture.check();
        expect(
          errors,
          contains(
            'webdav_client: local file escapes the reviewed package: LICENSE',
          ),
        );
        expect(
          errors,
          contains(
            'webdav_client: local source tree contains a link: lib/extra',
          ),
        );
      },
      skip: Platform.isWindows
          ? 'Windows symlinks require host privileges.'
          : false,
    );
  });
}

class _LocalFixture {
  _LocalFixture(Map reviewed) {
    final parent = Directory('build/dependency-vendoring/tests')
      ..createSync(recursive: true);
    root = parent.createTempSync('local-inventory-');
    addTearDown(() {
      if (!path.isWithin(
        parent.resolveSymbolicLinksSync(),
        root.resolveSymbolicLinksSync(),
      )) {
        throw StateError(
          'Refusing to remove a fixture outside its test directory',
        );
      }
      root.deleteSync(recursive: true);
    });
    final record = jsonDecode(jsonEncode(reviewed)) as Map;
    packagePath = record['path'] as String;
    final manifest =
        jsonDecode(
              File(
                path.join(packagePath, 'UPSTREAM_MANIFEST.json'),
              ).readAsStringSync(),
            )
            as Map;
    for (final relative in [
      ...(manifest['files'] as List).map((entry) => entry['path'] as String),
      'UPSTREAM_MANIFEST.json',
      'LOCAL_PATCHES.md',
    ]) {
      final destination = file(relative);
      destination.parent.createSync(recursive: true);
      File(path.join(packagePath, relative)).copySync(destination.path);
    }
    inventory = {
      'schema_version': 2,
      'repositories': [],
      'local_packages': [record],
    };
    spec = {
      'dependencies': {
        'webdav_client': {'path': packagePath},
      },
    };
    lock = {
      'packages': {
        'webdav_client': {
          'source': 'path',
          'description': {'path': packagePath, 'relative': true},
          'version': record['version'],
        },
      },
    };
  }

  late final Directory root;
  late final String packagePath;
  late final Map spec;
  late final Map lock;
  late final Map inventory;

  File file(String relative) =>
      File(path.join(root.path, packagePath, relative));

  List<String> check() =>
      checkDependencyInventory(spec, lock, inventory, root: root);
}
