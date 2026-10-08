import 'package:venera_next/foundation/app.dart';
import 'package:venera_next/foundation/window_placement_tracker.dart';
import 'package:venera_next/routing/app_links.dart';
import 'package:venera_next/routing/handle_text_share.dart';

import 'interactive_bindings.dart';
import 'windows_heartbeat.dart';

/// Assemble UI event handlers at the interactive application boundary.
InteractiveBindings createPlatformInteractiveBindings({
  WindowPlacementTracker? placement,
}) {
  final heartbeat = WindowsHeartbeat();
  return InteractiveBindings(
    android: App.isAndroid,
    windows: App.isWindows,
    links: createAppLinkSubscription,
    shares: createTextShareSubscription,
    heartbeat: heartbeat.send,
    closeHeartbeat: heartbeat.close,
    placement: placement,
  );
}
