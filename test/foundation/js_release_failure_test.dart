import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_engine.dart';

class _Callback extends JSInvokable {
  _Callback(this.events, this.name, {this.fail = false});
  final List<String> events;
  final String name;
  final bool fail;
  @override
  dynamic invoke(List args, [dynamic thisVal]) => null;
  @override
  void destroy() {
    events.add(name);
    if (fail) throw StateError('$name failed');
  }
}

void _retain(JsCallbackScope scope, _Callback callback) {
  scope.retain(callback);
  callback.free();
}

void main() {
  tearDown(() => JsEngine().dispose());

  test('scope attempts every child and callback despite release failures', () {
    final events = <String>[];
    final scope = JsCallbackScope();
    final child = scope.fork();
    _retain(child, _Callback(events, 'child', fail: true));
    _retain(scope, _Callback(events, 'first', fail: true));
    _retain(scope, _Callback(events, 'last'));
    expect(
      scope.dispose,
      throwsA(
        isA<JsResourceReleaseFailure>().having(
          (e) => e.failures.length,
          'failures',
          2,
        ),
      ),
    );
    expect(events, ['child', 'first', 'last']);
    scope.dispose();
    child.dispose();
    expect(events, ['child', 'first', 'last']);
  });

  test('engine releases later scopes when an earlier scope fails', () {
    final engine = JsEngine();
    final events = <String>[];
    final first = JsCallbackScope();
    final last = JsCallbackScope();
    _retain(first, _Callback(events, 'first', fail: true));
    _retain(last, _Callback(events, 'last'));
    expect(engine.dispose, throwsA(isA<JsResourceReleaseFailure>()));
    expect(events, ['first', 'last']);
    expect(first.fork, throwsStateError);
    expect(last.fork, throwsStateError);
    engine.dispose();
  });
}
