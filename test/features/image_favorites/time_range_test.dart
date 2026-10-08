import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/features/image_favorites/type.dart';

void main() {
  for (final range in TimeRange.values) {
    test('preset ${range.duration.inDays} days survives storage', () {
      expect(TimeRange.fromString(range.toString()), range);
    });
  }

  for (final utc in [false, true]) {
    test('custom ${utc ? 'UTC' : 'local'} range retains its instant', () {
      final end = utc
          ? DateTime.utc(2026, 10, 7, 12, 34, 56, 321)
          : DateTime(2026, 10, 7, 12, 34, 56, 321);
      final range = TimeRange(end: end, duration: const Duration(days: 9));
      final restored = TimeRange.fromString(range.toString());
      expect(restored.end!.isAtSameMomentAs(end), isTrue);
      expect(restored.duration, range.duration);
      expect(restored.toString(), range.toString());
    });
  }

  test('an unlisted rolling duration remains rolling', () {
    const range = TimeRange(duration: Duration(hours: 37, milliseconds: 21));
    expect(TimeRange.fromString(range.toString()), range);
  });

  test('old truncated custom dates safely fall back to all', () {
    for (final end in [0, 321, 999]) {
      expect(TimeRange.fromString('$end:604800000'), TimeRange.all);
    }
  });

  test('invalid types and malformed or negative ranges safely fall back', () {
    for (final value in <Object?>[
      null,
      123,
      true,
      [],
      {},
      '',
      'null',
      'null:1:2',
      'null:',
      ':1',
      'invalid:1',
      'null:no',
      'null:1.5',
      'null:-1',
      '2000:-100',
      'null:99999999999999999999999999999',
      '99999999999999999999999999999:1',
    ]) {
      expect(TimeRange.fromString(value), TimeRange.all, reason: '$value');
    }
  });

  test('duration overflow and unrepresentable start or end are rejected', () {
    for (final value in [
      'null:9223372036854775807',
      'null:9223372036854776',
      '8640000000000001:1',
      '-8640000000000001:1',
      '-8640000000000000:1',
      'null:9000000000000000',
    ]) {
      expect(TimeRange.fromString(value), TimeRange.all, reason: value);
    }
  });

  test('valid dates outside the original picker bounds retain their epoch', () {
    for (final end in [DateTime(1990, 3, 4), DateTime(2200, 5, 6)]) {
      final range = TimeRange(end: end, duration: const Duration(days: 2));
      expect(TimeRange.fromString(range.toString()), range);
    }
  });

  test('fixed interval remains start-exclusive and end-inclusive', () {
    final end = DateTime(2026, 10, 7);
    final start = end.subtract(const Duration(days: 7));
    final range = TimeRange.fromString(
      TimeRange(end: end, duration: const Duration(days: 7)).toString(),
    );
    expect(range.contains(start), isFalse);
    expect(range.contains(start.add(const Duration(milliseconds: 1))), isTrue);
    expect(range.contains(end), isTrue);
    expect(range.contains(end.add(const Duration(milliseconds: 1))), isFalse);
  });

  test('zero duration retains existing open-start and all behavior', () {
    final end = DateTime(2026, 10, 7);
    final range = TimeRange.fromString(
      TimeRange(end: end, duration: Duration.zero).toString(),
    );
    expect(range.contains(end.subtract(const Duration(days: 1000))), isTrue);
    expect(range.contains(end), isTrue);
    expect(range.contains(end.add(const Duration(milliseconds: 1))), isFalse);
    expect(TimeRange.all.contains(DateTime(1900)), isTrue);
    expect(TimeRange.all.contains(DateTime(2200)), isTrue);
  });
}
