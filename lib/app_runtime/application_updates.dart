import 'package:venera_next/features/comic_source/comic_source_api.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/appdata.dart';
import 'package:venera_next/foundation/application_update_service.dart';
import 'package:venera_next/foundation/startup_update_check.dart';
import 'package:venera_next/network/app_dio.dart';
import 'package:venera_next/network/request_scope.dart';

ApplicationUpdateService createApplicationUpdates() => ApplicationUpdateService(
  // Public release metadata needs network preferences, not application cookies
  // or an interactive Cloudflare interceptor.
  createClient: () => Dio()..httpClientAdapter = RHttpAdapter(),
  currentVersion: () => App.version,
);

StartupUpdateCheck createStartupUpdateCheck({
  required SourceUpdateService sources,
  required Future<void> Function(RequestScope) checkApplication,
}) => StartupUpdateCheck(
  reserveCheck: () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    const interval = 24 * 60 * 60 * 1000;
    final last = appdata.implicitData['lastCheckUpdate'] ?? 0;
    if (now - last < interval) return false;
    return appdata.updateImplicit((data) {
      final latest = data['lastCheckUpdate'] ?? 0;
      if (now - latest < interval) return false;
      data['lastCheckUpdate'] = now;
      return true;
    });
  },
  checkSources: () async {
    await sources.checkUpdates();
  },
  applicationCheckEnabled: () => appdata.settings['checkUpdateOnStart'],
  checkApplication: checkApplication,
);
