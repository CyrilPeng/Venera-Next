import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum ZipFixtureDamage { deflate, checksum, size, truncatedDirectory }

class ZipFixtureEntry {
  const ZipFixtureEntry(
    this.name,
    this.content, {
    this.utf8Name = false,
    this.compress = true,
    this.unicodePath,
    this.validUnicodePathCrc = true,
  });

  final List<int> name;
  final List<int> content;
  final bool utf8Name;
  final bool compress;
  final String? unicodePath;
  final bool validUnicodePathCrc;
}

// Write small ZIP32 fixtures without the archive package under test. Damage
// affects the last member, so earlier valid entries can test partial imports.
Uint8List zipFixture(
  List<ZipFixtureEntry> entries, {
  ZipFixtureDamage? damage,
}) {
  final files = BytesBuilder();
  final directory = BytesBuilder();
  for (final (index, entry) in entries.indexed) {
    final damaged = index == entries.length - 1 ? damage : null;
    final content = Uint8List.fromList(
      entry.compress
          ? ZLibCodec(raw: true).encode(entry.content)
          : entry.content,
    );
    if (damaged == ZipFixtureDamage.deflate) {
      if (!entry.compress) {
        throw ArgumentError('Deflate damage needs compression');
      }
      // BTYPE=3 is reserved; keep every ZIP header and size intact.
      content[0] = (content[0] & 0xf8) | 7;
    }
    final crc =
        _crc32(entry.content) ^ (damaged == ZipFixtureDamage.checksum ? 1 : 0);
    final size =
        entry.content.length + (damaged == ZipFixtureDamage.size ? 1 : 0);
    final extra = _unicodePathExtra(entry);
    final flags = entry.utf8Name ? 0x800 : 0;
    final method = entry.compress ? 8 : 0;
    final offset = files.length;
    files
      ..add(
        (ByteData(30)
              ..setUint32(0, 0x04034b50, Endian.little)
              ..setUint16(4, 20, Endian.little)
              ..setUint16(6, flags, Endian.little)
              ..setUint16(8, method, Endian.little)
              ..setUint16(12, 0x21, Endian.little)
              ..setUint32(14, crc, Endian.little)
              ..setUint32(18, content.length, Endian.little)
              ..setUint32(22, size, Endian.little)
              ..setUint16(26, entry.name.length, Endian.little)
              ..setUint16(28, extra.length, Endian.little))
            .buffer
            .asUint8List(),
      )
      ..add(entry.name)
      ..add(extra)
      ..add(content);
    directory
      ..add(
        (ByteData(46)
              ..setUint32(0, 0x02014b50, Endian.little)
              ..setUint16(4, 20, Endian.little)
              ..setUint16(6, 20, Endian.little)
              ..setUint16(8, flags, Endian.little)
              ..setUint16(10, method, Endian.little)
              ..setUint16(14, 0x21, Endian.little)
              ..setUint32(16, crc, Endian.little)
              ..setUint32(20, content.length, Endian.little)
              ..setUint32(24, size, Endian.little)
              ..setUint16(28, entry.name.length, Endian.little)
              ..setUint16(30, extra.length, Endian.little)
              ..setUint32(42, offset, Endian.little))
            .buffer
            .asUint8List(),
      )
      ..add(entry.name)
      ..add(extra);
  }
  final directoryOffset = files.length;
  final directorySize = directory.length;
  files
    ..add(directory.takeBytes())
    ..add(
      (ByteData(22)
            ..setUint32(0, 0x06054b50, Endian.little)
            ..setUint16(8, entries.length, Endian.little)
            ..setUint16(10, entries.length, Endian.little)
            ..setUint32(12, directorySize, Endian.little)
            ..setUint32(16, directoryOffset, Endian.little))
          .buffer
          .asUint8List(),
    );
  final bytes = files.takeBytes();
  return damage == ZipFixtureDamage.truncatedDirectory
      ? Uint8List.sublistView(bytes, 0, bytes.length - 5)
      : bytes;
}

List<int> _unicodePathExtra(ZipFixtureEntry entry) {
  final path = entry.unicodePath;
  if (path == null) return const [];
  final encoded = utf8.encode(path);
  return [
    ...(ByteData(9)
          ..setUint16(0, 0x7075, Endian.little)
          ..setUint16(2, encoded.length + 5, Endian.little)
          ..setUint8(4, 1)
          ..setUint32(
            5,
            _crc32(entry.name) ^ (entry.validUnicodePathCrc ? 0 : 1),
            Endian.little,
          ))
        .buffer
        .asUint8List(),
    ...encoded,
  ];
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return crc ^ 0xffffffff;
}
