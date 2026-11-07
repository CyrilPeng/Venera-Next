# Local webdav_client 1.2.2

Source: https://github.com/CyrilPeng/webdav_client at commit
`2f669c98fb81cff1c64fee93466a1475c77e4273`. The package identifies
https://github.com/flymzero/webdav_client as upstream. The original BSD-3-Clause
`LICENSE`, copyright notices and package version are retained. VeneraNext
maintainers own the local copy and future upstream comparisons.

## Retained behavior and files

The pinned fork supports the `newClient` adapter parameter used by the
application's HTTP transport, 301/302 redirect handling, uploads and multiple
authentication modes. All existing runtime behavior is retained during the
source migration.

All eleven `lib/` files, `pubspec.yaml`, `LICENSE`, upstream README and CHANGELOG
are retained. Examples, images used by the upstream README, upstream test
projects, Git metadata and build outputs are omitted. The application already
tests its actual WebDAV HTTP request builder, client ownership, library
transport and backup/synchronization paths with synthetic local fixtures.

`UPSTREAM_MANIFEST.json` records SHA-256 hashes of the retained canonical LF Git
blobs before local formatting, plus the reviewed local hashes. This preserves
the existing fork as the migration baseline; it is not a switch to the official
pub.dev release. The Dart sources use the project's formatter.
Inherited trailing spaces in README and CHANGELOG are trimmed without changing
their content. Manifest values and dependency constraints remain unchanged.

## Current-SDK compatibility

After identical Dart 3.11.4 formatting with language version 2.12, eight of the
eleven runtime files match the pinned source. Three have documented changes:

- `lib/src/utils.dart` spells the locked Dio 5.11.1 aliases `DioError` and
  `DioErrorType` as `DioException` and `DioExceptionType`. The aliases resolve to
  these exact types; request options, response and error categories are retained.
- `lib/src/xml.dart` uses `innerText` instead of the deprecated `XmlElement.text`.
  In locked xml 6.6.1, the old getter delegates to the same `innerText` extension;
  directory metadata parsing keeps its original semantics.
- `lib/src/md5.dart` makes implicit dynamic function return/parameter types
  explicit for the current analyzer. Digest operations and method bodies remain
  unchanged; no narrower argument types are imposed.

The upstream package declares no lint set. The local `analysis_options.yaml`
preserves that policy rather than inheriting application style rules that would
require renaming public authentication enum members. Analyzer warnings and infos
still fail application CI; no application-wide exclusions or quality gates change.

## Maintenance and rollback

Record future changes here and update the reviewed local hashes. Compare
upstream updates against the source commit and validate adapters, authentication,
redirects, uploads, downloads and cancellation before adopting them. Preserve
the original license and continue security review of the HTTP dependencies.

The application commit now fixes the local source. Rollback to Git requires
restoring the original URL and full commit in `pubspec.yaml`, the matching
`pubspec.lock` entry and the Git inventory record together. Retain the old
repository for historical builds; never patch the shared Pub cache.
