class ComicSourceParseException implements Exception {
  final String message;

  ComicSourceParseException(this.message);

  @override
  String toString() {
    return message;
  }
}

class SourceAlreadyInstalledException extends ComicSourceParseException {
  SourceAlreadyInstalledException(this.key) : super('key($key) already exists');
  final String key;
}
