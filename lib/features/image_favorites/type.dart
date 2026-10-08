enum ImageFavoriteSortType {
  title("Title"),
  timeAsc("Time Asc"),
  timeDesc("Time Desc"),
  maxFavorites("Favorite Num"), // 单本收藏数最多排序
  favoritesCompareComicPages("Favorite Num Compare Comic Pages"); // 单本收藏数比上总页数

  final String value;

  const ImageFavoriteSortType(this.value);
}

const numFilterList = [0, 1, 2, 5, 10, 20, 50, 100];

class TimeRange {
  /// End of the range, null means now
  final DateTime? end;

  /// Duration of the range
  final Duration duration;

  /// Create a time range
  const TimeRange({this.end, required this.duration});

  static const all = TimeRange(end: null, duration: Duration.zero);

  static const lastWeek = TimeRange(end: null, duration: Duration(days: 7));

  static const lastMonth = TimeRange(end: null, duration: Duration(days: 30));

  static const lastHalfYear = TimeRange(
    end: null,
    duration: Duration(days: 180),
  );

  static const lastYear = TimeRange(end: null, duration: Duration(days: 365));

  @override
  String toString() {
    return "${end?.millisecondsSinceEpoch}:${duration.inMilliseconds}";
  }

  /// Preserve the existing `end:duration` format, including rolling ranges.
  /// Invalid or irrecoverably truncated old dates fall back to [TimeRange.all].
  factory TimeRange.fromString(Object? str) {
    if (str is! String) {
      return TimeRange.all;
    }
    final parts = str.split(":");
    if (parts.length != 2) return TimeRange.all;
    final milliseconds = int.tryParse(parts[1]);
    if (milliseconds == null || milliseconds < 0) return TimeRange.all;
    final endMilliseconds = parts[0] == 'null' ? null : int.tryParse(parts[0]);
    if (parts[0] != 'null' && endMilliseconds == null) return TimeRange.all;
    // The old writer saved DateTime.millisecond instead of the epoch. Those
    // 0..999 values cannot recover dates selected by the UI (year 2000 onward).
    if (endMilliseconds != null &&
        endMilliseconds >= 0 &&
        endMilliseconds < 1000) {
      return TimeRange.all;
    }
    try {
      final duration = Duration(milliseconds: milliseconds);
      // Duration uses microseconds internally; reject integer overflow.
      if (duration.inMilliseconds != milliseconds) return TimeRange.all;
      final end = endMilliseconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(endMilliseconds);
      // Filtering and the date editor must be able to represent the start too.
      (end ?? DateTime.now()).subtract(duration);
      return TimeRange(end: end, duration: duration);
    } on ArgumentError {
      return TimeRange.all;
    }
  }

  /// Check if a time is in the range
  bool contains(DateTime time) {
    if (end != null && time.isAfter(end!)) {
      return false;
    }
    if (duration == Duration.zero) {
      return true;
    }
    final start = end == null
        ? DateTime.now().subtract(duration)
        : end!.subtract(duration);
    return time.isAfter(start);
  }

  @override
  bool operator ==(Object other) {
    return other is TimeRange && other.end == end && other.duration == duration;
  }

  @override
  int get hashCode => end.hashCode ^ duration.hashCode;

  static const List<TimeRange> values = [
    all,
    lastWeek,
    lastMonth,
    lastHalfYear,
    lastYear,
  ];
}

enum TimeRangeType {
  all("All"),
  lastWeek("Last Week"),
  lastMonth("Last Month"),
  lastHalfYear("Last Half Year"),
  lastYear("Last Year"),
  custom("Custom");

  final String value;

  const TimeRangeType(this.value);
}
