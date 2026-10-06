import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/owned_dio_client.dart';

/// Source metadata/script reads share transport rules. A supplied client stays
/// borrowed; its caller owns adapter completion and must drain it separately.
Future<Response<String>> readSourceText(
  String url, {
  Dio? client,
  Dio Function()? createClient,
  CancelToken? cancelToken,
}) async {
  void check() {
    final error = cancelToken?.cancelError;
    if (error != null) throw error;
  }

  check();
  final dio = client ?? (createClient ?? AppDio.new)();
  final owned = client == null ? OwnedDioClient(dio) : null;
  Object? cause;
  StackTrace? causeStack;
  late Response<String> response;
  try {
    check();
    response = await dio.get<String>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        headers: {'cache-time': 'no'},
      ),
    );
  } catch (error, stack) {
    cause = error;
    causeStack = stack;
    rethrow;
  } finally {
    await owned?.closeAndWait(cause: cause, stackTrace: causeStack);
  }
  check();
  return response;
}
