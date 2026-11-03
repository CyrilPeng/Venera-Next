/// Page positions are zero-based and retain the source's original page order.
class IncompleteChapter {
  IncompleteChapter({required this.pageCount, required Iterable<int> missing})
    : missing = List<int>.unmodifiable(missing.toSet().toList()..sort()) {
    if (pageCount <= 0 ||
        pageCount > 1000000 ||
        this.missing.isEmpty ||
        this.missing.any((index) => index < 0 || index >= pageCount)) {
      throw const FormatException('Invalid incomplete chapter');
    }
  }

  final int pageCount;
  final List<int> missing;

  Map<String, Object> toJson() => {'count': pageCount, 'missing': missing};

  factory IncompleteChapter.fromJson(Map<String, dynamic> json) =>
      IncompleteChapter(
        pageCount: json['count'] as int,
        missing: List<int>.from(json['missing'] as List),
      );
}
