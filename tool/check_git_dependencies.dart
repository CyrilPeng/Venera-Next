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
    if (![
          'official-commit',
          'maintained-fork',
          'license-review',
        ].contains(repo['status']) ||
        (repo['reason'] as String? ?? '').trim().isEmpty) {
      errors.add('$name: record maintenance status and retention reason');
    }
    _checkSourceDecision(repo, errors);
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
    final value = entry.value;
    if (value is! Map || !value.containsKey('git')) continue;
    final approved = expected[entry.key];
    if (approved == null) {
      errors.add('${entry.key}: Git dependency has no review record');
    } else if (!direct.contains(entry.key)) {
      final git = value['git'];
      if (git is! Map ||
          git['url'] != approved['url'] ||
          git['ref'] != approved['ref'] ||
          (git['path'] ?? '.') != approved['path']) {
        errors.add('${entry.key}: Git override differs from reviewed source');
      }
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
      } else if (source['type'] == 'project') {
        if (source['path'] != packagePath ||
            source['url'] != record['upstream'] ||
            !_relativePath(record['source_manifest']) ||
            record['source_directories'] is! List) {
          errors.add(
            '$name: project source needs its own path, repository and full source manifest',
          );
        }
      } else {
        errors.add('$name: source type must be git, archive or project');
      }
      final declared = declarations[name];
      if (declared is! Map ||
          declared['path'] != packagePath ||
          declared.containsKey('git')) {
        errors.add('$name: pubspec does not match the reviewed local path');
      }
      _checkLocalFiles(workspace, record, errors);
      if (source is Map && source['type'] != 'project') {
        _checkSourceDecision(record, errors);
      }
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

/// A failed Pub checkout can leave a correctly named cache on a different HEAD.
/// Validate the resolved checkout itself in addition to the lockfile labels.
List<String> checkResolvedGitDependencies(
  Map lock,
  Map config, {
  required File configFile,
}) {
  final errors = <String>[];
  final resolved = {
    for (final package in config['packages'] as List)
      package['name']: package['rootUri'],
  };
  for (final entry in (lock['packages'] as Map).entries) {
    if (entry.value['source'] != 'git') continue;
    final name = entry.key;
    final rootUri = resolved[name];
    if (rootUri is! String) {
      errors.add('$name: resolved Git package is missing; run pub get');
      continue;
    }
    final uri = configFile.absolute.uri.resolve(rootUri);
    if (uri.scheme != 'file') {
      errors.add('$name: resolved Git package must be a local checkout');
      continue;
    }
    try {
      final root = Directory.fromUri(uri).resolveSymbolicLinksSync();
      final head = Process.runSync('git', ['-C', root, 'rev-parse', 'HEAD']);
      if (head.exitCode != 0 ||
          (head.stdout as String).trim() !=
              entry.value['description']['resolved-ref']) {
        errors.add('$name: actual Git checkout differs from the locked SHA');
        continue;
      }
      final top = Process.runSync('git', [
        '-C',
        root,
        'rev-parse',
        '--show-toplevel',
      ]);
      if (top.exitCode != 0 ||
          path
                  .relative(root, from: (top.stdout as String).trim())
                  .replaceAll('\\', '/') !=
              entry.value['description']['path']) {
        errors.add('$name: resolved package path differs from the lockfile');
        continue;
      }
      final clean = Process.runSync('git', [
        '-C',
        root,
        'diff',
        '--quiet',
        'HEAD',
        '--',
        '.',
      ]);
      if (clean.exitCode != 0) {
        errors.add('$name: resolved Git package has tracked source changes');
      }
    } on FileSystemException {
      errors.add('$name: cannot read the resolved Git checkout');
    } on ProcessException {
      errors.add('$name: cannot verify the resolved Git checkout');
    }
  }
  return errors;
}

bool _nonempty(dynamic value) => value is String && value.trim().isNotEmpty;

void _checkSourceDecision(Map record, List<String> errors) {
  final name = record['dependency'];
  final review = record['official_review'];
  if (!_httpsUrl(record['upstream']) ||
      review is! Map ||
      !_nonempty(review['stable_version']) ||
      !_digest(review['commit'], 40) ||
      !_nonempty(review['validation']) ||
      !_nonempty(review['exit_condition']) ||
      !_nonempty(review['maintainer'])) {
    errors.add('$name: record official candidates, validation and exit review');
    return;
  }
  if (record['status'] == 'official-commit') {
    if (record['url'] != record['upstream']) {
      errors.add('$name: official commit must use the reviewed upstream URL');
    }
  } else if (review['required_patches'] is! List ||
      (review['required_patches'] as List).isEmpty ||
      !(review['required_patches'] as List).every(_nonempty)) {
    errors.add('$name: non-official source needs its necessary patch scope');
  }
}

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

String _sourceHash(File file, String encoding) => encoding == 'binary'
    ? sha256.convert(file.readAsBytesSync()).toString()
    : _textHash(file);

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
    final projectSource = source['type'] == 'project';
    final origins = projectSource
        ? _checkThirdPartySources(workspace, record, manifest, errors)
        : <String, Map>{};
    final fileOrigins = <String, String>{};
    for (final entry in manifest['files'] as List) {
      if (entry is! Map ||
          !_relativePath(entry['path']) ||
          !_digest(entry['sha256'], 64) ||
          !_digest(entry['local_sha256'], 64) ||
          !['text', 'binary'].contains(entry['encoding'] ?? 'text')) {
        errors.add(
          '$name: source manifest needs file paths and both checksums',
        );
        continue;
      }
      final relative = entry['path'] as String;
      if (!retained.add(relative)) {
        errors.add('$name: duplicate source manifest file $relative');
      }
      if (projectSource) {
        final origin = entry['origin'];
        if (origin is String) fileOrigins[relative] = origin;
        final thirdParty = origins[origin];
        final directoryOwner = origins.entries.where(
          (item) => relative.startsWith('${item.value['directory']}/'),
        );
        if (relative.startsWith('third_party/') && directoryOwner.isEmpty) {
          errors.add(
            '$name: third-party file has no reviewed source: $relative',
          );
        } else if (directoryOwner.isNotEmpty) {
          if (thirdParty == null ||
              directoryOwner.single.key != origin ||
              !_relativePath(entry['upstream_path'])) {
            errors.add(
              '$name: third-party file needs its reviewed origin: $relative',
            );
          }
        } else if (origin != 'project') {
          errors.add(
            '$name: authored file must identify project origin: $relative',
          );
        }
      }
      final retainedFile = _reviewedFile(
        workspace,
        packagePath,
        relative,
        name,
        errors,
      );
      if (retainedFile != null &&
          _sourceHash(retainedFile, entry['encoding'] ?? 'text') !=
              entry['local_sha256']) {
        errors.add('$name: local source changed without review: $relative');
      }
    }
    for (final origin in origins.entries) {
      final license = origin.value['license'];
      if (license is Map && fileOrigins[license['file']] != origin.key) {
        errors.add(
          '$name: third-party license is not in its source manifest: ${origin.key}',
        );
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
    _checkSourceDirectories(workspace, record, retained, errors);
  } on FormatException {
    errors.add('$name: cannot parse source manifest');
  } on FileSystemException {
    errors.add('$name: cannot read retained source files');
  }
}

Map<String, Map> _checkThirdPartySources(
  Directory workspace,
  Map record,
  Map manifest,
  List<String> errors,
) {
  final name = record['dependency'] as String;
  final packagePath = record['path'] as String;
  final records = record['third_party_sources'];
  final sources = <String, Map>{};
  if (records is! List ||
      jsonEncode(records) != jsonEncode(manifest['third_party_sources'])) {
    errors.add(
      '$name: project manifest must match reviewed third-party sources',
    );
    return sources;
  }
  final directories = <String>{};
  for (final entry in records) {
    if (entry is! Map ||
        !_nonempty(entry['id']) ||
        entry['id'] == 'project' ||
        sources.containsKey(entry['id']) ||
        !_relativePath(entry['directory']) ||
        !(entry['directory'] as String).startsWith('third_party/')) {
      errors.add('$name: invalid or duplicate third-party source');
      continue;
    }
    final id = entry['id'] as String;
    final directory = entry['directory'] as String;
    if (directories.any(
      (other) =>
          directory == other ||
          directory.startsWith('$other/') ||
          other.startsWith('$directory/'),
    )) {
      errors.add('$name: third-party source directories overlap');
      continue;
    }
    directories.add(directory);
    sources[id] = entry;
    final source = entry['source'];
    if (!_httpsUrl(entry['upstream']) ||
        source is! Map ||
        !_httpsUrl(source['url']) ||
        !(source['type'] == 'git' &&
                _digest(source['commit'], 40) &&
                _relativePath(source['path'], allowDot: true) ||
            source['type'] == 'archive' && _digest(source['sha256'], 64))) {
      errors.add(
        '$name: third-party source needs immutable Git/archive provenance: $id',
      );
    }
    final license = entry['license'];
    if (license is! Map ||
        !_nonempty(license['spdx']) ||
        !_relativePath(license['file']) ||
        !(license['file'] as String).startsWith('$directory/') ||
        !_digest(license['sha256'], 64)) {
      errors.add('$name: third-party license needs its file and checksum: $id');
    } else {
      final file = _reviewedFile(
        workspace,
        packagePath,
        license['file'],
        name,
        errors,
      );
      if (file != null && _textHash(file) != license['sha256']) {
        errors.add('$name: third-party license differs from review: $id');
      }
    }
  }
  final reviewedDirectories = record['source_directories'];
  if (sources.isNotEmpty &&
      (reviewedDirectories is! List ||
          !reviewedDirectories.contains('third_party'))) {
    errors.add('$name: project manifest must cover the third_party directory');
  }
  return sources;
}

void _checkSourceDirectories(
  Directory workspace,
  Map record,
  Set<String> retained,
  List<String> errors,
) {
  final name = record['dependency'] as String;
  final packagePath = record['path'] as String;
  final strictFiles = record.containsKey('source_directories');
  final directories = record['source_directories'] ?? ['lib'];
  if (directories is! List ||
      directories.isEmpty ||
      !directories.contains('lib')) {
    errors.add('$name: reviewed source directories must include lib');
    return;
  }
  final seen = <String>{};
  final canonicalPackage = Directory(
    path.join(workspace.path, packagePath),
  ).resolveSymbolicLinksSync();
  if (!path.isWithin(workspace.resolveSymbolicLinksSync(), canonicalPackage)) {
    errors.add('$name: source package escapes the reviewed workspace');
    return;
  }
  for (final directory in directories) {
    if (!_relativePath(directory) || !seen.add(directory as String)) {
      errors.add('$name: invalid or duplicate source directory $directory');
      continue;
    }
    final source = Directory(path.join(workspace.path, packagePath, directory));
    if (!source.existsSync()) {
      errors.add('$name: missing reviewed source directory $directory');
      continue;
    }
    if (!path.isWithin(canonicalPackage, source.resolveSymbolicLinksSync())) {
      errors.add('$name: $directory directory escapes the reviewed package');
      continue;
    }
    for (final entity in source.listSync(recursive: true, followLinks: false)) {
      final relative = path
          .relative(entity.path, from: path.join(workspace.path, packagePath))
          .replaceAll('\\', '/');
      if (entity is Link) {
        errors.add('$name: local source tree contains a link: $relative');
        continue;
      }
      if (entity is! File || (!strictFiles && !entity.path.endsWith('.dart'))) {
        continue;
      }
      if (!retained.contains(relative)) {
        final kind = strictFiles ? 'source' : 'Dart';
        errors.add('$name: local $kind file has no source record: $relative');
      }
    }
  }
}

void main() {
  final lock = loadYaml(File('pubspec.lock').readAsStringSync()) as Map;
  final errors = checkDependencyInventory(
    loadYaml(File('pubspec.yaml').readAsStringSync()) as Map,
    lock,
    jsonDecode(File('doc/development/git_dependencies.json').readAsStringSync())
        as Map,
  );
  final configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    errors.add('Missing resolved package configuration; run pub get');
  } else {
    errors.addAll(
      checkResolvedGitDependencies(
        lock,
        jsonDecode(configFile.readAsStringSync()) as Map,
        configFile: configFile,
      ),
    );
  }
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
      'Dependency inventory matches resolved Git checkouts, local sources and licenses.',
    );
  }
}
