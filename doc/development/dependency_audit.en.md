# Git dependency ownership and replacement audit (2026-09-28)

[简体中文](dependency_audit.zh.md) · [Rules](dependencies.en.md) · [Inventory](git_dependencies.json)

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
| desktop_webview_window | pub.dev 0.3.0; source points to MixinNetwork/flutter-plugins | Official archive includes Apache-2.0, but this does not automatically establish licensing of current custom code. Official CreateConfiguration lacks the proxy option used by the app. Fork includes libsoup-3.0, Linux and Windows ARM64 changes. Keep pinned origin pending provenance review or a validated replacement. |
| flutter_saf | fork of pkuislm/flutter_saf; pub.dev namesake 0.1.0 belongs to hamiranisahil/flutter_saf | Current LICENSE is a placeholder. The MIT-licensed namesake is a different implementation without the required IOOverrides mechanism. Retain origin; replacement requires persistent directory grants, isolate IO overrides, random access and background read/write tests. |
| flutter_7zip | fork of wgh136/flutter_7zip; pub.dev namesake returns 404 | Placeholder LICENSE. SZArchive.extractIsolates handles 7Z/CB7 and ZIP fallback. Having archive installed does not justify removal. Clarify wrapper and embedded native licensing or validate an equivalent 7Z implementation. |
| lodepng_flutter | Venera native plugin; pub.dev namesake returns 404 | Placeholder LICENSE. Application uses native pointers and a finalizer. Retain origin pending licensing or replacement; evaluate dimensions, transparency, pixel fidelity, peak memory and encoding time. |
| flutter_to_debian | pub.dev 2.0.2; jeffrey0606/flutter_to_debian, MIT | Fork adds the Depends propagation fix 3777c91 after upstream HEAD 7bf3b03df4e0f9f38f29dab6b5b66e587074262d. Published archive also lacks propagation. Replaced with project-owned packaging code. |

## Ownership and future updates

VeneraNext maintainers own patch selection, upstream review, and release validation. Preserve both original upstream provenance and Venera customization history. Each upgrade records comparison baselines, the full change range, retained/upstreamed/removable patches, licenses/advisories, functional validation and rollback commits. Do not automatically merge upstream default branches into release dependencies.

Do not republish the four license-review entries or apply this project's GPL or a namesake's license to their custom code. Continuing those replacements requires licensing evidence covering wrappers and embedded native code, or a functionally validated alternative. No external maintainer messages were sent. These outstanding items do not prevent the completed five-fork migration and Debian replacement.

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
