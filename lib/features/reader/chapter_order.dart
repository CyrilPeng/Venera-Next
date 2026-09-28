/// Reading order uses source chapter indices and preserves the order of groups.
class ChapterReadingOrder {
  const ChapterReadingOrder(this.groupLengths, {this.reversed = false});

  final List<int> groupLengths;
  final bool reversed;

  Iterable<int> get chapters sync* {
    var start = 1;
    for (final length in groupLengths) {
      for (var i = 0; i < length; i++) {
        yield start + (reversed ? length - i - 1 : i);
      }
      start += length;
    }
  }

  int? next(int chapter, {bool acrossGroups = true}) =>
      _adjacent(chapter, 1, acrossGroups);

  int? previous(int chapter, {bool acrossGroups = true}) =>
      _adjacent(chapter, -1, acrossGroups);

  int? _adjacent(int chapter, int direction, bool acrossGroups) {
    var start = 1;
    for (var group = 0; group < groupLengths.length; group++) {
      final end = start + groupLengths[group] - 1;
      if (chapter >= start && chapter <= end) {
        final target = chapter + (reversed ? -direction : direction);
        if (target >= start && target <= end) return target;
        if (!acrossGroups) return null;
        var adjacentGroup = group + direction;
        var adjacentStart = direction > 0
            ? end + 1
            : start - (adjacentGroup >= 0 ? groupLengths[adjacentGroup] : 0);
        while (adjacentGroup >= 0 && adjacentGroup < groupLengths.length) {
          final length = groupLengths[adjacentGroup];
          if (length > 0) {
            return (direction > 0) != reversed
                ? adjacentStart
                : adjacentStart + length - 1;
          }
          adjacentGroup += direction;
          if (direction < 0 && adjacentGroup >= 0) {
            adjacentStart -= groupLengths[adjacentGroup];
          }
        }
        return null;
      }
      start = end + 1;
    }
    return null;
  }
}
