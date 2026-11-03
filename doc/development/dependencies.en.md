# Dependency Governance

Default Chinese version: [dependencies.zh.md](dependencies.zh.md)

This document records governance rules for VeneraNext's direct dependencies, especially Git dependencies that are not resolved from pub.dev. `pubspec.lock` is part of reproducible builds, but it does not replace documenting dependency provenance and maintenance responsibility.

## Rules

See the [2026-09-28 audit](dependency_audit.en.md) for ownership and replacement decisions. [git_dependencies.json](git_dependencies.json) records current origins, pins, and all transitive Git packages. Update it with every Git dependency change and run `dart tool/check_git_dependencies.dart`.

- Commit related changes to both `pubspec.yaml` and `pubspec.lock`.
- Prefer stable pub.dev packages. Every Git fork must have a documented reason.
- Pin Git dependencies to immutable commits. Do not use a default branch, `main`, or `HEAD`.
- Tools installed with `dart pub global activate` in release workflows must use the same pinned commit.
- Review upstream changes, security advisories, licenses, platform builds, and relevant tests when upgrading.
- Publishing a fork to pub.dev does not replace security maintenance; a diff audit and upstream synchronization plan are still required.

## Current Git Dependencies

2026-09-28: `flutter_qjs`, `photo_view`, `flutter.widgets`, `flutter_inappwebview`, and `webdav_client` moved to the existing forks under `CyrilPeng`, without changing pinned commits. The six platform subpackages of `flutter_inappwebview` resolve through repository-relative paths to the same fork. That stage changed provenance only, not versions. On 2026-10-05, `photo_view` became the local path package documented below and left the current Git inventory. Roll back dependency declarations, lockfile, and the corresponding inventory entry together.

VeneraNext maintainers own patch selection, upstream review, and validation for these forks. Preserve original copyrights and licenses. Mirroring does not replace ongoing maintenance or resolve missing licenses.

| Dependency | Commit | Upstream / license | Immediate reason for retaining the customized repository |
|---|---|---|---|
| `flutter_qjs` | `295f77421eedff356a02e92987181b525970c780` | Fork upstream not recorded / MIT | Retains NDK r28 support and skips numeric-buffer reference walks for asynchronous byte results; replacement requires runtime and native platform verification |
| `scrollable_positioned_list` | `09e756b1f1b04e6298318d99ec20a787fb360f59` | `google/flutter.widgets` / BSD-3-Clause | The pinned revision adds `scrollControllerCallback` and `scrollBehavior`, used by continuous-reader positioning |
| `desktop_webview_window` | `7801fc582ecf5a7351632887891ecf309a7b2583` | `wgh136/flutter_desktop_webview` / not declared | The pinned revision fixes Windows ARM64 builds; replacement requires verification on every desktop platform |
| `flutter_inappwebview` | `3ef899b3db57c911b080979f1392253b835f98ab` | `pichillilorenzo/flutter_inappwebview` / Apache-2.0 | The pinned revision fixes `GraphicsContext` deallocation; embedded WebView and Cloudflare flows rely on this branch behavior |
| `lodepng_flutter` | `ac7d05dde32e8d728102a9ff66e6b55f05d94ba1` | Fork upstream not recorded / license file is still a placeholder | The pinned revision includes NDK r28 build support, and the image pipeline still uses its native plugin |
| `webdav_client` | `2f669c98fb81cff1c64fee93466a1475c77e4273` | `wgh136/webdav_client` / BSD-3-Clause | The pinned revision adds multiple authentication methods required by WebDAV reading and backup compatibility |
| `flutter_saf` | `fe182cdf40e5fa6230f451bc1d643b860f610d13` | `pkuislm/flutter_saf` / license file is still a placeholder | The pinned revision disables minification to avoid Android release-build problems; storage access still uses this plugin |
| `flutter_7zip` | `b33344797f1d2469339e0e1b75f5f954f1da224c` | `wgh136/flutter_7zip` / license file is still a placeholder | The pinned revision fixes compilation errors, and CBZ/archive fallback compatibility still uses this plugin |

The table uses commit messages to explain why the project cannot immediately switch back to upstream. It is not a complete diff audit. Every Git dependency update must document the upstream repository, comparison range, all custom changes, upstream PR if any, security impact, and rollback path.

`desktop_webview_window` does not declare a license, while `lodepng_flutter`, `flutter_saf`, and `flutter_7zip` still contain placeholder license files. These are known supply-chain debts. Confirm licensing with the maintainers before upgrading; if it cannot be confirmed, migrate to an upstream revision or replacement with clear licensing.

## QuickJS Numeric-Buffer Reference Walk Fix (2026-10-31)

The pin moves from `8feae95df7fb00455df129ad7a0dfec1d0e8d8e4` to `295f77421eedff356a02e92987181b525970c780` on the existing fork's `venera-next-pinned` branch. The application still uses the full immutable commit, not a floating branch.
The [complete diff](https://github.com/CyrilPeng/flutter_qjs/compare/8feae95df7fb00455df129ad7a0dfec1d0e8d8e4...295f77421eedff356a02e92987181b525970c780) contains only a `TypedData` early return in `lib/src/ffi.dart`, regression tests, and the dependency changelog. License, package version 0.3.7, native code, NDK/CMake and platform settings are unchanged. No unverified upstream PR is claimed.

Previously, `JSRef._callRecursive` copied and scanned `Uint8List` as an ordinary list even though numeric buffers cannot contain JS references. Skipping those buffers removes unnecessary Promise byte-result walks while preserving normal list/map traversal, aliases, cycles, callbacks and asynchronous completion. It does not disable processing, rewrite user scripts, or introduce zero-copy buffers.
The [reader diagnostic record](reader_diagnostics.md) preserves an isolated A/B/A comparison and its limits. Two dependency-local regressions cover buffers and cyclic graphs; application regressions cover results, cancellation, errors, workers and reference release. Host checks do not replace Android-device retesting or platform builds, and do not close #125.

This is not a QuickJS engine security upgrade and does not resolve the existing upstream-provenance debt. It adds no permissions or network capabilities. Roll back the pin in `pubspec.yaml`, `pubspec.lock`, `git_dependencies.json` and the current dependency table together, then revalidate loading/processing lifetimes; never patch the shared Pub cache as a rollback mechanism.

## Locally Maintained PhotoView

`photo_view` resolves through `path: packages/photo_view` to the [local package](../../packages/photo_view/pubspec.yaml), still at version **0.14.0**. Its source is the previously pinned [CyrilPeng/photo_view](https://github.com/CyrilPeng/photo_view) commit `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c`, with [renancaraujo/photo_view](https://github.com/renancaraujo/photo_view) as upstream. Original copyrights and the [MIT license](../../packages/photo_view/LICENSE) remain unchanged. VeneraNext maintainers own the local patch and future upstream comparisons.

[LOCAL_PATCHES.md](../../packages/photo_view/LOCAL_PATCHES.md) records canonical Git blob SHA-256 hashes, retained files, and validation. The patch fixes leaked `ImageInfo` clones in the dimension listener by disposing each clone in `finally` after reading its size. The painting listener continues to own its separate image. Three equivalent calls also replace deprecated SDK APIs:

- `TickerMode.of(context)` → `TickerMode.valuesOf(context).enabled`.
- `translate(dx, dy)` → `translateByDouble(dx, dy, 0.0, 1.0)`.
- `scale(s)` → `scaleByDouble(s, s, s, 1.0)`, preserving scaling on all three axes and the homogeneous coordinate.

The migration retains the existing fork's reader interfaces and behavior; it does not adopt the pub.dev release. After formatter normalization, only the three documented source files differ. Package version, manifest dependencies, all **156** other locked dependency records, and SDK locks remain unchanged. `git_dependencies.json` lists active Git dependencies, so its `photo_view` entry is removed while the local patch record preserves full provenance. Resolve dependencies with `PUB_HOSTED_URL=https://pub.dev` to match the lockfile, using `flutter pub get --offline --enforce-lockfile`.

Real PhotoView regressions cover cached and asynchronous first frames, replacement, unmount cleanup, contained sizing, and zoom. The PR build rules already include `packages/`, so changes to this package trigger existing platform validation without a separate rule change. Restoring the Git source requires restoring `pubspec.yaml`, `pubspec.lock`, and the Git inventory together, then revalidating image lifetimes.

## Rust Security Maintenance for Local Rhttp

`packages/rhttp` retains the local callback cancellation patch and
`flutter_rust_bridge =2.11.1`. Rust transitive dependency versions and security
advisories are recorded in [LOCAL_PATCHES.md](../../packages/rhttp/LOCAL_PATCHES.md).
The project and CI pin Rust 1.92.0 to satisfy the fixed dependencies' compiler
requirements.

Dependabot checks `/packages/rhttp/rust` weekly. Rust bridge updates must be
validated with the Dart dependency and generated code, so they are not upgraded
independently. The [dependency security workflow](../../.github/workflows/dependency_review.yml)
audits the complete Rust lockfile on pull requests, main pushes, manual dispatch
and a weekly schedule. Known vulnerabilities and unsoundness warnings fail the
audit, including those in dependencies already present in the lockfile.

Run the same check locally:

```sh
cargo install cargo-audit --version 0.22.2 --locked --no-default-features
cargo audit --file packages/rhttp/rust/Cargo.lock --deny unsound
```

After updating the lockfile, rebuild the native Rhttp library before running
callback cancellation and Flutter network regressions so tests cannot use an
old DLL. Update both `rust-toolchain.toml` and
`.github/scripts/prepare_rust_toolchain.py` when changing the toolchain, then
validate platform builds.

## Upstreaming Process

1. Compare the pinned commit with the corresponding upstream version.
2. Submit generic changes upstream as focused pull requests.
3. Document and test changes that cannot be upstreamed.
4. Update the fork after upstream security fixes, then update this repository's pinned commit.
5. Record risks for abandoned dependencies that cannot yet be replaced; never silently switch to a floating branch.

## Review Checklist

- [ ] `pubspec.yaml` uses immutable commits, never `HEAD` or a default branch.
- [ ] Resolved commits in `pubspec.lock` match the declarations.
- [ ] Release workflows use the same commit for Git-installed tools.
- [ ] `flutter pub get --enforce-lockfile`, `flutter analyze --no-pub`, and `flutter test --no-pub` have passed.
- [ ] Platform builds have passed, or unverified platforms are documented.
- [ ] Licenses, security advisories, and upstream changes have been reviewed.
