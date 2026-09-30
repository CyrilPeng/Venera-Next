/// Explicit startup dependencies; no constructor side effects or UI requirement.
/// A failed startup is cached: partial databases must not be reopened implicitly.
class CoreBootstrap {
  CoreBootstrap({
    required this.environment,
    required this.settings,
    required this.infrastructure,
    required this.sources,
    required this.stores,
    required this.finish,
  });
  final Future<void> Function() environment;
  final Future<void> Function() settings;
  final Future<void> Function() infrastructure;
  final Future<void> Function() sources;
  final Future<void> Function() stores;
  final Future<void> Function() finish;
  Future<void>? _startup;

  Future<void> start() => _startup ??= _start();

  Future<void> _start() async {
    await environment();
    await settings();
    await infrastructure();
    // Stores may await source readiness. Do not start them if source startup
    // fails before the source manager's init attempt can be created.
    await sources();
    await stores();
    await finish();
  }
}
