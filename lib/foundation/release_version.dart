/// return true if version1 > version2
bool _compareVersion(String version1, String version2) {
  var v1 = _versionNumbers(version1);
  var v2 = _versionNumbers(version2);
  final length = v1.length > v2.length ? v1.length : v2.length;
  for (var i = 0; i < length; i++) {
    var n1 = i < v1.length ? v1[i] : 0;
    var n2 = i < v2.length ? v2[i] : 0;
    if (n1 > n2) return true;
    if (n1 < n2) return false;
  }
  return _comparePrerelease(_prerelease(version1), _prerelease(version2));
}

bool shouldNotifyRelease(String remoteVersion, String currentVersion) {
  return _canNotifyChannel(remoteVersion, currentVersion) &&
      _compareVersion(remoteVersion, currentVersion);
}

bool _canNotifyChannel(String remoteVersion, String currentVersion) {
  return !_isPrerelease(remoteVersion) || _isPrerelease(currentVersion);
}

bool allowsPrereleaseUpdates(String currentVersion) {
  return _isPrerelease(currentVersion);
}

String? selectPublishedReleaseVersion(
  Object? response, {
  required bool includePrerelease,
}) {
  final releases = response is List ? response : [response];
  return releases
      .whereType<Map>()
      .where((release) => release["draft"] != true)
      .where((release) => includePrerelease || release["prerelease"] != true)
      .map((release) => release["tag_name"]?.toString())
      .whereType<String>()
      .map((tag) => tag.replaceFirst(RegExp(r'^[vV]'), ''))
      .fold<String?>(null, (latest, version) {
        if (latest == null) return version;
        return _compareVersion(version, latest) ? version : latest;
      });
}

bool _isPrerelease(String version) => _prerelease(version) != null;

String _versionCore(String version) {
  return version.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
}

List<int> _versionNumbers(String version) {
  return _versionCore(version)
      .split('-')
      .first
      .split('.')
      .map((segment) => int.tryParse(segment) ?? 0)
      .toList();
}

String? _prerelease(String version) {
  var core = _versionCore(version);
  var index = core.indexOf('-');
  return index == -1 ? null : core.substring(index + 1);
}

bool _comparePrerelease(String? version1, String? version2) {
  if (version1 == null || version2 == null) {
    return version1 == null && version2 != null;
  }

  var parts1 = version1.split('.');
  var parts2 = version2.split('.');
  final length = parts1.length > parts2.length ? parts1.length : parts2.length;
  for (var i = 0; i < length; i++) {
    if (i >= parts1.length) return false;
    if (i >= parts2.length) return true;

    var part1 = parts1[i];
    var part2 = parts2[i];
    var num1 = int.tryParse(part1);
    var num2 = int.tryParse(part2);
    if (num1 != null && num2 != null) {
      if (num1 > num2) return true;
      if (num1 < num2) return false;
    } else if (num1 != null) {
      return false;
    } else if (num2 != null) {
      return true;
    } else {
      var comparison = part1.compareTo(part2);
      if (comparison > 0) return true;
      if (comparison < 0) return false;
    }
  }
  return false;
}
