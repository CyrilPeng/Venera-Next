import 'package:flutter/foundation.dart';

enum EInkRefreshStyle {
  black('black'),
  white('white'),
  whiteThenBlack('whiteThenBlack');

  const EInkRefreshStyle(this.key);

  final String key;

  static EInkRefreshStyle fromKey(String? key) {
    return values.firstWhere(
      (style) => style.key == key,
      orElse: () => EInkRefreshStyle.black,
    );
  }
}

class EInkRefreshRequest {
  const EInkRefreshRequest({
    required this.id,
    required this.durationMilliseconds,
    required this.style,
  });

  final int id;
  final int durationMilliseconds;
  final EInkRefreshStyle style;
}

class EInkRefreshController extends ChangeNotifier {
  EInkRefreshRequest? _request;
  int _pageChangeCount = 0;
  int? _interval;

  EInkRefreshRequest? get request => _request;

  bool onPageChanged({
    required int interval,
    required int durationMilliseconds,
    required EInkRefreshStyle style,
  }) {
    final normalizedInterval = interval.clamp(1, 10).toInt();
    if (_interval != normalizedInterval) {
      _interval = normalizedInterval;
      _pageChangeCount = 0;
    }

    final shouldRefresh = _pageChangeCount % normalizedInterval == 0;
    _pageChangeCount++;
    if (!shouldRefresh) {
      return false;
    }

    _request = EInkRefreshRequest(
      id: (_request?.id ?? 0) + 1,
      durationMilliseconds: durationMilliseconds.clamp(100, 1500).toInt(),
      style: style,
    );
    notifyListeners();
    return true;
  }

  void reset() {
    _pageChangeCount = 0;
    _interval = null;
  }
}
