enum ProxyMode { direct, system, manual }

/// The saved proxy editor dialect, not the platform's system-proxy response.
/// Keeps the existing separator rules and raw text (including port spelling).
class ProxyConfiguration {
  const ProxyConfiguration({
    required this.mode,
    this.host = '',
    this.port = '',
    this.username = '',
    this.password = '',
  });

  final ProxyMode mode;
  final String host, port, username, password;

  factory ProxyConfiguration.parse(String proxy) {
    if (proxy == 'direct') {
      return const ProxyConfiguration(mode: ProxyMode.direct);
    } else if (proxy == 'system') {
      return const ProxyConfiguration(mode: ProxyMode.system);
    }
    var host = '', port = '', username = '', password = '';
    var parts = proxy.split('@');
    if (parts.length == 2) {
      var auth = parts[0].split(':');
      if (auth.length == 2) {
        username = auth[0];
        password = auth[1];
      }
      parts = parts[1].split(':');
      if (parts.length == 2) {
        host = parts[0];
        port = parts[1];
      }
    } else {
      parts = proxy.split(':');
      if (parts.length == 2) {
        host = parts[0];
        port = parts[1];
      }
    }
    return ProxyConfiguration(
      mode: ProxyMode.manual,
      host: host,
      port: port,
      username: username,
      password: password,
    );
  }

  String serialize() {
    if (mode == ProxyMode.direct) return 'direct';
    if (mode == ProxyMode.system) return 'system';
    var res = '';
    if (username.isNotEmpty) {
      res += username;
      if (password.isNotEmpty) res += ':$password';
      res += '@';
    }
    res += host;
    if (port.isNotEmpty) res += ':$port';
    return res;
  }

  ProxyConfiguration copyWith({
    ProxyMode? mode,
    String? host,
    String? port,
    String? username,
    String? password,
  }) => ProxyConfiguration(
    mode: mode ?? this.mode,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    password: password ?? this.password,
  );
}
