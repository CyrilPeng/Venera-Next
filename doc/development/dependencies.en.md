# Dependency Governance

Default Chinese version: [dependencies.zh.md](dependencies.zh.md)

This document records governance rules for VeneraNext's Git dependencies and repository-local source packages. `pubspec.lock` is part of reproducible builds, but it does not replace documenting dependency provenance and maintenance responsibility.

See the [2026-11-07 audit and proposal](official_dependency_plan_20261107.zh.md) for the pre-migration snapshot, and the [implementation record](official_dependency_implementation_20261107.zh.md) for current sources, rejected candidates and validation evidence.

## Rules

See the [dependency audit](dependency_audit.en.md) for ownership and replacement decisions. The [combined inventory](git_dependencies.json) keeps active Git origins and all transitive Git packages in `repositories`; `local_packages` records local paths, versions, upstreams, immutable source baselines, licenses and patch notes. Update it with every Git or local dependency change and run `dart tool/check_git_dependencies.dart`.

- Commit related changes to both `pubspec.yaml` and `pubspec.lock`.
- Prefer an official stable release that satisfies functionality, SDK, licensing and security requirements; next use a verified official full commit when the release lacks a required fix; retain necessary local patches or an existing fork only when neither meets those requirements.
- Prefer application adapters and public upstream interfaces to eliminate customization. When dependency source changes remain necessary, keep only their required scope, fixed by the application commit, instead of creating independent forks. Treat project-authored modules separately from same-name third-party packages.
- Every third-party local or fork exception must record the compared official release and commit, required patches, failure/validation evidence, exit conditions and maintenance responsibility. Reevaluate official sources after upstream covers the patches and acceptance passes; preserve existing security fixes during the transition.
- Each local package must identify its original upstream, complete source commit or archive SHA-256, version, retained license and checksum, maintenance reason and `LOCAL_PATCHES.md`. Switching to `path` must not bypass provenance review.
- Pin Git dependencies to immutable commits. Do not use a default branch, `main`, or `HEAD`.
- Tools installed with `dart pub global activate` in release workflows must use the same pinned commit.
- Review upstream changes, security advisories, licenses, platform builds, and relevant tests when upgrading.
- Publishing a fork to pub.dev does not replace security maintenance; a diff audit and upstream synchronization plan are still required.

## Current Git Dependencies

Five dependencies moved to existing forks under `CyrilPeng` on 2026-09-28 without changing pins. PhotoView became local on 2026-10-05; scrolling, WebDAV and desktop WebView became local on 2026-11-06, alongside project-authored native/SAF modules. On 2026-11-07 scrolling returns to official pub.dev 0.3.8 and six InAppWebView packages use one official commit; Windows instance ownership alone remains local. There are now two independent Git sources, seven Git packages and eight local packages. QuickJS is the only remaining personal Git source. Roll back declarations, lockfile and inventory together.

VeneraNext maintainers own necessary fork/local patches, upstream review and validation. Official Git sources also require checking the actual checkout HEAD, package directory and clean source. Preserve original copyrights and licenses; source ownership does not replace safety validation.

| Dependency | Commit | Upstream / license | Source decision and necessary patches |
|---|---|---|---|
| `flutter_qjs` | `f5a1f20d08c33b0a6b3e38eda2a7b27705420620` | `ekibun/flutter_qjs` / MIT | Existing necessary fork retains Map/TypedData/dispatch/port contracts and backports applicable d07 core safety fixes. Official 0.4.0 fails current resolution and the Map probe |
| `flutter_inappwebview` | `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676` | `pichillilorenzo/flutter_inappwebview` / Apache-2.0 | Six packages directly use official source; stable 6.1.5 lacks the browser-exit event. Windows instance ownership alone remains a local platform override |

The table summarizes current source decisions; the official-source audit and its pinned mainline audit link contain the comparisons and candidate evidence. Every Git dependency update must document the upstream repository, comparison range, all custom changes, upstream PR if any, security impact, exit conditions and rollback path.

The `desktop_webview_window` package directory already contains Apache-2.0 LICENSE; the previous repository-root lookup missed it. Its local source retains third-party notices. PNG/7z now use project-authored bridges with explicitly licensed official cores. Project-authored `venera_saf` replaces the former placeholder-license wrapper without retaining its source, preserving stored paths and system-persisted grants.

## QuickJS Numeric-Buffer Reference Walk Fix (2026-10-31)

The pin moves from `8feae95df7fb00455df129ad7a0dfec1d0e8d8e4` to `295f77421eedff356a02e92987181b525970c780` on the existing fork's `venera-next-pinned` branch. The application still uses the full immutable commit, not a floating branch.
The [complete diff](https://github.com/CyrilPeng/flutter_qjs/compare/8feae95df7fb00455df129ad7a0dfec1d0e8d8e4...295f77421eedff356a02e92987181b525970c780) contains only a `TypedData` early return in `lib/src/ffi.dart`, regression tests, and the dependency changelog. License, package version 0.3.7, native code, NDK/CMake and platform settings are unchanged. No unverified upstream PR is claimed.

Previously, `JSRef._callRecursive` copied and scanned `Uint8List` as an ordinary list even though numeric buffers cannot contain JS references. Skipping those buffers removes unnecessary Promise byte-result walks while preserving normal list/map traversal, aliases, cycles, callbacks and asynchronous completion. It does not disable processing, rewrite user scripts, or introduce zero-copy buffers.
The [reader diagnostic record](reader_diagnostics.md) preserves an isolated A/B/A comparison and its limits. Two dependency-local regressions cover buffers and cyclic graphs; application regressions cover results, cancellation, errors, workers and reference release. Host checks do not replace Android-device retesting or platform builds, and do not close #125.

This is not a QuickJS engine security upgrade and does not resolve the existing upstream-provenance debt. It adds no permissions or network capabilities. Roll back the pin in `pubspec.yaml`, `pubspec.lock`, `git_dependencies.json` and the current dependency table together, then revalidate loading/processing lifetimes; never patch the shared Pub cache as a rollback mechanism.

## Local Packages and First Migration (2026-11-06)

| Local package | Version | Application path | Immutable source baseline |
|---|---|---|---|
| `photo_view` | 0.14.0 | `packages/photo_view` | Former fork commit `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c` |
| `share_plus` | 12.0.2 | `packages/share_plus` | pub.dev 12.0.2 archive and SHA-256 |
| `rhttp` | 0.15.1 | `packages/rhttp` | pub.dev 0.15.1 archive and SHA-256 |
| `flutter_inappwebview_windows` | 0.7.0-beta.3 | `packages/flutter_inappwebview_windows` | Official commit `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676` and necessary instance ownership fix |
| `webdav_client` | 1.2.2 | `packages/webdav_client` | Former fork commit `2f669c98fb81cff1c64fee93466a1475c77e4273` |
| `desktop_webview_window` | 0.2.4 | `packages/desktop_webview_window` | Package directory at fork commit `7801fc582ecf5a7351632887891ecf309a7b2583` |
| `venera_native` | 1.0.0 | `packages/venera_native` | Application commit pins project-authored bridges; third-party cores have separate official pins |
| `venera_saf` | 1.0.0 | `packages/venera_saf` | Project commit fixes authored Dart/Kotlin/JNI and descriptor source |

The table shows current local packages. The initial scrolling package was retired on 2026-11-07; historical commits retain its source and checksums. The 2026-11-06 migration retained scrolling/WebDAV runtime sources and original BSD licenses. Current scrolling uses application adapters and official public interfaces; WebDAV retains its necessary authentication, redirect, adapter and upload patches.

Both new `UPSTREAM_MANIFEST.json` files record canonical LF Git blob SHA-256 hashes and reviewed local file hashes. The checker validates matching source provenance, local file hashes and registration of every Dart file under `lib/`. The three previously local packages retain their detailed patch/archive records and gain combined declaration, provenance, license and documentation checks.

Local declarations and relative lockfile paths must agree; package manifest names/versions must match the inventory. Resolved files must remain inside the reviewed package directory. License hashes use canonical LF bytes, and patch notes must retain the source baseline and version. Unreviewed direct dependencies, overrides and transitive local packages fail validation. The application Git commit fixes local contents; a lockfile path alone cannot ensure unchanged source.

Update patch notes, inventory and applicable local file hashes with each change, compare upstream updates and run strict analysis and affected feature regressions. Restore declarations, lockfile and Git inventory entries together when reverting to Git. Existing forks remain available for historical builds and rollback. SAF now uses the project-maintained implementation with existing grants and saved references preserved.

## Initial Local PhotoView Migration (2026-10-05)

The following preserves the initial migration scope. Later lifecycle and zoom patches are documented in the local `LOCAL_PATCHES.md`.

`photo_view` resolves through `path: packages/photo_view` to the [local package](../../packages/photo_view/pubspec.yaml), still at version **0.14.0**. Its source is the previously pinned [CyrilPeng/photo_view](https://github.com/CyrilPeng/photo_view) commit `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c`, with [renancaraujo/photo_view](https://github.com/renancaraujo/photo_view) as upstream. Original copyrights and the [MIT license](../../packages/photo_view/LICENSE) remain unchanged. VeneraNext maintainers own the local patch and future upstream comparisons.

[LOCAL_PATCHES.md](../../packages/photo_view/LOCAL_PATCHES.md) records canonical Git blob SHA-256 hashes, retained files, and validation. The patch fixes leaked `ImageInfo` clones in the dimension listener by disposing each clone in `finally` after reading its size. The painting listener continues to own its separate image. Three equivalent calls also replace deprecated SDK APIs:

- `TickerMode.of(context)` → `TickerMode.valuesOf(context).enabled`.
- `translate(dx, dy)` → `translateByDouble(dx, dy, 0.0, 1.0)`.
- `scale(s)` → `scaleByDouble(s, s, s, 1.0)`, preserving scaling on all three axes and the homogeneous coordinate.

The migration retains the existing fork's reader interfaces and behavior; it does not adopt the pub.dev release. After formatter normalization, only the three documented source files differ. Package version, manifest dependencies, all **156** other locked dependency records, and SDK locks remain unchanged. Initially `photo_view` left the then Git-only inventory; on 2026-11-06 it joined the combined inventory's `local_packages` list, retaining the detailed provenance and patch record. Resolve dependencies with `PUB_HOSTED_URL=https://pub.dev` to match the lockfile, using `flutter pub get --offline --enforce-lockfile`.

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
- [ ] Local paths, versions, upstreams, source checksums, licenses and patch notes are synchronized; applicable source manifests and local file hashes are updated.
- [ ] Release workflows use the same commit for Git-installed tools.
- [ ] `flutter pub get --enforce-lockfile`, `flutter analyze --no-pub`, and `flutter test --no-pub` have passed.
- [ ] Platform builds have passed, or unverified platforms are documented.
- [ ] Licenses, security advisories, and upstream changes have been reviewed.

## Local desktop WebView maintenance (2026-11-06)

`desktop_webview_window 0.2.4` retains the pinned desktop proxy, Linux WebKit/libsoup and Windows ARM64 implementation. Its package directory already contains Apache-2.0 LICENSE; the previous repository-root lookup missed it. The x64 1.0.992.28 and ARM64 1.0.3124.44 WebView2 loaders/import libraries match official NuGet archives byte for byte. Archive hashes, entries and SDK LICENSE/NOTICE are recorded in the local `NATIVE_ARTIFACTS.json` and `licenses/`; WIL and strconv notices are retained.

The reviewed official 0.4.2 archive requires Flutter >=3.44.0 and changes configuration/title-bar APIs without an equivalent public proxy parameter. This migration retains application Flutter 3.41.4 and package 0.2.4. Maintenance and rollback are documented in `packages/desktop_webview_window/LOCAL_PATCHES.md`. The inventory declares `source_directories` for complete native-tree review. Binary entries use `encoding: binary` and raw-byte hashes; text uses canonical LF. Unregistered files and links fail the check.

## Project-Owned PNG/7z Bridges (2026-11-06)

`packages/venera_native 1.0.0` replaces the Dart/FFI wrappers and build integration of two packages with placeholder licenses. The new wrapper is project-authored GPL-3.0-or-later code; the old wrappers were not copied or relicensed. The separate cores come from official LodePNG `79a61c79cc62814f315661f53a026004bac80614` (20241015, Zlib) and 7-Zip `e5431fa6f5505e385c6f9367260717e9c47dc2ee` (24.09, only retained C decoder files with explicit public-domain headers). That declaration does not apply to the entire 7-Zip repository. The local `SOURCE_MANIFEST.json` and `LOCAL_PATCHES.md` record source pins, original filenames, hashes and notices.

Packages with `source.type: project` still require a complete source inventory, license and maintenance record. Third-party trees have separate immutable provenance and licenses; their files cannot be relabeled as project-authored code. APK checks verify codec libraries, real exports and assets notices for each Flutter ABI. Windows/Linux check loaded exports; Apple checks framework exports, ARM64 and notices inside the built app. CI adds independent ASan/UBSan C ABI regressions and complete platform builds. Windows image/JS lifecycle tests accept `VENERA_NATIVE_TEST_DIRECTORY` to use the current Debug bundle instead of accidentally skipping when only looking for historical Release DLLs.

PNG keeps the algorithm/settings, validates RGBA/alpha and offset typed views, and returns owned Dart bytes after releasing all native allocations. One background isolate owns and closes each 7z archive while reusing its solid-block cache. All names, collisions, directory conflicts and links are preflighted, and decoding checks CRC and lengths. Password protection and unsupported compression methods fail explicitly. The application's ZIP → 7z → Dart ZIP fallback remains.

`tool/native_png_probe.py` performs old/new/old A/B/A with identical RGBA bytes and reports byte equality, timing and host-process RSS. Peak RSS is cumulative for that process, not an independent per-encode peak. This does not measure Android frames or energy use. Algorithm updates need separate upstream review, provenance/hash updates and pixel, archive, memory-safety and platform regressions. Historical forks remain for old builds; the frozen `1.18.3+244` Harmony source and assets are unchanged.

## Project-maintained Android SAF (2026-11-06)

`packages/venera_saf 1.0.0` replaces the placeholder-license wrapper with project-authored GPL-3.0-or-later source. Its complete `SOURCE_MANIFEST.json` inventories the license, source, platform build and maintenance notes; none of the old wrapper's source is copied. The inventory now has **two Git origins, eight Git packages and eight local packages**. All **155** other locked records and SDK pins remain unchanged.

Stored `android://<treeDocumentId>/<display names>` paths and Android's persisted URI grants remain authoritative. The longest complete known tree ID handles IDs containing `/`; a revoked longer grant fails instead of redirecting through a shorter overlapping root. Authority ambiguity, unavailable providers, missing children and denied access have distinct failures. UTF-8 JSON preserves Chinese, emoji, colons and pipes.

The original ParcelFileDescriptor remains alive until final close. Native 64-bit IO/seek/length/truncate/flush do not copy file bytes through JNI. Cross-isolate open uses retain/ack/sender-release/adopted so the worker releases its lease before returning a file. Generation tokens prevent closing reused OS descriptor numbers. Workers initialize idempotently, preserve error stacks and drain on disposal. Streams cancel with cleanup; the PDF worker closes failed output and its SAF worker before completion. Explicit close propagates provider errors; cleanup preserves primary IO failures.

Existing file creation preserves bytes. Same-parent rename checks observed targets, and authorized roots cannot be removed or renamed. Atomic exclusive creation/createTemp, watching, locks and setting timestamps are explicitly unsupported; provider races and external cloud restrictions still need vendor/device validation.

Validation includes host adapters/workers, 200 C++ ownership/error/FD-reuse cycles and >2 GiB sparse-file checks. CI runs ASan/UBSan, complete Android/TV builds, 13 native/JNI export checks and packaged-notice checks. Two isolated APKs in `tool/saf_provider_probe` test real DocumentsProvider grants, restart, Unicode, modes, cancellation, close callbacks and errors with a minified Release consumer. See `packages/venera_saf/LOCAL_PATCHES.md` for exact semantics and maintenance.
