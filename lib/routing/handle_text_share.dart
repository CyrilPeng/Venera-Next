import 'package:venera_next/foundation/event_subscription.dart';
import 'package:venera_next/foundation/log.dart';
import 'package:flutter/services.dart';
import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/context.dart';
import 'package:venera_next/features/search/search.dart';

/// A caller-owned stream binding. Awaited navigation checks cannot outlive it.
EventSubscription<Object?> createTextShareSubscription() => EventSubscription(
  events: const EventChannel('venera/text_share').receiveBroadcastStream(),
  handle: (event, isActive) async {
    if (App.mainNavigatorKey == null) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (!isActive()) return;
    if (event is String) {
      App.rootNavigatorKey.currentContext?.to(
        () => AggregatedSearchPage(keyword: event),
      );
    }
  },
  onError: (error, stack) => Log.error('Text share', error, stack),
);
