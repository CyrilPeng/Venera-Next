import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera_next/features/search/search.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:venera_next/routing/app_navigation.dart';

/// A caller-owned stream binding. Awaited navigation checks cannot outlive it.
EventSubscription<Object?> createTextShareSubscription() => EventSubscription(
  events: const EventChannel('venera/text_share').receiveBroadcastStream(),
  handle: (event, isActive) async {
    handleTextShare(event, isActive: isActive);
  },
  onError: (error, stack) => Log.error('Text share', error, stack),
);

void _openSharedSearch({
  required String keyword,
  bool Function()? isActive,
  Widget Function(String keyword)? searchPageBuilder,
}) {
  if (isActive?.call() == false || !appNavigation.isReadyForNavigation) return;
  final builder = searchPageBuilder;
  appNavigation.rootNavigatorKey.currentContext?.to(
    () => builder != null
        ? builder(keyword)
        : AggregatedSearchPage(keyword: keyword),
  );
}

bool handleTextShare(
  Object? event, {
  bool Function()? isActive,
  Widget Function(String keyword)? searchPageBuilder,
}) {
  if (isActive?.call() == false || event is! String) return false;
  if (!appNavigation.isReadyForNavigation) {
    appNavigation.deferUntilReady(
      () => _openSharedSearch(
        keyword: event,
        isActive: isActive,
        searchPageBuilder: searchPageBuilder,
      ),
      isActive: isActive,
      onError: (error, stack) => Log.error('Text share', error, stack),
    );
    return true;
  }
  appNavigation.clearPendingNavigation();
  _openSharedSearch(
    keyword: event,
    isActive: isActive,
    searchPageBuilder: searchPageBuilder,
  );
  return true;
}
