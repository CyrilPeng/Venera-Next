import 'package:venera_next/foundation/js_engine.dart';

void configureHeadlessBindings() {
  JsEngine.configureUiMessageHandler(const HeadlessJsUiHandler());
}

/// Headless commands cannot display or launch interactive source UI.
class HeadlessJsUiHandler implements JsUiMessageHandler {
  const HeadlessJsUiHandler();
  @override
  Object? handleUIMessage(Map<String, dynamic> message) {
    throw UnsupportedError('Source UI is unavailable in headless mode');
  }
}
