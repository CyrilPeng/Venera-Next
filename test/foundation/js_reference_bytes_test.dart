import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reference walks preserve typed buffers and their subviews', () {
    final bytes = Uint8List.fromList([0, 1, 2, 3, 254, 255]);
    final view = Uint8List.sublistView(bytes, 1, 5);
    final signed = Int32List.fromList([-1, 0, 1]);
    final floats = Float64List.fromList([-1.5, 0, 1.5]);
    final data = ByteData.sublistView(bytes);
    final values = [bytes, view, signed, floats, data];

    JSRef.dupRecursive(values);
    JSRef.freeRecursive(values);

    expect(bytes, [0, 1, 2, 3, 254, 255]);
    expect(view, [1, 2, 3, 254]);
    expect(signed, [-1, 0, 1]);
    expect(floats, [-1.5, 0, 1.5]);
    expect(data.getUint8(5), 255);
  });

  test('mixed cyclic graphs retain ordinary reference ownership', () {
    final reference = _Reference();
    final graph = <Object?>[];
    final child = <String, Object?>{
      'bytes': Uint8List(256 * 1024),
      'callback': reference,
      'parent': graph,
    };
    graph.addAll([child, child, reference, graph]);

    JSRef.dupRecursive(graph);
    expect(reference.duplicates, 2);
    JSRef.freeRecursive(graph);
    expect(reference.releases, 2);
    expect(reference.destroyed, 0);
    reference.free();
    expect(reference.destroyed, 1);
  });
}

class _Reference extends JSRef {
  int duplicates = 0, releases = 0, destroyed = 0;

  @override
  void dup() {
    duplicates++;
    super.dup();
  }

  @override
  void free() {
    releases++;
    super.free();
  }

  @override
  void destroy() => destroyed++;
}
