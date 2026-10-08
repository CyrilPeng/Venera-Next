import 'source.dart';
import 'source_mutation_failure.dart';

typedef SourceScriptReplacement =
    Future<ComicSource> Function(ComicSource source, String script);

/// Keeps successive edits on the instances produced by this editing session.
/// The injected replacement owns admission, serialization and persistence.
class SourceScriptSession {
  SourceScriptSession({
    required ComicSource source,
    required SourceScriptReplacement replace,
  }) : _source = source,
       _replace = replace;

  ComicSource _source;
  final SourceScriptReplacement _replace;
  bool _saving = false;
  ({SourceMutationFailure error, StackTrace stack})? _blocked;

  bool get canSave => _blocked == null;

  Future<void> save(String script) async {
    if (_blocked case final failure?) {
      Error.throwWithStackTrace(failure.error, failure.stack);
    }
    if (_saving) throw StateError('Source script save is already running');
    _saving = true;
    try {
      // Do not find by key after awaiting: a later queued mutation may already
      // have installed a different source that this editor must not overwrite.
      _source = await _replace(_source, script);
    } on SourceMutationFailure catch (error, stack) {
      // Applied is not proof of a durable commit decision. Keep the original
      // failure and draft, and never replay an applied or unresolved mutation.
      // Ordinary failures with a successful rollback remain retryable.
      _blocked = (error: error, stack: stack);
      rethrow;
    } finally {
      _saving = false;
    }
  }
}
