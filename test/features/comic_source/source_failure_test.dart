import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_failure.dart';
import 'package:venera_next/features/comic_source/source_failure_presentation.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('repository failure keeps its reason across presentation languages', () {
    final language = appdata.settings['language'];
    final translations = AppTranslation.translations;
    addTearDown(() {
      appdata.settings['language'] = language;
      AppTranslation.translations = translations;
    });
    AppTranslation.translations = {
      'zh_CN': {'Enter a complete HTTP or HTTPS URL.': '请输入完整地址'},
    };
    appdata.settings['language'] = 'en-US';
    Object? failure;
    try {
      SourceRepositories.normalizeUrl('file:///invalid');
    } catch (error) {
      failure = error;
    }
    expect(failure, isA<SourceFailure>());
    expect((failure as SourceFailure).code, SourceFailureCode.invalidUrl);
    for (final language in ['zh-CN', 'en-US']) {
      appdata.settings['language'] = language;
      expect(
        sourceFailureMessage(failure),
        language == 'zh-CN' ? '请输入完整地址' : 'Enter a complete HTTP or HTTPS URL.',
      );
      expect(failure.toString(), 'Enter a complete HTTP or HTTPS URL.');
    }
  });

  test('check output preserves cause and formats scope at the boundary', () {
    const cause = SourceFailure(SourceFailureCode.missingSource);
    const failure = SourceCheckFailure(
      cause,
      repository: 'Repo',
      source: 'Book',
    );
    expect(identical(failure.cause, cause), isTrue);
    expect(failure.format((_) => 'translated'), 'Repo / Book: translated');
    expect(failure.toString(), 'Repo / Book: ${cause.code.message}');
    const unscoped = SourceCheckFailure(cause);
    expect(unscoped.format((_) => 'translated'), 'translated');
  });

  test('unexpected failures retain their diagnostic at the UI boundary', () {
    expect(
      () => SourceRepositories.parseCatalog('[broken'),
      throwsA(
        isA<SourceFailure>()
            .having((error) => error.cause, 'cause', isA<FormatException>())
            .having((error) => error.stackTrace, 'stack', isNotNull),
      ),
    );
    final error = StateError('write failed');
    expect(sourceFailureMessage(error), error.toString());
    final failure = SourceCheckFailure(error, repository: 'Repo');
    expect(identical(failure.cause, error), isTrue);
    expect(failure.format(sourceFailureMessage), 'Repo: $error');
  });
}
