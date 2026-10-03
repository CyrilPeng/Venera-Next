import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/utilities.dart';

/// Syntactic candidates only: never delete code based on this report alone.
class Inventory extends GeneralizingAstVisitor<void> {
  Inventory(this.path, this.unit);
  final String path;
  final CompilationUnit unit;
  final declarations = <Map<String, Object?>>[];
  final strings = <String, int>{};

  void add(
    AstNode node,
    String name,
    String kind, {
    AnnotatedNode? annotations,
  }) {
    if (name.startsWith('_')) return;
    String? owner;
    var parent = node.parent;
    while (parent != null) {
      if (parent is NamedCompilationUnitMember) {
        owner = parent.name.lexeme;
        break;
      }
      parent = parent.parent;
    }
    declarations.add({
      'file': path,
      'offset': node.offset,
      'name': name,
      'owner': owner,
      'kind': kind,
      'annotations':
          annotations?.metadata.map((a) => a.name.name).toList() ?? [],
    });
  }

  @override
  void visitNode(AstNode node) {
    if (node is NamedCompilationUnitMember && node.parent is CompilationUnit) {
      add(
        node,
        node.name.lexeme,
        node.runtimeType.toString().replaceAll('Impl', ''),
        annotations: node,
      );
    }
    super.visitNode(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    if (node.name != null) {
      add(node, node.name!.lexeme, 'extension', annotations: node);
    }
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    add(
      node,
      node.name.lexeme,
      node.isGetter
          ? 'getter'
          : node.isSetter
          ? 'setter'
          : 'method',
      annotations: node,
    );
    super.visitMethodDeclaration(node);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (node.name != null)
      add(node, node.name!.lexeme, 'named constructor', annotations: node);
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final container = node.parent?.parent;
    if (container is FieldDeclaration ||
        container is TopLevelVariableDeclaration) {
      add(
        node,
        node.name.lexeme,
        container is FieldDeclaration ? 'field' : 'variable',
        annotations: container as AnnotatedNode,
      );
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    add(node, node.name.lexeme, 'enum constant', annotations: node);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(node.value)) {
      strings.update(node.value, (n) => n + 1, ifAbsent: () => 1);
    }
    super.visitSimpleStringLiteral(node);
  }
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'Usage: dart run bin/public_symbols.dart <repository> <output.json>',
    );
    exitCode = 64;
    return;
  }
  final root = Directory(args[0]).absolute;
  final tracked = Process.runSync('git', [
    'ls-files',
    '-z',
  ], workingDirectory: root.path);
  if (tracked.exitCode != 0) throw StateError('${tracked.stderr}');
  final files =
      (tracked.stdout as String)
          .split('\x00')
          .where(
            (p) =>
                p.endsWith('.dart') &&
                (p.startsWith('lib/') || p.startsWith('test/')),
          )
          .toList()
        ..sort();
  final declarations = <Map<String, Object?>>[];
  final production = <String, int>{};
  final tests = <String, int>{};
  final strings = <String, int>{};
  final declarationCounts = <String, int>{};
  for (final path in files) {
    final source = File('${root.path}/$path').readAsStringSync();
    final parsed = parseString(
      content: source,
      path: path,
      throwIfDiagnostics: false,
    );
    if (parsed.errors.isNotEmpty) {
      throw StateError('Parse diagnostics in $path: ${parsed.errors}');
    }
    final counter = path.startsWith('lib/') ? production : tests;
    var token = parsed.unit.beginToken;
    while (!token.isEof) {
      if (token.isIdentifier)
        counter.update(token.lexeme, (n) => n + 1, ifAbsent: () => 1);
      token = token.next!;
    }
    if (!path.startsWith('lib/')) continue;
    final visitor = Inventory(path, parsed.unit);
    parsed.unit.accept(visitor);
    for (final entry in visitor.declarations) {
      entry['line'] = parsed.lineInfo
          .getLocation(entry.remove('offset') as int)
          .lineNumber;
      final name = entry['name'] as String;
      declarationCounts.update(name, (n) => n + 1, ifAbsent: () => 1);
      declarations.add(entry);
    }
    visitor.strings.forEach(
      (name, count) =>
          strings.update(name, (n) => n + count, ifAbsent: () => count),
    );
  }
  final candidates = <Map<String, Object?>>[];
  for (final entry in declarations) {
    final name = entry['name'] as String;
    final count = production[name] ?? 0;
    final declarationsWithName = declarationCounts[name]!;
    if (count > declarationsWithName) continue;
    candidates.add({
      ...entry,
      'production_identifier_tokens': count,
      'public_declarations_with_name': declarationsWithName,
      'test_identifier_tokens': tests[name] ?? 0,
      'exact_production_string_literals': strings[name] ?? 0,
    });
  }
  File(args[1]).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'scope': 'tracked working-tree lib/test Dart files; syntactic name counts, not resolved references', 'limitations': 'Same-name symbols can hide candidates. Overrides, external protocols, JS/native calls and reflection require manual review. Unnamed constructors and parameters are not independent candidates. Strings with interpolation are not exact-string matches.', 'production_files': files.where((p) => p.startsWith('lib/')).length, 'test_files': files.where((p) => p.startsWith('test/')).length, 'public_declarations': declarations.length, 'candidates': candidates})}\n',
  );
  stdout.writeln(
    '${declarations.length} declarations; ${candidates.length} candidates',
  );
}
