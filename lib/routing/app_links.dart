import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:app_links/app_links.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/features/comic_source/comic_source.dart';
import 'package:venera_next/features/comic_details/comic_details.dart';

EventSubscription<Uri> createAppLinkSubscription() => EventSubscription(
  events: AppLinks().uriLinkStream,
  handle: (uri, isActive) async {
    await handleAppLink(uri, isActive: isActive);
  },
  onError: (error, stack) => Log.error('App links', error, stack),
);

Future<bool> handleAppLink(Uri uri, {bool Function()? isActive}) async {
  if (isActive?.call() == false) return false;
  for (var source in ComicSource.all()) {
    if (source.linkHandler != null) {
      if (source.linkHandler!.domains.contains(uri.host)) {
        var id = source.linkHandler!.linkToId(uri.toString());
        if (id != null) {
          if (App.mainNavigatorKey == null) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
          if (isActive?.call() == false) return false;
          App.mainNavigatorKey?.currentContext?.to(() {
            return ComicPage(id: id, sourceKey: source.key);
          });
          return true;
        }
        return false;
      }
    }
  }
  return false;
}
