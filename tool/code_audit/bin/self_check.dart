import 'package:analyzer/dart/analysis/utilities.dart';

import 'public_symbols.dart';

void main() {
  final parsed = parseString(
    content: '''
class PublicType {
  PublicType.named();
  int field = 0;
  int get value => field;
  @override
  String toString() => 'dynamicEntry';
  void action() { void localFunction() {} }
  void _privateMethod() {}
}
enum Choice { first, second }
typedef Callback = void Function();
extension Tools on String { int get size => length; }
void topLevel() {}
final topField = 'dynamicEntry';
// NotADeclaration
''',
  );
  final inventory = Inventory('fixture.dart', parsed.unit);
  parsed.unit.accept(inventory);
  final names = inventory.declarations.map((d) => d['name']).toSet();
  final expected = {
    'PublicType',
    'named',
    'field',
    'value',
    'toString',
    'action',
    'Choice',
    'first',
    'second',
    'Callback',
    'Tools',
    'size',
    'topLevel',
    'topField',
  };
  if (names.difference(expected).isNotEmpty ||
      expected.difference(names).isNotEmpty) {
    throw StateError('Unexpected declarations: $names');
  }
  if (inventory.strings['dynamicEntry'] != 2) {
    throw StateError('Exact string evidence was not collected');
  }
  final overridden = inventory.declarations.singleWhere(
    (d) => d['name'] == 'toString',
  );
  if (!(overridden['annotations'] as List).contains('override')) {
    throw StateError('Override annotation was lost');
  }
  if (inventory.declarations.length != expected.length) {
    throw StateError('Duplicate declarations in visitor');
  }
  print('AST inventory checks passed');
}
