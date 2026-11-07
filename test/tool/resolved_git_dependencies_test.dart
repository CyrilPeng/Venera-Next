import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import '../../tool/check_git_dependencies.dart';

void main() {
  late Directory directory;
  late String oldHead;
  late String newHead;

  String git(List<String> args) {
    final result = Process.runSync('git', [
      '-C',
      directory.path,
      '-c',
      'user.name=Dependency source fixture',
      '-c',
      'user.email=fixture@example.invalid',
      ...args,
    ]);
    expect(result.exitCode, 0, reason: result.stderr as String);
    return (result.stdout as String).trim();
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('resolved-git-source-');
    git(['init', '--quiet']);
    final source = File(path.join(directory.path, 'pubspec.yaml'));
    final changelog = File(path.join(directory.path, 'CHANGELOG.md'));
    source.writeAsStringSync('name: fixture\nversion: 1.0.0\n');
    changelog.writeAsStringSync('第一版来源夹具\n');
    git(['add', '.']);
    git(['commit', '--quiet', '-m', 'chore(test): 初始化来源夹具']);
    oldHead = git(['rev-parse', 'HEAD']);
    source.writeAsStringSync('name: fixture\nversion: 2.0.0\n');
    changelog.writeAsStringSync('第二版来源夹具\n');
    git(['add', '.']);
    git(['commit', '--quiet', '-m', 'chore(test): 更新来源夹具']);
    newHead = git(['rev-parse', 'HEAD']);
  });

  tearDown(() {
    expect(
      path.isWithin(
        Directory.systemTemp.resolveSymbolicLinksSync(),
        directory.resolveSymbolicLinksSync(),
      ),
      isTrue,
    );
    directory.deleteSync(recursive: true);
  });

  List<String> check(String sha, {String packagePath = '.'}) =>
      checkResolvedGitDependencies(
        {
          'packages': {
            'fixture': {
              'source': 'git',
              'description': {'resolved-ref': sha, 'path': packagePath},
            },
          },
        },
        {
          'packages': [
            {'name': 'fixture', 'rootUri': directory.uri.toString()},
          ],
        },
        configFile: File(path.join(directory.path, 'package_config.json')),
      );

  test('accepts the actual locked checkout and package path', () {
    expect(check(newHead), isEmpty);
  });

  test('rejects a failed checkout even when the lock labels the old SHA', () {
    expect(
      check(oldHead),
      contains('fixture: actual Git checkout differs from the locked SHA'),
    );
  });

  test('rejects a package configuration resolving the wrong subdirectory', () {
    expect(
      check(newHead, packagePath: 'other_package'),
      contains('fixture: resolved package path differs from the lockfile'),
    );
  });

  test('rejects tracked cache modifications despite an unchanged HEAD', () {
    File(
      path.join(directory.path, 'pubspec.yaml'),
    ).writeAsStringSync('changed');
    expect(
      check(newHead),
      contains('fixture: resolved Git package has tracked source changes'),
    );
  });
}
