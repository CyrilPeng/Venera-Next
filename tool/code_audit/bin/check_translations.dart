import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

final _placeholder = RegExp(r'@[A-Za-z][A-Za-z0-9_]*');

Map<String, int> placeholders(String text) {
  final counts = <String, int>{};
  for (final match in _placeholder.allMatches(text)) {
    counts.update(match[0]!, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts;
}

bool _sameCounts(Map<String, int> a, Map<String, int> b) =>
    a.length == b.length &&
    a.entries.every((entry) => b[entry.key] == entry.value);

/// Decode with the JSON codec, and check duplicates before they can be hidden
/// by Map's last-write-wins behavior. Tokens inside strings stay intact.
Map<String, Map<String, String>> readTranslations(String content) {
  final decoded = jsonDecode(content);
  final tokens = RegExp(
    r'"(?:\\.|[^"\\])*"|[{}\[\]:]',
  ).allMatches(content).toList();
  final scopes = <Set<String>?>[];
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i][0]!;
    if (token == '{' || token == '[') {
      scopes.add(token == '{' ? <String>{} : null);
    } else if (token == '}' || token == ']') {
      scopes.removeLast();
    } else if (token.startsWith('"') &&
        i + 1 < tokens.length &&
        tokens[i + 1][0] == ':') {
      final key = jsonDecode(token) as String;
      if (!scopes.last!.add(key)) {
        throw FormatException(
          'Duplicate JSON key: $key',
          content,
          tokens[i].start,
        );
      }
    }
  }
  if (decoded is! Map<String, dynamic> || decoded.isEmpty) {
    throw const FormatException('Expected non-empty locale dictionaries');
  }
  return {
    for (final locale in decoded.entries)
      locale.key: switch (locale.value) {
        Map<String, dynamic> entries when entries.isNotEmpty => {
          for (final entry in entries.entries)
            entry.key: switch (entry.value) {
              String value when value.trim().isNotEmpty => value,
              _ => throw FormatException(
                '${locale.key}/${entry.key}: empty or non-string translation',
              ),
            },
        },
        _ => throw FormatException('${locale.key}: expected a dictionary'),
      },
  };
}

List<String> dictionaryErrors(Map<String, Map<String, String>> dictionaries) {
  final errors = <String>[];
  final reference = dictionaries.values.first;
  for (final locale in dictionaries.entries) {
    final missing = reference.keys.toSet().difference(
      locale.value.keys.toSet(),
    );
    final extra = locale.value.keys.toSet().difference(reference.keys.toSet());
    if (missing.isNotEmpty || extra.isNotEmpty) {
      errors.add(
        '${locale.key}: mismatched keys; missing=$missing; extra=$extra',
      );
    }
    for (final entry in locale.value.entries) {
      if (RegExp(r'[\u4e00-\u9fff]').hasMatch(entry.key)) {
        errors.add('${locale.key}: non-English key: ${entry.key}');
      }
      if (!_sameCounts(placeholders(entry.key), placeholders(entry.value))) {
        errors.add(
          '${locale.key}/${entry.key}: placeholder names or counts differ',
        );
      }
    }
  }
  return errors;
}

/// Recover complete literal keys, including adjacent, escaped and raw strings,
/// parenthesized/conditional expressions and literal lists. Dynamic targets are
/// reported separately; parsing a fragment of an interpolation is never valid.
Iterable<String> _literalKeys(Expression? expression) sync* {
  if (expression is StringLiteral && expression.stringValue != null) {
    yield expression.stringValue!;
  } else if (expression is ParenthesizedExpression) {
    yield* _literalKeys(expression.expression);
  } else if (expression is ConditionalExpression) {
    yield* _literalKeys(expression.thenExpression);
    yield* _literalKeys(expression.elseExpression);
  } else if (expression is ListLiteral) {
    for (final element in expression.elements) {
      if (element is Expression) yield* _literalKeys(element);
    }
  }
}

class TranslationUsage extends RecursiveAstVisitor<void> {
  TranslationUsage(this.path, this.dictionaries, this.lineInfo);
  final String path;
  final Map<String, Map<String, String>> dictionaries;
  final LineInfo lineInfo;
  final keys = <String>{};
  final errors = <String>[];
  var dynamicTargets = 0;

  void _check(Expression? target, AstNode call, [Expression? arguments]) {
    final literals = _literalKeys(target).toSet();
    if (literals.isEmpty) {
      dynamicTargets++;
      return;
    }
    keys.addAll(literals);
    final location = lineInfo.getLocation(call.offset);
    final source = '$path:${location.lineNumber}:${location.columnNumber}';
    Set<String>? parameterNames;
    if (arguments is SetOrMapLiteral &&
        arguments.elements.every(
          (element) =>
              element is MapLiteralEntry &&
              element.key is StringLiteral &&
              (element.key as StringLiteral).stringValue != null,
        )) {
      parameterNames = {
        for (final element in arguments.elements.cast<MapLiteralEntry>())
          '@${(element.key as StringLiteral).stringValue!}',
      };
    }
    for (final key in literals) {
      for (final locale in dictionaries.entries) {
        if (!locale.value.containsKey(key)) {
          errors.add('$source: ${locale.key} missing "$key"');
        }
      }
      final expected = placeholders(key).keys.toSet();
      if (arguments == null && expected.isNotEmpty) {
        errors.add('$source: "$key" requires tlParams');
      } else if (parameterNames != null &&
          (expected.difference(parameterNames).isNotEmpty ||
              parameterNames.difference(expected).isNotEmpty)) {
        errors.add('$source: "$key" expects $expected, got $parameterNames');
      }
    }
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (node.propertyName.name == 'tl') _check(node.target, node);
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.identifier.name == 'tl') _check(node.prefix, node);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'tlParams') {
      final arguments = node.argumentList.arguments;
      _check(
        node.target,
        node,
        arguments.length == 1 ? arguments.single : null,
      );
    }
    super.visitMethodInvocation(node);
  }
}

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run bin/check_translations.dart <repository-root>',
    );
    exitCode = 64;
    return;
  }
  final root = Directory(arguments.single).absolute;
  final dictionaries = readTranslations(
    File('${root.path}/assets/translation.json').readAsStringSync(),
  );
  final errors = dictionaryErrors(dictionaries);
  final keys = <String>{};
  var dynamicTargets = 0;
  final files =
      Directory('${root.path}/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final parsed = parseString(
      content: file.readAsStringSync(),
      path: file.path,
    );
    final usage = TranslationUsage(file.path, dictionaries, parsed.lineInfo);
    parsed.unit.accept(usage);
    keys.addAll(usage.keys);
    errors.addAll(usage.errors);
    dynamicTargets += usage.dynamicTargets;
  }
  for (final error in errors) {
    stderr.writeln(error);
  }
  print(
    'Translation audit: ${dictionaries.length} dictionaries, '
    '${dictionaries.values.first.length} entries, ${keys.length} static keys; '
    '$dynamicTargets dynamic targets require runtime coverage.',
  );
  if (errors.isNotEmpty) exitCode = 1;
}
