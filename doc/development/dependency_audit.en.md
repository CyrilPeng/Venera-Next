# Current Dependency Sources and Replacement Conditions

[中文](dependency_audit.zh.md) · [Governance](dependencies.en.md) · [Machine inventory](git_dependencies.json)

The current graph has two Git repositories, seven Git packages and eight local packages. Exact versions, commits, archive hashes, licenses, patches and exit conditions live in `git_dependencies.json`, `pubspec.lock` and package manifests. Completed comparisons and raw evidence remain in the [v1.18.4-rc.3 historical documentation](https://github.com/CyrilPeng/Venera-Next/tree/v1.18.4-rc.3/doc/development).

## Current Exceptions and Exit Conditions

| Dependency | Reason for retaining it | Condition for adopting official sources |
| --- | --- | --- |
| QuickJS | Pin `CyrilPeng/flutter_qjs@f5a1f20d08c33b0a6b3e38eda2a7b27705420620` preserves Map/TypedData, integer/NaN, Promise, dispatch/port and reference ownership. Official unpublished 0.4.0 fails actual resolution and the native Map probe | SDK resolution, Map/TypedData, Promise/cancellation, ownership, secure core and platform acceptance all pass |
| InAppWebView | Six packages share official `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676`; stable 6.1.5 lacks browser-exit events. Only Windows instance ownership remains local | Stable exit API and upstream Windows fixes pass coordinated platform validation |
| PhotoView | Local 0.14.0 retains scale/reset APIs, gestures and ImageInfo ownership. Official 0.15.0 causes 15 application API errors and still needs ownership fixes | Public application adapters and upstream fixes pass zoom, touchpad, double-page, automatic reading and exit tests |
| SharePlus | Local 12.0.2 retains native payload, file retention and callback ownership fixes | Application, Android primitives, Windows COM and other platform sharing/cancellation pass |
| Desktop WebView | Local 0.2.4 retains proxy, Linux/ARM64 and process-exit contracts; official 0.4.2 requires Flutter >=3.44 and changes required configuration APIs | SDK/API adaptation, cookies, proxies, exit/recreation and platform checks pass |
| Rhttp | Local 0.15.1 retains cancellation, actual native drain, timeouts and connection ownership; lockfile and patch records constrain Rust security updates | Upstream covers application contracts and all retained security fixes; streaming/native platform checks pass |
| WebDAV Client | Local 1.2.2 retains the HTTP adapter, authentication, redirects and upload behavior | Official or application adapters pass authentication, 301, directories, large uploads and cleanup |
| Venera Native | Project-owned PNG/7z wrappers use separately recorded, clearly licensed official LodePNG and 7z C sources | Review core upgrades independently; old namesake wrappers are not equivalent replacements |
| Venera SAF | Project-owned persistent URI, random-access and cross-isolate handle bridge; old placeholder-license wrappers were not copied | Maintain real Provider, original PFD and restart/grant contracts |

Scrollable Positioned List now uses official pub.dev 0.3.8 with application adapters. `debian/build.py` and system `dpkg-deb` replace Flutter to Debian. Old SAF, 7zip and LodePNG wrappers remain only in historical builds.

## Security and Provenance

The retained QuickJS core matches QuickJS-NG `d07f6b5`. Applicable advisories, patch scope and regressions are recorded in pinned [CORE_PATCHES.json](https://github.com/CyrilPeng/flutter_qjs/blob/f5a1f20d08c33b0a6b3e38eda2a7b27705420620/CORE_PATCHES.json). Wrapper compatibility does not replace native safety fixes. Candidates must retain GC, allocation-failure, buffer-transfer, Linux 64/32-bit ASan/UBSan and Windows 64/32-bit ASan coverage.

Local `LOCAL_PATCHES.md`, `UPSTREAM_MANIFEST.json`/`SOURCE_MANIFEST.json`, licenses and notices remain maintained inputs. PNG uses official LodePNG 20241015; 7z uses the public-domain C decoding subset of 24.09. Match XZ, other handler and C++ extraction advisories to the actual compiled subset. Reject links, missing names, escaping paths and corrupt input, retaining ABI and sanitizer tests.

Source checks verify declarations, locks, actual Git HEAD, package subdirectories and clean source. Failed Windows long-path checkouts can leave a cache whose name differs from its actual HEAD. Recheck in an independent longpaths-enabled cache and preserve the original shared cache for diagnosis.

## Stable Candidates Not Yet Adopted

These are verified historical compatibility limits; reevaluate candidates with the pinned SDK on each update.

| Candidate | Verified limit | Current choice |
| --- | --- | --- |
| `dynamic_color 1.9.0` | Published Android Gradle Kotlin script omits the Kotlin Android plugin and fails Android/TV compilation | Exact official 1.8.1 |
| `flutter_reorderable_grid_view 5.10.0` | Adaptive-grid mouse/touch drag produces negative BoxConstraints | Tested 5.7.0 |
| `pdfrx 2.4.8` | Its engine requires meta ^1.18 while this Flutter pins meta 1.17 | Keep the resolvable version specified by the root lock |

## Updates, Validation and Recovery

Compare official stable archives, full official commits and retained custom sources. Separate equivalent SDK calls, application adapters and necessary patches. Formatter-normalized equality does not prove behavior, native safety or platform equivalence.

Update declarations, locks, inventory, provenance/patch hashes and CHANGELOG together. Run `dart tool/check_git_dependencies.dart`, strict analysis, affected regressions, native ABI/sanitizers and platform builds. Restore the same input group and adapters on rollback, preserving independent security fixes. See [HarmonyOS releases](harmonyos_releases.en.md) for the separate toolchain and frozen sources.
