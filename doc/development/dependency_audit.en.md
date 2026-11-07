# Git dependency ownership and replacement audit (2026-09-28)

[简体中文](dependency_audit.zh.md) · [Rules](dependencies.en.md) · [Inventory](git_dependencies.json)

The latest [2026-11-07 implementation record](official_dependency_implementation_20261107.zh.md) has two Git origins, seven Git packages and eight local packages. Only the necessary QuickJS patch remains at a personal Git origin. The dated decisions below remain historical evidence.

The baseline is the pre-migration lockfile. The inventory records exact current Git URLs, commits, and package paths. Local path packages are documented in subsequent updates and the [governance rules](dependencies.en.md). Evidence includes pinned local source and Git history, GitHub repository metadata, and the latest stable pub.dev archives available on the review date. The original 2026-09-28 decisions remain below as a historical record of confirmed incompatibilities, not a complete security audit or proof of behavioral equivalence.

## Completed changes

- Removed six original-app IPAs and related news from AltStore; the updater accepts this project's release URLs. Preserve attribution, copyrights, legacy data migration, and extension protocols.
- Reused five existing CyrilPeng forks at unchanged commits, including all six platform subpackages of flutter_inappwebview. Other application dependency versions did not change.
- Replaced flutter_to_debian with debian/build.py and system dpkg-deb, also removing its unused mime_type dependency. CI no longer globally installs a Git packaging tool. ARM64 DEBs upload from their own architecture directory.
- CI runs `dart tool/check_git_dependencies.dart` after locked resolution. It validates direct and transitive Git packages, full commits, resolved-ref, URLs, and paths against the reviewed inventory. The four license-review entries are explicit exceptions, not resolved licensing issues.

## Decisions by dependency

| Dependency | Candidate / provenance | Evidence and decision |
|---|---|---|
| flutter_qjs | pub.dev 0.3.7; source identifies ekibun/flutter_qjs, MIT | Current history includes migration to QuickJS-NG (67496e2), Apple builds, integer and NaN conversion fixes. Retain owned fork. Replacement needs Promise, exception, numeric, typed-array, object lifetime and five-platform native validation. |
| photo_view | pub.dev 0.15.0; renancaraujo/photo_view, MIT | Published package lacks getInitialScale used by the application; fork history also adds resetWithNewBoxFit. Fork history also changes GIFs, disposal, trackpad handling and animation. Retain fork; validate zoom, long press, trackpad, double pages, auto-reading and image lifecycle before replacing. |
| scrollable_positioned_list | pub.dev 0.3.8; google/flutter.widgets, BSD-3-Clause | Published package lacks scrollControllerCallback and scrollBehavior added by 09e756b. Retain fork; replacement requires reader navigation, long-chapter jumping, auto-reading and touch recovery changes/tests. |
| flutter_inappwebview | stable pub.dev 6.1.5; pichillilorenzo/flutter_inappwebview, Apache-2.0 | Current fork uses a customized 6.2.0-beta.3 with GraphicsContext disposal fixes. Switching stable versions changes the API baseline and multiple platform implementations. Retain whole repository; compare each platform and verify login, cookies, proxies, Cloudflare and disposal/recreation. |
| webdav_client | pub.dev 1.2.2; original upstream flymzero/webdav_client, BSD-3-Clause | Published newClient accepts user/password/debug, not the adapter supplied by this app. Fork also modifies redirects, uploads and authentication. Retain fork; verify RHttpAdapter, authentication, redirects, directories and large uploads before replacing. |
| desktop_webview_window | Initial candidate pub.dev 0.3.0; reviewed 0.4.2 on 2026-11-06 | Corrected the earlier repository-root lookup: the pinned package already has Apache-2.0 LICENSE. Version 0.4.2 requires Flutter >=3.44 and changes configuration APIs without an equivalent public proxy argument. Current 0.2.4 is local, retaining Linux/ARM64 behavior and recording SDK loaders and third-party notices. |
| flutter_saf | fork of pkuislm/flutter_saf; pub.dev namesake 0.1.0 belongs to hamiranisahil/flutter_saf | Current LICENSE is a placeholder. The MIT-licensed namesake is a different implementation without the required IOOverrides mechanism. Retain origin; replacement requires persistent directory grants, isolate IO overrides, random access and background read/write tests. |
| flutter_7zip | fork of wgh136/flutter_7zip; pub.dev namesake returns 404 | Placeholder LICENSE. SZArchive.extractIsolates handles 7Z/CB7 and ZIP fallback. Having archive installed does not justify removal. Clarify wrapper and embedded native licensing or validate an equivalent 7Z implementation. |
| lodepng_flutter | Venera native plugin; pub.dev namesake returns 404 | Placeholder LICENSE. Application uses native pointers and a finalizer. Retain origin pending licensing or replacement; evaluate dimensions, transparency, pixel fidelity, peak memory and encoding time. |
| flutter_to_debian | pub.dev 2.0.2; jeffrey0606/flutter_to_debian, MIT | Fork adds the Depends propagation fix 3777c91 after upstream HEAD 7bf3b03df4e0f9f38f29dab6b5b66e587074262d. Published archive also lacks propagation. Replaced with project-owned packaging code. |

## Ownership and future updates

VeneraNext maintainers own patch selection, upstream review, and release validation. Preserve both original upstream provenance and Venera customization history. Each upgrade records comparison baselines, the full change range, retained/upstreamed/removable patches, licenses/advisories, functional validation and rollback commits. Do not automatically merge upstream default branches into release dependencies.

The initial audit listed four license-review entries. On 2026-11-06 the pinned desktop WebView package's Apache-2.0 LICENSE was confirmed, correcting the repository-root lookup. For the three placeholder-license packages, distinguish wrapper and embedded-code licensing or validate replacements. Do not apply this project's or a namesake's license to third-party code; no external maintainer messages were sent.

Rollback source migration by restoring pubspec, lockfile and inventory together. Debian rollback also restores the build script and CI installation steps. A pinned SHA controls content drift, not remote availability. Keep pins reachable through retained refs and repository backups; same-platform forks do not solve GitHub-wide connectivity problems.

## Validation

- GitHub API confirmed that each of the five fork default branches points to its pinned commit; locked resolution succeeded and all seven WebView package URLs agree.
- Local Flutter 3.41.6 / Dart 3.11.4: 566 application tests passed; analysis passed with 24 existing info diagnostics; Windows x64 Release built. CI still uses the declared Flutter 3.41.4, which is a separate environment.
- Android: local JBR 21 crashed natively in a GC thread. Using the existing Oracle JDK 17 for this validation process, two Gradle workers and the local proxy, `assembleDebug -Ptarget-platform=android-arm64` passed (788 tasks). Project JDK settings were unchanged; device runtime testing was not performed.
- Linux container: real dpkg-deb creation/extraction passed for amd64 and arm64, checking Depends, ELF architecture, desktop entries and installation path. Minimal bundle fixtures do not establish Linux application runtime compatibility.
- Local Python suite: 35 passed and one Linux-only dpkg-deb case skipped on Windows, separately passed in the container. Inventory tests cover floating branches, origin changes, platform omissions and new dependencies.
- Complete macOS, iOS and Linux application builds remain for their platform release jobs.

## Subsequent Update: Local PhotoView Patch (2026-10-05)

The earlier `photo_view` decision remains as historical evidence. Its current source is `path: packages/photo_view`, still at **0.14.0**, copied from the previously pinned [CyrilPeng/photo_view](https://github.com/CyrilPeng/photo_view) commit `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c`, with [renancaraujo/photo_view](https://github.com/renancaraujo/photo_view) as upstream. The [MIT license](../../packages/photo_view/LICENSE), copyrights, package manifest, and fork interfaces are retained. This does not adopt the previously reviewed pub.dev 0.15.0 release.

The new patch fixes discarded `ImageInfo` clones in the dimension listener and replaces three deprecated calls with equivalent `TickerMode.valuesOf(context).enabled`, `translateByDouble(dx, dy, 0.0, 1.0)`, and `scaleByDouble(s, s, s, 1.0)` calls. The latter preserves the scalar branch semantics of locked vector_math 2.2.0. Only three of the 16 Dart source files differ after formatter normalization. [LOCAL_PATCHES.md](../../packages/photo_view/LOCAL_PATCHES.md) records canonical LF Git blob SHA-256 hashes, changes, ownership, and rollback requirements. All **156** other complete dependency records and SDK locks remain unchanged.

Validation: two real PhotoView ownership regressions, for cached and asynchronous images, failed on the original source and pass with the patch. They cover replacement, unmount, sizing, and zoom. Strict analysis of the package and regression tests, formatting, source comparison, and `dart tool/check_git_dependencies.dart` pass. New real-reader exit integration regressions also cover visible-image file reads, pending native frames, forced unmount, and recovery of PhotoView/continuous images after exit failure. This update's focused validation does not establish additional complete platform builds beyond the historical record.

`photo_view` has left the inventory of active Git dependencies; its local patch document now preserves provenance. `.github/workflows/pr_build.yml` already includes `packages/`, so no build-trigger rule change is needed. Restoring the Git source requires restoring dependency declarations, lockfile, and inventory together and validating image lifetimes.

## Follow-up: First Git-to-Local Source Migration (2026-11-06)

The earlier fork-retention decisions remain historical audit evidence. `scrollable_positioned_list` 0.3.8+1 now resides in `packages/scrollable_positioned_list`, copied from the same-named directory at `CyrilPeng/flutter.widgets` commit `09e756b1f1b04e6298318d99ec20a787fb360f59`. `webdav_client` 1.2.2 now resides in `packages/webdav_client`, copied from `CyrilPeng/webdav_client` commit `2f669c98fb81cff1c64fee93466a1475c77e4273`. Both original BSD-3-Clause licenses, copyrights, runtime sources and customized APIs are retained, with unchanged versions and dependency constraints.

Each package gains `LOCAL_PATCHES.md` and `UPSTREAM_MANIFEST.json` covering original Git blob hashes, reviewed local hashes, retained files, current-SDK equivalents and rollback. After identical formatting, 9/12 scrolling runtime files and 8/11 WebDAV runtime files match their origins; each remaining group of three has documented compatibility changes. Package analysis policies are retained and application strict analysis gates remain enabled.

The inventory now covers six Git origins and five local packages. Existing PhotoView, SharePlus and Rhttp source commits/archive checksums and patch notes join the checks. The checker rejects unreviewed local direct dependencies, overrides and transitive packages, path/version drift, missing licenses or patch notes, resolved files outside reviewed directories, and unrecorded source changes in the two new local packages.

Historical forks remain available for old builds and rollback; no remote repository is archived or deleted. QuickJS, WebView and the four license-review origins retain their existing pins. Frozen candidate sources, native bridge versions and release assets are unchanged. See [dependencies.en.md](dependencies.en.md) for current governance and local maintenance rules.

## Follow-up: PNG/7z Wrapper Replacement (2026-11-06)

The two placeholder-license wrapper decisions in the historical table are now superseded. `lodepng_flutter` and `flutter_7zip` are no longer current dependencies. Project-authored `packages/venera_native 1.0.0` maintains the Dart API, C ABI and build integration under GPL-3.0-or-later without copying or relicensing the old wrappers. At the PNG/7z stage, the inventory had **three Git origins, nine Git packages and seven local packages**. All **155** other complete locked records and SDK locks remain unchanged.

- LodePNG: official `lvandeve/lodepng@79a61c79cc62814f315661f53a026004bac80614`, version 20241015, Zlib. The original `.cpp` is renamed to `.c` for C compilation with its full notice. The former plugin only appended `freePtr` and added header export annotations; the replacement exports its own ABI.
- 7z: official `ip7z/7zip@e5431fa6f5505e385c6f9367260717e9c47dc2ee`, version 24.09. All 34 retained runtime C/header files match; official `7zVersion.h` adds the declaration. Only the expressly public-domain C decoder subset is retained, not the whole 7-Zip repository or former Dart/build wrappers.
- New bridges: PNG returns owned bytes before releasing native allocations. Every partial 7z open is closed, one worker reuses solid blocks, Windows paths use UTF-8 → UTF-16, and all output paths are preflighted. CRC/length failures and missing name metadata fail safely. The existing ZIP/7z/Dart ZIP fallback remains.

The official [7-Zip history](https://www.7-zip.org/history.txt) was reviewed through 26.05, compared at fixed commit `b88c6bc09339de32f7d18bbab900686b244f42ba`. Notices affecting XZ, other archive handlers and C++ link extraction cannot be applied indiscriminately to the compiled C decoder subset: those implementations are absent, and the new bridge rejects link entries. `Lzma2Dec.c/.h` are unchanged at 26.05 and the `LzmaDec.c` diff uses equivalent temporary expressions. `7zArcIn.c` also adds header-count, duplicate-property and boundary hardening. This migration preserves algorithm versions and adds a bridge guard plus an independent missing-name regression. A subsequent core update must separately examine those header paths; this review is not a complete security audit of every input.

The local manifest inventories 115 files and distinguishes project code, two separate upstreams and binary fixtures. CI validates exports, ABIs and packaged notices across supported platforms and runs ASan/UBSan C ABI checks, real RGBA/alpha/typed-view tests, solid/non-solid/Unicode/empty-file archives, malformed/unsafe paths, links and failure/retry regressions. The host PNG old/new/old A/B/A results and limitations are recorded in local maintenance notes. Frozen Harmony `1.18.3+244` sources/assets remain unchanged; the next candidate is synchronized separately.

## Follow-up: SAF Wrapper Replacement (2026-11-06)

The historical `flutter_saf` retention decision is superseded by project-authored `packages/venera_saf 1.0.0`. None of the placeholder-license wrapper's source was copied or relicensed. New Dart/Kotlin/JNI and C++ ownership code is maintained under GPL-3.0-or-later. The current inventory has **two Git origins, eight Git packages and eight local packages**, with all **155** other locked records and SDK pins unchanged. Historical forks remain available for old builds.

This review covers stored paths/persisted grants, tree IDs containing `/`, revoked grants and authority ambiguity, the original PFD's commit/close lifetime, two-stage isolate adoption, 64-bit sparse files, streaming cancellation, primary errors and PDF worker shutdown. Complete source inventory, interface limitations and validation requirements are in `packages/venera_saf/LOCAL_PATCHES.md`. `tool/saf_provider_probe` and CI repeat a real Android fixture using a minified Release consumer; external cloud limitations remain vendor/device-specific.

PNG/7z PR #148 passed Android/TV, Windows, Linux, macOS, iOS, complete Flutter tests and Linux ASan/UBSan before merging. UBSan's unaligned `CpuArch.h` accesses were fixed using the core's existing byte-wise endian helpers, retaining separate official and patched local hashes. Sanitizer and ABI gates remain enabled. Frozen Harmony `1.18.3+244` selector and assets retain their original source.

## Follow-up: Remaining Fork Audit and HarmonyOS Candidate (2026-11-06)

The [remaining Git dependency audit](remaining_git_audit_20261106.en.md) and [machine evidence](remaining_git_audit_20261106.json) contain full comparisons, 2092 changed-file records, current upstream candidates, contract probes and advisory assessments. The inventory remains two Git origins, eight Git packages and eight local packages. Official QuickJS Git now has an unpublished Dart 3-compatible 0.4.0, but actual application resolution and the native Map contract fail. InAppWebView's personal patch is confined to two Windows files; later upstream platform development is inventoried separately.

The embedded QuickJS core matches the 2025-01-18 QuickJS-NG `d07f6b5` snapshot. Ten published GHSAs were assessed and multiple remediation patterns are present; exact conditions and the current Dart buffer API limits are documented. Retaining the wrapper API does not resolve core defects. The next HarmonyOS source syncs main `55c7c44`, all eight local packages and the new native library set, using a separate >=245 preview pin with `release_enabled: false`. The 244 pin, lockfile and historical Release assets remain frozen.
