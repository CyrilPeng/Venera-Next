/// The existing settings operations needed by scoped preference edits.
/// Implementations own inheritance, active-scope selection and notifications.
abstract interface class ReaderPreferenceSettings {
  Object? operator [](String key);
  void operator []=(String key, Object? value);

  Object? getReaderSetting(String comicId, String sourceKey, String key);
  Object? getDeviceReaderSetting(String key);
  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    Object? value,
  );
  void setDeviceReaderSetting(String key, Object? value);
  void setActiveReaderSetting(
    String? comicId,
    String? sourceKey,
    String key,
    Object? value,
  );
}
