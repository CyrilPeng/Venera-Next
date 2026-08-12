import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/js_engine.dart';

void main() {
  test('read-only source retry recognizes malformed JSON responses', () {
    expect(
      JsEngine.debugIsRetryableReadError(
        Exception('SyntaxError: unexpected token < in JSON'),
      ),
      isTrue,
    );
    expect(
      JsEngine.debugIsRetryableReadError(
        Exception('JSException: Syntax error: unexpected end of input'),
      ),
      isTrue,
    );
  });

  test('read-only source retry recognizes transient network failures', () {
    for (final message in [
      'Connection timed out',
      'Connection reset by peer',
      'Connection terminated during handshake',
      'Response ended prematurely',
      'HTTP/2 stream was reset',
    ]) {
      expect(JsEngine.debugIsRetryableReadError(Exception(message)), isTrue);
    }
  });

  test('read-only source retry ignores unrelated failures', () {
    expect(
      JsEngine.debugIsRetryableReadError(
        Exception('SyntaxError: missing ) after argument list'),
      ),
      isFalse,
    );
    expect(
      JsEngine.debugIsRetryableReadError(Exception('Invalid Status Code: 403')),
      isFalse,
    );
  });
}
