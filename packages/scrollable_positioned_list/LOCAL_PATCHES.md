# Local scrollable_positioned_list 0.3.8+1

Source: https://github.com/CyrilPeng/flutter.widgets at commit
`09e756b1f1b04e6298318d99ec20a787fb360f59`, package directory
`packages/scrollable_positioned_list`. Upstream is
https://github.com/google/flutter.widgets. The original BSD-3-Clause `LICENSE`,
copyright notices and package version are retained. VeneraNext maintainers own
the local copy and future upstream comparisons.

## Retained behavior and files

The pinned fork adds `scrollControllerCallback` and `scrollBehavior` to the
positioned-list implementation. The reader uses these interfaces for scroll
control, automatic reading and gesture behavior. They remain available with
their existing signatures and behavior.

All twelve `lib/` files, `pubspec.yaml`, `LICENSE`, upstream README and CHANGELOG
are retained. The package also retains the analysis policy inherited from the
upstream monorepo's root `analysis_options.yaml`; its manifest entry identifies
that root source path. Examples, upstream test projects, Git metadata and build
outputs are omitted. The application already covers continuous-reader scrolling,
automatic reading, image replacement, scroll ownership and reader exit.

`UPSTREAM_MANIFEST.json` records SHA-256 hashes of the retained canonical LF Git
blobs before local formatting, plus the reviewed local hashes. This records the
existing fork as the migration baseline; it does not claim equivalence to the
current official release. The Dart sources use the project's formatter.
Inherited trailing spaces in README and the null `lints` YAML value are trimmed;
manifest values, dependency constraints and documentation content are retained.

## Current-SDK compatibility

After identical Dart 3.11.4 formatting with language version 2.15, nine of the
twelve runtime files match the pinned source. Three have documented changes:

- `lib/src/wrapping.dart` uses
  `translateByDouble(offset.dx, offset.dy, 0.0, 1.0)` instead of the deprecated
  `translate(offset.dx, offset.dy)`. This is the exact double-argument branch of
  the application's locked vector_math 2.2.0 implementation.
- `lib/src/scrollable_positioned_list.dart` removes two private, unreferenced
  `ScrollOffsetController` attach/detach helpers. The used `ItemScrollController`
  helpers, controller binding, public APIs and scroll algorithms are unchanged.
- `lib/src/item_positions_listener.dart` documents a line-local
  `test_types_in_equals` exemption for the existing runtimeType-checked cast.
  Equality still distinguishes subclasses with the original implementation.

The inherited analysis policy, including its existing null-comparison handling,
is retained byte-for-byte. The application CI still treats analyzer warnings
and infos as fatal. No application-wide exclusions or quality gates change.

## Maintenance and rollback

Record future changes here and update the reviewed local hashes. Compare
upstream changes against the source commit, preserve applicable notices and
run dependency inventory checks and the affected reader regressions. Moving
the package into this repository does not replace upstream/security review.

The application commit now fixes the local source. Rollback to Git requires
restoring the original URL, full commit and package path in `pubspec.yaml`, the
matching `pubspec.lock` entry and the Git inventory record together. Retain the
old repository for historical builds; never patch the shared Pub cache.
