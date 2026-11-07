import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
    spec['dependencies']['flutter_inappwebview']['git']['url'] =
        'https://example.com/fork';
    final errors = checkDependencyInventory(spec, lock, inventory);
    expect(errors.any((e) => e.startsWith('flutter_qjs:')), isTrue);
    expect(errors.any((e) => e.startsWith('flutter_inappwebview:')), isTrue);
  });

  test('detects platform source drift and a lost Windows patch override', () {
    final packages = lock['packages'];
    packages['flutter_inappwebview_android']['description']['url'] =
        'https://github.com/venera-app/flutter_inappwebview';
    packages['flutter_inappwebview_windows']['description']['path'] =
        'packages/unreviewed_windows';
    packages['flutter_inappwebview_ios']['description']['resolved-ref'] =
        'other';
    final errors = checkDependencyInventory(spec, lock, inventory);
    expect(
      errors.any((e) => e.startsWith('flutter_inappwebview_windows:')),
      isTrue,
    );
    expect(
      errors.any((e) => e.startsWith('flutter_inappwebview_android:')),
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

  test('requires evidence for necessary local and fork exceptions', () {
    local('rhttp')['official_review'].remove('exit_condition');
    local('photo_view')['official_review']['required_patches'] = [];
    inventory['repositories'][0].remove('official_review');
    final errors = checkDependencyInventory(spec, lock, inventory);
    for (final name in ['rhttp', 'photo_view', 'flutter_qjs']) {
      expect(errors.any((error) => error.startsWith('$name:')), isTrue);
    }
  });

  test('rejects a fork mislabeled as an official commit', () {
    final repo = (inventory['repositories'] as List).firstWhere(
      (repo) => repo['dependency'] == 'flutter_inappwebview',
    );
    repo['url'] = 'https://example.com/fork';
    expect(
      checkDependencyInventory(spec, lock, inventory),
      contains(
        'flutter_inappwebview: official commit must use the reviewed upstream URL',
      ),
    );
  });

  test('rejects a federated Git override drifting from the official group', () {
    spec['dependency_overrides']['flutter_inappwebview_platform_interface']['git']['ref'] =
        'main';
    expect(
      checkDependencyInventory(spec, lock, inventory),
      contains(
        'flutter_inappwebview_platform_interface: Git override differs from reviewed source',
      ),
    );
  });

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

    void registerNativeFixture() {
      final bytes = [0x4d, 0x5a, 0xff, 0x00, 0xfe];
      final native = fixture.file('windows/loader.dll');
      native.parent.createSync(recursive: true);
      native.writeAsBytesSync(bytes);
      final file = fixture.file('UPSTREAM_MANIFEST.json');
      final manifest = jsonDecode(file.readAsStringSync()) as Map;
      final digest = sha256.convert(bytes).toString();
      (manifest['files'] as List).add({
        'path': 'windows/loader.dll',
        'sha256': digest,
        'local_sha256': digest,
        'encoding': 'binary',
      });
      file.writeAsStringSync(jsonEncode(manifest));
      fixture.inventory['local_packages'][0]['source_directories'] = [
        'lib',
        'windows',
      ];
    }

    test('checks non-UTF8 binary sources and detects byte changes', () {
      registerNativeFixture();
      expect(fixture.check(), isEmpty);
      fixture.file('windows/loader.dll').writeAsBytesSync([0x4d, 0x5a, 0xff]);
      expect(
        fixture.check(),
        contains(
          'webdav_client: local source changed without review: windows/loader.dll',
        ),
      );
    });

    test('rejects unregistered native files inside reviewed directories', () {
      registerNativeFixture();
      fixture.file('windows/extra.cc').writeAsStringSync('// native source');
      expect(
        fixture.check(),
        contains(
          'webdav_client: local source file has no source record: windows/extra.cc',
        ),
      );
    });

    test('rejects unknown source encodings instead of skipping the file', () {
      registerNativeFixture();
      final file = fixture.file('UPSTREAM_MANIFEST.json');
      final manifest = jsonDecode(file.readAsStringSync()) as Map;
      (manifest['files'] as List).last['encoding'] = 'unverified';
      file.writeAsStringSync(jsonEncode(manifest));
      expect(
        fixture.check(),
        contains(
          'webdav_client: source manifest needs file paths and both checksums',
        ),
      );
    });

    test('requires lib and rejects unsafe or duplicate source directories', () {
      registerNativeFixture();
      final record = fixture.inventory['local_packages'][0] as Map;
      record['source_directories'] = ['windows'];
      expect(
        fixture.check(),
        contains('webdav_client: reviewed source directories must include lib'),
      );
      record['source_directories'] = [
        'lib',
        'windows',
        'windows',
        '../external',
      ];
      final errors = fixture.check();
      expect(
        errors,
        contains(
          'webdav_client: invalid or duplicate source directory windows',
        ),
      );
      expect(
        errors,
        contains(
          'webdav_client: invalid or duplicate source directory ../external',
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

  group('project-authored packages and third-party cores', () {
    late _LocalFixture fixture;
    late Map record;

    setUp(() {
      fixture = _LocalFixture(local('venera_native'));
      record = fixture.inventory['local_packages'][0] as Map;
    });

    void updateManifest(void Function(Map manifest) change) {
      final file = fixture.file('SOURCE_MANIFEST.json');
      final manifest = jsonDecode(file.readAsStringSync()) as Map;
      change(manifest);
      file.writeAsStringSync(jsonEncode(manifest));
    }

    test('accepts own code with separately pinned official native sources', () {
      expect(fixture.check(), isEmpty);
    });

    test('requires complete review rather than treating project as a bypass', () {
      record.remove('source_directories');
      expect(
        fixture.check(),
        contains(
          'venera_native: project source needs its own path, repository and full source manifest',
        ),
      );
    });

    test('rejects floating third-party provenance and missing license', () {
      final origins = record['third_party_sources'] as List;
      origins[0]['source']['commit'] = 'main';
      origins[1].remove('license');
      updateManifest((manifest) => manifest['third_party_sources'] = origins);
      final errors = fixture.check();
      expect(
        errors,
        contains(
          'venera_native: third-party source needs immutable Git/archive provenance: lodepng',
        ),
      );
      expect(
        errors,
        contains(
          'venera_native: third-party license needs its file and checksum: lzma',
        ),
      );
    });

    test('rejects reclassifying a third-party core as authored code', () {
      updateManifest((manifest) {
        (manifest['files'] as List).firstWhere(
          (entry) => entry['path'] == 'third_party/lodepng/lodepng.c',
        )['origin'] = 'project';
      });
      expect(
        fixture.check(),
        contains(
          'venera_native: third-party file needs its reviewed origin: third_party/lodepng/lodepng.c',
        ),
      );
    });

    test(
      'rejects an undeclared third-party tree despite updated local hashes',
      () {
        final file = fixture.file('third_party/unknown/core.c');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('// unreviewed upstream core\n');
        final hash = sha256
            .convert(utf8.encode(file.readAsStringSync()))
            .toString();
        updateManifest(
          (manifest) => (manifest['files'] as List).add({
            'path': 'third_party/unknown/core.c',
            'origin': 'project',
            'sha256': hash,
            'local_sha256': hash,
          }),
        );
        expect(
          fixture.check(),
          contains(
            'venera_native: third-party file has no reviewed source: third_party/unknown/core.c',
          ),
        );
      },
    );

    test('rejects overlapping third-party directories without throwing', () {
      final origins = record['third_party_sources'] as List;
      origins[1]['directory'] = 'third_party/lodepng/child';
      updateManifest((manifest) => manifest['third_party_sources'] = origins);
      expect(
        fixture.check(),
        contains('venera_native: third-party source directories overlap'),
      );
    });

    test('rejects changed third-party license bytes', () {
      fixture
          .file('third_party/lodepng/LICENSE')
          .writeAsStringSync('changed license');
      expect(
        fixture.check(),
        contains(
          'venera_native: third-party license differs from review: lodepng',
        ),
      );
    });
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
    final name = record['dependency'] as String;
    final manifestName = record['source_manifest'] as String;
    packagePath = record['path'] as String;
    final manifest =
        jsonDecode(
              File(path.join(packagePath, manifestName)).readAsStringSync(),
            )
            as Map;
    for (final relative in [
      ...(manifest['files'] as List).map((entry) => entry['path'] as String),
      manifestName,
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
        name: {'path': packagePath},
      },
    };
    lock = {
      'packages': {
        name: {
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
