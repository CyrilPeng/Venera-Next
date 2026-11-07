# Complete Diff Audit of Remaining Git Dependencies (2026-11-06)

[中文](remaining_git_audit_20261106.zh.md) · [Complete inventories and evidence hashes](remaining_git_audit_20261106.json) · [Governance](dependencies.en.md)

The application retains **two Git origins, eight Git packages and eight local packages**. This audit changes no dependency SHA, SDK or application version. It inventories the full Git changes, separates actual customization from later upstream development, and tests current application contracts. Historical forks remain available for old builds and rollback.

Retain both existing API forks for now. The unpublished official QuickJS candidate fails application resolution and loses JavaScript Map entries in a native probe. Stable InAppWebView lacks a required browser-exit event, while official Git master has not adopted the Windows GraphicsContext ownership fix. The old embedded QuickJS core also contains security-advisory code patterns requiring priority remediation. Keeping the wrapper contract does not resolve those findings. The next HarmonyOS pin is preview-only: `release_enabled: false` prevents tag distribution until separate core remediation and platform review.

## Baselines and scope

Use full SHAs, common ancestors and canonical Git blobs. A later tag with the same version is not the fork's parent. JSON records every changed path, additions/deletions and before/after Git blob IDs, including native cores, platform code, generated files, examples and tools. Counts use `--no-renames`; QuickJS's candidate therefore has 161 paths, compared with 159 files when Git recognizes renames.

| Comparison | From → to | Changed paths | Interpretation |
|---|---|---:|---|
| QuickJS customization | `32aac42…` → `295f774…` | 84 | Includes the embedded core, platform files and generated metadata; not 84 application patches. |
| QuickJS official candidate | `295f774…` → `12a393b…` | 161 | Changes native assets, core and wrapper together. |
| InAppWebView customization | `0aaf7a0…` → `3ef899b…` | 2 | Only the Windows manager: five added and two deleted lines. |
| InAppWebView official candidate | `3ef899b…` → `17527ca…` | 1845 | Upstream APIs, generated files, Linux implementation and platform development, not personal customization. |

Complete inventories and impact review are distinct from device behavior, exploit testing and platform equivalence. Those acceptance limits are explicit below.

## QuickJS wrapper and core

The current fork is [CyrilPeng/flutter_qjs@295f774…](https://github.com/CyrilPeng/flutter_qjs/tree/295f77421eedff356a02e92987181b525970c780), with `ekibun/flutter_qjs` as wrapper upstream and `32aac42c194bd9631fb44e0582e6fde1778807d0` as common baseline.

Pub.dev still reports **0.3.7**, requiring Dart `>=2.12.0-0 <3.0.0`. Official Git has an unpublished **0.4.0**, committed on 2026-10-19 as `12a393bd22529753935705b2a8f5db636e93d37f`. It requires Dart `^3.10.0`, `hooks ^2.2.0`, `code_assets ^2.0.0` and `native_toolchain_cmake ^0.3.2`. The claim that upstream universally lacks Dart 3 support is obsolete.

Of 19 embedded core files, 18 source/header files exactly match QuickJS-NG `d07f6b5232dd92ba712fe729bd018aae3a1b328f`, the 2025-01-18 `v0.8.0-31-gd07f6b5` snapshot. Only `VERSION` differs, retaining `2024-02-14`; that label does not identify the actual core. Official 0.4.0 uses submodule `081d50c2792c16763f0e4a62ee4fdfb902b15a67`, whose headers identify **0.17.0**. JSON preserves the individual matches.

| Layer/platform | Current contract | Candidate change and disposition |
|---|---|---|
| Dart/FFI | Dart 3 FFI types, integer/NaN conversion, JS Map entries, `JSInvokable.call`, TypedData reference-walk shortcut. | Regenerated native bindings retain tested numeric values, but remove Map conversion and the TypedData shortcut. Keep these contracts. |
| Engine/isolate | The application calls public `dispatch()`, `port` and `JSInvokable.call`, coordinating shutdown, callbacks and Promise draining. | Candidate internalizes the loop and port and removes those public interfaces. Actual lifecycle adaptation is required. |
| Android | NDK 28, AGP/namespace/CMake updates, build-id handling and current library name. | Native assets replace the traditional plugin; CMake adds 16 KiB page alignment. Validate real APKs, every ABI, exports and lifecycle. |
| iOS/macOS | Framework loading, CocoaPods entry points and native sources/copyrights. | Pods and plugin directories are removed in favor of hooks. Application linking, loading and teardown remain unverified. |
| Windows/Linux | Existing plugin/CMake and library names; current application CI and host-loading contract. | New `flutter_qjs` code asset. A pure Dart Windows build ran, but Flutter application integration failed resolution. |

An isolated application candidate changes only QuickJS and keeps the real application `lib/` sources. Resolution fails because Flutter pins `meta 1.17.0`, while `hooks 2.2.0` requires `record_use 1.0.0`, requiring `meta ^1.19.0`. No SDK or dependency override bypasses the gate.

After moving generated output to a shorter path to resolve MSBuild's path-length failure, a pure Dart Windows probe built the actual 0.17.0 core. Numeric boundaries, NaN and infinities passed, as did 30 cycles of Promise, Dart callback, copied ArrayBuffer and engine teardown. `new Map([["中文",7],["second",9]])` returned `{}`, failing the contract. Candidate negative zero retains its sign; the current fork returns zero. This is recorded behavior, not a fabricated regression from the initial overly strict int-type assertion. The current fork passes **29** corresponding contract and existing application lifecycle tests, explicitly starting dispatch and closing its port.

Wrapper MIT licensing and embedded-core copyrights remain. JSON records license hashes and core provenance. Native assets are an upgrade candidate, not evidence that every platform patch can already be removed.

## Core security findings

The published QuickJS-NG repository advisory query returned **10 GHSAs**. Compare their actual code patterns rather than trusting broad version ranges alone. No command-execution or host-secret extraction exploit was run. JSON contains exact source functions, report ranges, query hashes and the limits of each assessment.

| Advisory | Current source assessment | Required work |
|---|---|---|
| [GHSA-m53g-qx47-3h38](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-m53g-qx47-3h38) | Four array copy constructors publish uninitialized slots before getter reentry. | Prioritize initialization/GC ownership fixes and controlled native getter/GC sanitizer regression. |
| [GHSA-r6vf-p8wr-4vg9](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-r6vf-p8wr-4vg9) | Corrected 2026-11-07: the d07 core uses generic `JS_SetPropertyInt64`, without the later optimized push path. The previous missing-condition assessment does not apply. | Do not backport the unrelated `d98ff101` condition; retain shrink/grow, holes, push and GC regression. |
| [GHSA-v647-xff9-jxf7](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-v647-xff9-jxf7) | Failed CallSite insertion double-frees the transferred value and retains transferred cleanup fields. | Review `c846cb1364272de07bcc42e5a385ccdadf6b8409` and OOM ownership. |
| [GHSA-crgj-9jv8-xfhq](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-crgj-9jv8-xfhq) | Reject-function OOM frees the resolve function without clearing the caller's slot. | Review `776d724cfa46a3b5bb045012ef4c838eae71ebaf`, including async function/generator cleanup. |
| [GHSA-wm7w-r6qf-3c9w](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-wm7w-r6qf-3c9w) | Invalidated-buffer error paths fail to release the converted Atomics.store value. | Repair error ownership and validate detach, conversion and retries. |
| [GHSA-9wv5-5cgr-grj6](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-9wv5-5cgr-grj6) | Sort index allocation lacks checked length multiplication; Android ARM32 is supported. | Review `e93cca611908e12b824ec85fbee6b31a5ee61568` and real 32-bit boundaries. |
| [GHSA-jp52-chwg-2p9p](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-jp52-chwg-2p9p) | Older Proxy code allocates `sizeof(tab[0]) * len`; the advisory's extra_len implementation differs. | Review related 32-bit size overflow without claiming reproduction of the advisory's exact exploit. |
| [GHSA-52gx-967m-hxp3](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-52gx-967m-hxp3) | Core transfer may realloc foreign ArrayBuffer storage. The current Dart bridge uses `JS_NewArrayBufferCopy`. | Retain copying and reject or safely copy external storage in the core. Other Rust-binding exploit results do not establish exposure through this Dart API. |
| [GHSA-3jf7-4qfx-xc2h](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-3jf7-4qfx-xc2h) | The matched early core has no reported rope-string implementation. | Check the fixed route during core migration; do not mechanically apply `<0.16.0`. |
| [GHSA-rxpx-wj25-jhqq](https://github.com/quickjs-ng/quickjs/security/advisories/GHSA-rxpx-wj25-jhqq) | Reported lower bound is 0.15.1; this earlier RegExp compiler needs its own allocation-error review. | Do not claim current exposure or completed remediation without that review. |

Current upstream SECURITY.md no longer accepts private security reports or issues CVEs, and excludes hostile bytecode. That neither retracts published GHSAs nor resolves JavaScript-source-triggered memory errors. The wrapper and InAppWebView repository queries returned zero advisories; installed WebView2/WebKit and other dependencies remain separate sources of security updates.

Preserve Map, TypedData and application lifecycle contracts while independently reviewing official core fix backports or an upgrade. Record source and patch hashes; run native ASan/UBSan, OOM/GC, 32-bit boundaries and every supported platform's actual build. Resync HarmonyOS to the reviewed source/common baseline before enabling distribution. Ordinary regression and HAP preview success only establish their declared behavior.

## InAppWebView

Current fork: `3ef899b3db57c911b080979f1392253b835f98ab`; closest common baseline: `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676`. The later `v6.2.0-beta.3` tag, `5e4b6a4cd88870a45c8e2396bb43ce94a50e7317`, is not the customization baseline. Official master is reviewed through `17527cae5a3371c1e87f9c1df4281a7710debf28` (2026-02-10); Pub stable remains 6.1.5.

All personal changes are confined to Windows `in_app_webview_manager.h/.cpp`: `graphics_context_` becomes an instance member instead of an inline static unique_ptr, is initialized to nullptr, and is reset after clearing the three webview collections. Official master still retains the static context. This fix does not imply complete ownership refactoring of every static Windows/COM resource.

| Package scope | All changed paths from fork to official master | Impact |
|---|---:|---|
| Facade | 327 | Facade/environment APIs, examples and generated application files. |
| Android | 43 | Dart/native implementation and build. |
| iOS | 315 | Dart/Swift, packaging, capabilities and examples. |
| macOS | 288 | Dart/Swift, packaging and capability alignment. |
| Windows | 93 | WebView2, environment/messages/printing and build; retain the context fix. |
| Web | 22 | JS bridge, controller, storage and platform support. |
| Platform interface | 494 | API/types and generated code; a shared beta version does not imply identical content. |
| New Linux package | 220 | Review registration/dependencies alongside the application's existing desktop WebView. |

The remaining 43 paths cover repository tooling, test services and metadata. JSON records the full set and root/package Apache-2.0 license hashes for all seven current packages. System WebView runtime updates remain separate.

The isolated real application fails strict analysis with stable 6.1.5 because `windows_webview_environment.dart` needs `onBrowserProcessExited`. Official master passes strict application analysis, but has not completed Windows multiview shutdown/recreation, actual proxy switching, cookies/login/Cloudflare or other platforms' native acceptance. No event is removed and no API is downgraded to bypass analysis.

For a replacement, start from a reviewed official SHA, retain/upstream or implement equivalent context ownership, coordinate all platform packages/interfaces and validate native multiview shutdown/proxy changes. Remove the personal fork only after these checks; creating new platform forks is unnecessary. No external maintainer messages or upstream PRs were sent.

## Evidence and rollback

The evidence directory contains both QuickJS contract sources as `.dart.txt` files and sanitized resolution/runtime/analysis logs; copy sources into isolated test projects when reproducing. JSON records SHA-256 hashes and the full Git comparison commands. Initial path-length failures and unverified platform behavior are not counted as successful upgrades.

The next HarmonyOS candidate retains the existing platform variant in `packages/rhttp/lib/src/rhttp.dart`: `Rhttp.init()` accepts an optional `ExternalLibrary?` and forwards it to `RustLib.init` for explicitly loading `librhttp.so`; Rust sources match main. This is not a new patch in this round, and the eight local packages are not claimed to be byte-identical to main. Candidate package digests use the actual files at its pinned Git commit, which the main release verifier independently checks.

No dependency pin changes occur in this audit. A future core/source change must update pubspec, complete lockfile, inventory, audit and HarmonyOS overlays together. Rollback restores that whole set and preserves the frozen `1.18.3+244` source, lock and historical Release assets.
