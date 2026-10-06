import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/comic_source/source_import.dart';
import 'package:venera_next/features/comic_source/source_repositories.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/owned_dio_client.dart';

import '../../support/application_update_adapter.dart';

const _repository = SourceRepository(
  id: 'repo',
  name: 'Repo',
  url: 'https://example.test/index.json',
);
const _catalog =
    '[{"key":"source","name":"Source","version":"1.0.0","fileName":"source.js"}]';

void main() {
  for (final preview in [false, true]) {
    Future<Object> load(
      Dio Function() factory,
      CancelToken token, {
      Dio? borrowed,
    }) => preview
        ? SourceImportPreview.fromUrl(
            _repository.url,
            client: borrowed,
            createClient: factory,
            cancelToken: token,
          )
        : SourceRepositories.instance.load(
            _repository,
            client: borrowed,
            createClient: factory,
            cancelToken: token,
          );

    test(
      'owned ${preview ? "preview" : "catalog"} waits cleanup and rejects cancellation during drain',
      () async {
        final adapter = ApplicationUpdateAdapter();
        final token = CancelToken();
        final result = expectLater(
          load(() => Dio()..httpClientAdapter = adapter, token),
          throwsA(isA<DioException>()),
        );
        await adapter.entered.future;
        adapter.response.complete(ResponseBody.fromString(_catalog, 200));
        await adapter.draining.future;
        token.cancel();
        adapter.released.complete();
        await result;
        expect(adapter.closes, 1);
      },
    );

    test(
      'borrowed ${preview ? "preview" : "catalog"} does not close or drain unrelated work',
      () async {
        final adapter = ApplicationUpdateAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        final result = load(
          () => throw TestFailure('borrowed client has no factory'),
          CancelToken(),
          borrowed: dio,
        );
        await adapter.entered.future;
        adapter.response.complete(ResponseBody.fromString(_catalog, 200));
        await result;
        expect(adapter.closes, 0);
        expect(adapter.draining.isCompleted, isFalse);
        dio.close(force: true);
        adapter.released.complete();
        await adapter.waitForIdle();
      },
    );

    test(
      '${preview ? "preview" : "catalog"} keeps operation, close and native cleanup failures',
      () async {
        final error = StateError('HTTP failed');
        final closeError = StateError('close failed');
        final idleError = StateError('drain failed');
        final adapter = ApplicationUpdateAdapter()..closeError = closeError;
        final result = expectLater(
          load(() => Dio()..httpClientAdapter = adapter, CancelToken()),
          throwsA(
            isA<DioCleanupFailure>()
                .having(
                  (e) => (e.cause as DioException).error,
                  'cause',
                  same(error),
                )
                .having((e) => e.stackTrace, 'stack', isNotNull)
                .having(
                  (e) => e.failures.map((f) => f.error).toList(),
                  'cleanup',
                  [closeError, idleError],
                ),
          ),
        );
        await adapter.entered.future;
        adapter.response.completeError(error);
        await adapter.draining.future;
        adapter.released.completeError(idleError);
        await result;
      },
    );
  }
}
