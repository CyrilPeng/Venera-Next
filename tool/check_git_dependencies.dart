import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

/// Compare all direct and transitive Git packages with the reviewed inventory.
List<String> checkGitDependencies(Map spec, Map lock, Map inventory) {
  final errors = <String>[];
  final expected = <String, Map>{};
  final direct = <String>{};
  final declarations = <dynamic, dynamic>{
    ...?spec['dependencies'] as Map?,
    ...?spec['dev_dependencies'] as Map?,
    ...?spec['dependency_overrides'] as Map?,
  };
  for (final repo in inventory['repositories'] as List) {
    final name = repo['dependency'] as String;
    final commit = repo['commit'] as String;
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
      errors.add('$name: inventory must pin a full commit SHA');
    }
    if (!direct.add(name)) errors.add('$name: duplicate direct dependency');
    if (!['maintained-fork', 'license-review'].contains(repo['status']) ||
        (repo['reason'] as String? ?? '').trim().isEmpty) {
      errors.add('$name: record maintenance status and retention reason');
    }
    final declaration = declarations[name];
    final git = declaration is Map ? declaration['git'] : null;
    final packages = repo['packages'] as Map;
    if (git is! Map ||
        git['url'] != repo['url'] ||
        git['ref'] != commit ||
        (git['path'] ?? '.') != packages[name]) {
      errors.add(
        '$name: pubspec does not match the reviewed URL, commit or path',
      );
    }
    for (final entry in packages.entries) {
      if (expected.containsKey(entry.key)) {
        errors.add('${entry.key}: duplicate inventory package');
      }
      expected[entry.key as String] = {
        'url': repo['url'],
        'ref': commit,
        'resolved-ref': commit,
        'path': entry.value,
      };
    }
  }
  for (final entry in declarations.entries) {
    if (entry.value is Map &&
        (entry.value as Map).containsKey('git') &&
        !direct.contains(entry.key)) {
      errors.add('${entry.key}: Git dependency has no review record');
    }
  }
  final locked = lock['packages'] as Map;
  for (final entry in locked.entries) {
    if (entry.value['source'] != 'git') continue;
    final approved = expected.remove(entry.key);
    if (approved == null) {
      errors.add('${entry.key}: unexpected transitive Git package');
      continue;
    }
    final actual = entry.value['description'] as Map;
    for (final field in approved.keys) {
      if (actual[field] != approved[field]) {
        errors.add(
          '${entry.key}: locked $field differs from reviewed inventory',
        );
      }
    }
  }
  for (final missing in expected.keys) {
    errors.add('$missing: reviewed Git package missing from lockfile');
  }
  return errors;
}

/// Review local package provenance as well as the Git dependency inventory.
List<String> checkDependencyInventory(
  Map spec,
  Map lock,
  Map inventory, {
  Directory? root,
}) {
  final errors = checkGitDependencies(spec, lock, inventory);
  if (inventory['schema_version'] != 2) {
    errors.add('inventory: expected schema_version 2');
  }
  final workspace = root ?? Directory.current;
  final declarations = <dynamic, dynamic>{
    ...?spec['dependencies'] as Map?,
    ...?spec['dev_dependencies'] as Map?,
    ...?spec['dependency_overrides'] as Map?,
  };
  final expected = <String, Map>{};
  final localPaths = <String>{};
  final records = inventory['local_packages'];
  if (records is! List) {
    errors.add('inventory: local_packages must be a reviewed list');
  } else {
    for (final record in records) {
      if (record is! Map || record['dependency'] is! String) {
        errors.add('inventory: local package record needs a dependency name');
        continue;
      }
      final name = record['dependency'] as String;
      if (expected.containsKey(name)) {
        errors.add('$name: duplicate local inventory package');
      }
      expected[name] = record;
      final packagePath = record['path'];
      if (!_relativePath(packagePath) ||
          !(packagePath as String).startsWith('packages/')) {
        errors.add('$name: local package path must stay under packages/');
        continue;
      }
      if (!localPaths.add(packagePath)) {
        errors.add('$name: duplicate local package path');
      }
      if (record['status'] != 'maintained-local' ||
          !_nonempty(record['reason']) ||
          !_nonempty(record['version'])) {
        errors.add(
          '$name: record local version, maintenance status and reason',
        );
      }
      if (!_httpsUrl(record['upstream'])) {
        errors.add('$name: record the original upstream URL');
      }
      final source = record['source'];
      if (source is! Map || !_httpsUrl(source['url'])) {
        errors.add('$name: record the immutable source URL');
      } else if (source['type'] == 'git') {
        if (!_digest(source['commit'], 40) ||
            !_relativePath(source['path'], allowDot: true)) {
          errors.add('$name: source must pin a full Git SHA and package path');
        }
      } else if (source['type'] == 'archive') {
        if (!_digest(source['sha256'], 64)) {
          errors.add('$name: source archive needs a SHA-256 checksum');
        }
      } else {
        errors.add('$name: source type must be git or archive');
      }
      final declared = declarations[name];
      if (declared is! Map ||
          declared['path'] != packagePath ||
          declared.containsKey('git')) {
        errors.add('$name: pubspec does not match the reviewed local path');
      }
      _checkLocalFiles(workspace, record, errors);
    }
  }
  for (final entry in declarations.entries) {
    if (entry.value is Map &&
        (entry.value as Map).containsKey('path') &&
        !expected.containsKey(entry.key)) {
      errors.add('${entry.key}: local dependency has no review record');
    }
  }
  for (final entry in (lock['packages'] as Map).entries) {
    if (entry.value['source'] != 'path') continue;
    final approved = expected.remove(entry.key);
    if (approved == null) {
      errors.add('${entry.key}: unexpected transitive local package');
      continue;
    }
    final description = entry.value['description'];
    if (description is! Map ||
        description['path'] != approved['path'] ||
        description['relative'] != true ||
        entry.value['version'] != approved['version']) {
      errors.add(
        '${entry.key}: locked local path or version differs from review',
      );
    }
  }
  for (final missing in expected.keys) {
    errors.add('$missing: reviewed local package missing from lockfile');
  }
  return errors;
}

bool _nonempty(dynamic value) => value is String && value.trim().isNotEmpty;

bool _digest(dynamic value, int length) =>
    value is String && RegExp('^[0-9a-f]{$length}\$').hasMatch(value);

bool _httpsUrl(dynamic value) {
  if (value is! String) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

bool _relativePath(dynamic value, {bool allowDot = false}) {
  if (allowDot && value == '.') return true;
  return value is String &&
      value.isNotEmpty &&
      !value.contains(RegExp(r'[\\:]')) &&
      value
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');
}

File? _reviewedFile(
  Directory workspace,
  String packagePath,
  dynamic relative,
  String name,
  List<String> errors,
) {
  if (!_relativePath(relative)) {
    errors.add('$name: invalid local file path $relative');
    return null;
  }
  final file = File(path.join(workspace.path, packagePath, relative as String));
  try {
    if (!file.existsSync()) {
      errors.add('$name: missing local file $relative');
      return null;
    }
    final canonicalPackage = Directory(
      path.join(workspace.path, packagePath),
    ).resolveSymbolicLinksSync();
    if (!path.isWithin(
          workspace.resolveSymbolicLinksSync(),
          canonicalPackage,
        ) ||
        !path.isWithin(canonicalPackage, file.resolveSymbolicLinksSync())) {
      errors.add('$name: local file escapes the reviewed package: $relative');
      return null;
    }
    return file;
  } on FileSystemException {
    errors.add('$name: cannot resolve local file $relative');
    return null;
  }
}

String _textHash(File file) => sha256
    .convert(utf8.encode(file.readAsStringSync().replaceAll('\r\n', '\n')))
    .toString();

void _checkLocalFiles(Directory workspace, Map record, List<String> errors) {
  final name = record['dependency'] as String;
  final packagePath = record['path'] as String;
  final manifest = _reviewedFile(
    workspace,
    packagePath,
    'pubspec.yaml',
    name,
    errors,
  );
  if (manifest != null) {
    try {
      final spec = loadYaml(manifest.readAsStringSync());
      if (spec is! Map ||
          spec['name'] != name ||
          spec['version'] != record['version']) {
        errors.add('$name: local pubspec name or version differs from review');
      }
    } on YamlException {
      errors.add('$name: cannot parse local pubspec');
    }
  }
  final license = record['license'];
  if (license is! Map ||
      !_nonempty(license['spdx']) ||
      !_digest(license['sha256'], 64)) {
    errors.add('$name: record license identifier, file and SHA-256');
  } else {
    final file = _reviewedFile(
      workspace,
      packagePath,
      license['file'],
      name,
      errors,
    );
    if (file != null && _textHash(file) != license['sha256']) {
      errors.add('$name: local license differs from the reviewed checksum');
    }
  }
  final patches = _reviewedFile(
    workspace,
    packagePath,
    record['patches'],
    name,
    errors,
  );
  if (patches != null) {
    final text = patches.readAsStringSync();
    final source = record['source'];
    final baseline = source is Map
        ? source['commit'] ?? source['sha256']
        : null;
    if (!_nonempty(text) ||
        (baseline is String && !text.contains(baseline)) ||
        (record['version'] is String && !text.contains(record['version']))) {
      errors.add('$name: patch notes must identify the source and version');
    }
  }
  if (record.containsKey('source_manifest')) {
    _checkSourceManifest(workspace, record, errors);
  }
}

void _checkSourceManifest(
  Directory workspace,
  Map record,
  List<String> errors,
) {
  final name = record['dependency'] as String;
  final packagePath = record['path'] as String;
  final file = _reviewedFile(
    workspace,
    packagePath,
    record['source_manifest'],
    name,
    errors,
  );
  if (file == null) return;
  try {
    final manifest = jsonDecode(file.readAsStringSync());
    final source = record['source'];
    if (manifest is! Map ||
        source is! Map ||
        manifest['source'] is! Map ||
        source.length != (manifest['source'] as Map).length ||
        !source.entries.every(
          (entry) => manifest['source'][entry.key] == entry.value,
        ) ||
        manifest['files'] is! List) {
      errors.add('$name: source manifest does not match reviewed provenance');
      return;
    }
    final retained = <String>{};
    for (final entry in manifest['files'] as List) {
      if (entry is! Map ||
          !_relativePath(entry['path']) ||
          !_digest(entry['sha256'], 64) ||
          !_digest(entry['local_sha256'], 64)) {
        errors.add(
          '$name: source manifest needs file paths and both checksums',
        );
        continue;
      }
      final relative = entry['path'] as String;
      if (!retained.add(relative)) {
        errors.add('$name: duplicate source manifest file $relative');
      }
      final retainedFile = _reviewedFile(
        workspace,
        packagePath,
        relative,
        name,
        errors,
      );
      if (retainedFile != null &&
          _textHash(retainedFile) != entry['local_sha256']) {
        errors.add('$name: local source changed without review: $relative');
      }
    }
    final license = record['license'];
    if (!retained.contains('pubspec.yaml') ||
        license is! Map ||
        !retained.contains(license['file']) ||
        !retained.any(
          (item) => item.startsWith('lib/') && item.endsWith('.dart'),
        )) {
      errors.add('$name: source manifest must cover pubspec, license and lib');
    }
    final lib = Directory(path.join(workspace.path, packagePath, 'lib'));
    if (lib.existsSync()) {
      final canonicalPackage = Directory(
        path.join(workspace.path, packagePath),
      ).resolveSymbolicLinksSync();
      if (!path.isWithin(canonicalPackage, lib.resolveSymbolicLinksSync())) {
        errors.add('$name: lib directory escapes the reviewed package');
        return;
      }
      for (final entity in lib.listSync(recursive: true, followLinks: false)) {
        final relative = path
            .relative(entity.path, from: path.join(workspace.path, packagePath))
            .replaceAll('\\', '/');
        if (entity is Link) {
          errors.add('$name: local source tree contains a link: $relative');
          continue;
        }
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (!retained.contains(relative)) {
          errors.add('$name: local Dart file has no source record: $relative');
        }
      }
    }
  } on FormatException {
    errors.add('$name: cannot parse source manifest');
  } on FileSystemException {
    errors.add('$name: cannot read retained source files');
  }
}

void main() {
  final errors = checkDependencyInventory(
    loadYaml(File('pubspec.yaml').readAsStringSync()) as Map,
    loadYaml(File('pubspec.lock').readAsStringSync()) as Map,
    jsonDecode(File('doc/development/git_dependencies.json').readAsStringSync())
        as Map,
  );
  // Build tools must not bypass the application lockfile and review inventory.
  for (final file in Directory(
    '.github/workflows',
  ).listSync().whereType<File>()) {
    if (RegExp(
      r'pub\s+global\s+activate\s+.*(?:-s\s+git|--source[=\s]+git)',
    ).hasMatch(file.readAsStringSync())) {
      errors.add('${file.path}: unreviewed global Git tool installation');
    }
  }
  if (errors.isNotEmpty) {
    stderr.writeln(errors.join('\n'));
    exitCode = 1;
  } else {
    stdout.writeln(
      'Dependency inventory matches Git and local packages, provenance and licenses.',
    );
  }
}
