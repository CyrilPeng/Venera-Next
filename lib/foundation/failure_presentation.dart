import 'dart:io';

import 'package:venera_next/foundation/operation_failure.dart';
import 'package:venera_next/foundation/translations.dart';

/// Display-only classification. Raw errors stay intact for logs and details.
enum FailurePresentation {
  sourceScript,
  networkTimeout,
  networkConnection,
  httpStatus,
  cloudflare,
  fileMissing,
  storageBusy,
  noSpace,
  permission,
  cancelled,
  unsupported,
  unknown,
}

final _cancellation = RegExp(
  r'request cancelled|request canceled|operation cancelled|operation canceled|'
  r'dioexceptiontype\.cancel|^cancelled$|^canceled$',
);

final _sourceScript = RegExp(
  r'\b(ReferenceError|TypeError|SyntaxError|RangeError|EvalError|URIError)\b|'
  r'JSException|JavaScriptRuntimeException|ComicSourceParseException',
  caseSensitive: false,
);

final _timeout = RegExp(
  r'receive timeout|connection timeout|send timeout|timed out|'
  r'timeoutexception|took longer than|rhttptimeoutexception',
  caseSensitive: false,
);

final _connection = RegExp(
  r'rhttpconnectionexception|connection error|connection reset|'
  r'connection refused|broken pipe|failed host lookup|'
  r'network is unreachable|handshake|socketexception|tls ',
  caseSensitive: false,
);

final _httpStatus = RegExp(
  r'invalid status code|badresponse|statuscode|http status|status code',
  caseSensitive: false,
);

final _cloudflare = RegExp(
  r'cloudflareexception|cloudflare verification',
  caseSensitive: false,
);

final _fileMissing = RegExp(
  r'file not found|no such file|pathnotfound|path not found|'
  r'local comic files are unavailable|comic not found|'
  r'no local comic images found|directory does not exist|path does not exist',
  caseSensitive: false,
);

final _noSpace = RegExp(
  r'no space left|not enough space|disk full|insufficient storage',
  caseSensitive: false,
);

final _permission = RegExp(
  r'permission denied|operation not permitted|access denied|no permission',
  caseSensitive: false,
);

final _storageBusy = RegExp(
  r'local comic storage is busy|local storage is busy|'
  r'local library recovery is required|storage is closing|'
  r'wait for local file operations|wait for downloads to finish',
  caseSensitive: false,
);

final _unsupported = RegExp(
  r'unimplementederror|not implemented|unsupported|not supported',
  caseSensitive: false,
);

final _statusCode = RegExp(
  r'(?:invalid status code|statuscode|status code|http status)\D{0,8}(\d{3})',
  caseSensitive: false,
);

final _technical = RegExp(
  r'exception|^error\b|error:|#\d+\s|\b\w+\.(dart|js|kt|swift):\d+|'
  r'\(package:|dioexception',
  caseSensitive: false,
);

FailurePresentation classifyFailure(Object error) {
  if (error is FailureDetails) {
    if (error.kind == FailureKind.cancelled) {
      return FailurePresentation.cancelled;
    }
    if (error.kind == FailureKind.unsupported) {
      return FailurePresentation.unsupported;
    }
    final cause = error.cause;
    if (cause != null && !identical(cause, error)) {
      final nested = classifyFailure(cause);
      if (nested != FailurePresentation.unknown) return nested;
    }
    return classifyFailureMessage(error.message);
  }
  if (error is FileSystemException) {
    final lower = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    if (lower.contains('no space left') || lower.contains('disk full')) {
      return FailurePresentation.noSpace;
    }
    if (lower.contains('permission denied') ||
        lower.contains('operation not permitted')) {
      return FailurePresentation.permission;
    }
    if (lower.contains('no such file') || lower.contains('not found')) {
      return FailurePresentation.fileMissing;
    }
  }
  return classifyFailureMessage(error.toString());
}

FailurePresentation classifyFailureMessage(String message) {
  final text = message.trim();
  if (text.isEmpty) return FailurePresentation.unknown;
  final lower = text.toLowerCase();
  if (_cancellation.hasMatch(lower)) return FailurePresentation.cancelled;
  if (_sourceScript.hasMatch(text)) return FailurePresentation.sourceScript;
  if (_timeout.hasMatch(lower)) return FailurePresentation.networkTimeout;
  if (_connection.hasMatch(lower)) return FailurePresentation.networkConnection;
  if (_cloudflare.hasMatch(lower)) return FailurePresentation.cloudflare;
  if (_httpStatus.hasMatch(lower)) return FailurePresentation.httpStatus;
  if (_fileMissing.hasMatch(lower)) return FailurePresentation.fileMissing;
  if (_noSpace.hasMatch(lower)) return FailurePresentation.noSpace;
  if (_permission.hasMatch(lower)) return FailurePresentation.permission;
  if (_storageBusy.hasMatch(lower)) return FailurePresentation.storageBusy;
  if (_unsupported.hasMatch(lower)) return FailurePresentation.unsupported;
  return FailurePresentation.unknown;
}

/// A readable message for a structured or string error.
String presentFailure(Object error) =>
    _present(classifyFailure(error), error.toString());

/// A readable message when only the raw text crossed the boundary.
String presentFailureMessage(String message) =>
    _present(classifyFailureMessage(message), message);

/// Rewrite only messages that look like raw diagnostics. Friendly toasts pass
/// through unchanged, so this is safe at a shared toast boundary.
String presentTechnicalFailureMessage(String message) =>
    _looksTechnical(message) ? presentFailureMessage(message) : message;

String _present(FailurePresentation kind, String raw) {
  switch (kind) {
    case FailurePresentation.sourceScript:
      return 'The comic source script failed. Update or check the source, then retry.'
          .tl;
    case FailurePresentation.networkTimeout:
      return 'The request timed out. Check your network and try again.'.tl;
    case FailurePresentation.networkConnection:
      return 'Network connection failed. Check your network, proxy or VPN and try again.'
          .tl;
    case FailurePresentation.httpStatus:
      final code = _statusCode.firstMatch(raw)?.group(1);
      return code == null
          ? 'The server returned an error. Try again later or change the comic source.'
                .tl
          : 'The server returned an error (@code). Try again later or change the comic source.'
                .tlParams({'code': code});
    case FailurePresentation.cloudflare:
      return 'Cloudflare verification is required. Try again later.'.tl;
    case FailurePresentation.fileMissing:
      return 'The downloaded files are missing. Remove the local record or download again.'
          .tl;
    case FailurePresentation.storageBusy:
      return 'Local storage is busy. Wait for the current operation to finish and try again.'
          .tl;
    case FailurePresentation.noSpace:
      return 'Not enough storage space.'.tl;
    case FailurePresentation.permission:
      return 'No permission to access the required files or network resource.'
          .tl;
    case FailurePresentation.cancelled:
      return 'Cancelled.'.tl;
    case FailurePresentation.unsupported:
      return 'This operation is not supported for the current source or platform.'
          .tl;
    case FailurePresentation.unknown:
      return _readableFallback(raw);
  }
}

String _readableFallback(String raw) {
  final firstLine = raw.split('\n').first.trim();
  if (firstLine.isEmpty || _looksTechnical(raw)) {
    return 'Operation failed. Check Logs for details.'.tl;
  }
  return firstLine;
}

bool _looksTechnical(String message) =>
    message.contains('\n') || _technical.hasMatch(message);
