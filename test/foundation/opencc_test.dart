import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/opencc.dart';
import 'package:venera_next/foundation/opencc_table.dart';

class _Bundle extends CachingAssetBundle {
  final requests = <Completer<ByteData>>[];
  @override
  Future<ByteData> load(String key) {
    expect(key, 'assets/opencc.txt');
    final request = Completer<ByteData>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'load failure is shared, retry publishes atomically and success is reused',
    () async {
      final bundle = _Bundle();
      expect(() => OpenCC.hasChineseSimplified('汉'), throwsStateError);
      final first = OpenCC.init(bundle: bundle);
      expect(OpenCC.init(bundle: bundle), same(first));
      final failure = expectLater(first, throwsStateError);
      bundle.requests.single.completeError(StateError('asset unavailable'));
      await failure;
      expect(() => OpenCC.hasChineseTraditional('漢'), throwsStateError);
      final retry = OpenCC.init(bundle: bundle);
      expect(bundle.requests, hasLength(2));
      final bytes = Uint8List.fromList([0, ...utf8.encode('汉漢\n马馬'), 0]);
      bundle.requests.last.complete(
        ByteData.view(bytes.buffer, 1, bytes.length - 2),
      );
      await retry;
      expect(OpenCC.init(bundle: bundle), same(retry));
      expect(OpenCC.hasChineseSimplified('汉字'), isTrue);
      expect(OpenCC.hasChineseTraditional('漢字'), isTrue);
      expect(OpenCC.simplifiedToTraditional('汉马🙂'), '漢馬🙂');
      expect(OpenCC.traditionalToSimplified('漢馬🙂'), '汉马🙂');
      expect(bundle.requests, hasLength(2));
    },
  );

  test('table handles CRLF, supplementary characters and invalid rows', () {
    final table = OpenCCTable.parse('# comment\r\n汉漢\r\n㓆𠗣\ninvalid\n\n');
    expect(table.toTraditional('汉㓆🙂abc'), '漢𠗣🙂abc');
    expect(table.toSimplified('漢𠗣🙂abc'), '汉㓆🙂abc');
    expect(table.hasSimplified('hello汉'), isTrue);
    expect(table.hasTraditional('𠗣'), isTrue);
    expect(table.hasSimplified('hello🙂'), isFalse);
    expect(table.hasTraditional(''), isFalse);
  });

  test('last duplicate mapping wins in each direction', () {
    final table = OpenCCTable.parse('发發\n发髮\n髪髮');
    expect(table.toTraditional('发'), '髮');
    expect(table.toSimplified('髮'), '髪');
  });

  test(
    'bundled mappings preserve supported BMP conversions and include extensions',
    () async {
      final data = await rootBundle.loadString('assets/opencc.txt');
      final table = OpenCCTable.parse(data);
      expect(table.toTraditional('漫画汉语门马'), '漫畫漢語門馬');
      expect(table.toSimplified('漫畫漢語門馬'), '漫画汉语门马');
      expect(table.hasSimplified('漫画'), isTrue);
      expect(table.hasTraditional('漫畫'), isTrue);
      expect(table.toTraditional('㓆'), '𠗣');
    },
  );
}
