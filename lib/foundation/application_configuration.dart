import 'application_preferences.dart';

class NetworkConfiguration {
  NetworkConfiguration.read(Object? Function(String key) read)
    : proxy = NetworkPreferences.proxy.normalize(
        read(NetworkPreferences.proxy.key),
      ),
      sni = NetworkPreferences.sni.normalize(read(NetworkPreferences.sni.key)),
      ignoreBadCertificate = NetworkPreferences.ignoreBadCertificate.normalize(
        read(NetworkPreferences.ignoreBadCertificate.key),
      ),
      enableDnsOverrides = NetworkPreferences.enableDnsOverrides.normalize(
        read(NetworkPreferences.enableDnsOverrides.key),
      ),
      dnsOverrides = NetworkPreferences.dnsOverrides.normalize(
        read(NetworkPreferences.dnsOverrides.key),
      ),
      downloadThreads = NetworkPreferences.downloadThreads
          .normalize(read(NetworkPreferences.downloadThreads.key))
          .toInt();

  final String proxy;
  final bool sni;
  final bool ignoreBadCertificate;
  final bool enableDnsOverrides;
  final Map<String, String> dnsOverrides;
  final int downloadThreads;

  Map<String, List<String>> get effectiveDnsOverrides => {
    if (enableDnsOverrides)
      for (final entry in dnsOverrides.entries) entry.key: [entry.value],
  };
}

class AppearanceConfiguration {
  AppearanceConfiguration.read(Object? Function(String key) read)
    : themeMode = AppearancePreferences.themeMode.normalize(
        read(AppearancePreferences.themeMode.key),
      ),
      color = AppearancePreferences.color.normalize(
        read(AppearancePreferences.color.key),
      );
  final String themeMode;
  final String color;
}
