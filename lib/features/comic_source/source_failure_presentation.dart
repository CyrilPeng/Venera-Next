import 'package:venera_next/foundation/translations.dart';
import 'source_failure.dart';

String sourceFailureMessage(Object error) =>
    error is SourceFailure ? error.code.message.tl : error.toString();
