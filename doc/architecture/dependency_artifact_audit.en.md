# Direct dependency and tracked artifact usage audit

Date: 2026-10-03. Scope: 881 tracked paths at `9b06917`, read from the current working tree; untracked user files are excluded. This records P1.4/P1.5 usage evidence, not the P1.3 public-symbol/dynamic-entry reachability inventory or a security, license or cross-platform build sign-off.

## Dependency decisions

Compared every dependencies/dev_dependencies/dependency_overrides entry with tracked Dart imports/exports, then checked workflows, platform registration, configuration, assets/init.js and the JS host bridge. The table lists every package, matching-file count and its first entry. Counts describe explicit references, not dead-symbol proof. Fork compatibility and license follow-ups remain in the [existing audit](../development/dependency_audit.en.md).

| Package | Scope | Dart files | Usage evidence / decision |
|---|---|---:|---|
| `flutter` | `dependencies` | 227 | [lib/app_runtime/headless.dart:3](../../lib/app_runtime/headless.dart) — retain |
| `path_provider` | `dependencies` | 3 | [lib/features/local_comics/local.dart:15](../../lib/features/local_comics/local.dart) — retain |
| `intl` | `dependencies` | 2 | [lib/features/image_favorites/image_favorites_item.dart:3](../../lib/features/image_favorites/image_favorites_item.dart) — retain |
| `window_manager` | `dependencies` | 4 | [lib/components/window_frame.dart:11](../../lib/components/window_frame.dart) — retain |
| `sqlite3` | `dependencies` | 54 | [lib/features/favorites/favorite_row.dart:1](../../lib/features/favorites/favorite_row.dart) — retain |
| `sqlite3_flutter_libs` | `dependencies` | 0 | Retain: native SQLite libraries. Resolved 0.5.42 declares five platform plugins; local generated Windows/Linux/macOS registrations include it. Generated registrants are not tracked. |
| `flutter_qjs` | `dependencies` | 17 | [lib/components/js_ui.dart:5](../../lib/components/js_ui.dart) — retain |
| `crypto` | `dependencies` | 3 | [lib/features/history/image_favorites_provider.dart:2](../../lib/features/history/image_favorites_provider.dart) — retain |
| `dio` | `dependencies` | 13 | [lib/features/comic_source/source_repository_page.dart:3](../../lib/features/comic_source/source_repository_page.dart) — retain |
| `html` | `dependencies` | 1 | [lib/foundation/js_engine.dart:10](../../lib/foundation/js_engine.dart) — retain |
| `pointycastle` | `dependencies` | 1 | [lib/foundation/js_engine.dart:13](../../lib/foundation/js_engine.dart) — retain |
| `url_launcher` | `dependencies` | 10 | [lib/components/js_ui.dart:6](../../lib/components/js_ui.dart) — retain |
| `path` | `dependencies` | 15 | [lib/features/comic_storage/file_system_layout.dart:1](../../lib/features/comic_storage/file_system_layout.dart) — retain |
| `photo_view` | `dependencies` | 7 | [lib/features/comic_details/cover_viewer.dart:5](../../lib/features/comic_details/cover_viewer.dart) — retain |
| `mime` | `dependencies` | 1 | [lib/foundation/file_type.dart:1](../../lib/foundation/file_type.dart) — retain |
| `share_plus` | `dependencies` | 1 | [lib/foundation/file_interaction.dart:10](../../lib/foundation/file_interaction.dart) — retain |
| `scrollable_positioned_list` | `dependencies` | 2 | [lib/features/reader/continuous_view.dart:9](../../lib/features/reader/continuous_view.dart) — retain |
| `flutter_reorderable_grid_view` | `dependencies` | 4 | [lib/features/favorites/local_favorites_page.dart:6](../../lib/features/favorites/local_favorites_page.dart) — retain |
| `uuid` | `dependencies` | 6 | [lib/features/comic_source/source_repositories.dart:5](../../lib/features/comic_source/source_repositories.dart) — retain |
| `desktop_webview_window` | `dependencies` | 2 | [lib/main.dart:14](../../lib/main.dart) — retain |
| `flutter_inappwebview` | `dependencies` | 3 | [lib/features/comic_source/comic_source_page.dart:7](../../lib/features/comic_source/comic_source_page.dart) — retain |
| `app_links` | `dependencies` | 1 | [lib/routing/app_links.dart:3](../../lib/routing/app_links.dart) — retain |
| `sliver_tools` | `dependencies` | 4 | [lib/features/comic_details/comments_preview.dart:2](../../lib/features/comic_details/comments_preview.dart) — retain |
| `flutter_file_dialog` | `dependencies` | 1 | [lib/foundation/file_interaction.dart:5](../../lib/foundation/file_interaction.dart) — retain |
| `file_selector` | `dependencies` | 1 | [lib/foundation/file_interaction.dart:3](../../lib/foundation/file_interaction.dart) — retain |
| `zip_flutter` | `dependencies` | 10 | [lib/features/local_comics/archive_download_task.dart:14](../../lib/features/local_comics/archive_download_task.dart) — retain |
| `lodepng_flutter` | `dependencies` | 1 | [lib/foundation/image_processing.dart:10](../../lib/foundation/image_processing.dart) — retain |
| `rhttp` | `dependencies` | 2 | [lib/app_runtime/bootstrap_core.dart:4](../../lib/app_runtime/bootstrap_core.dart) — retain |
| `webdav_client` | `dependencies` | 4 | [lib/features/sync/comic_backup.dart:8](../../lib/features/sync/comic_backup.dart) — retain |
| `battery_plus` | `dependencies` | 1 | [lib/features/reader/status_info.dart:3](../../lib/features/reader/status_info.dart) — retain |
| `local_auth` | `dependencies` | 2 | [lib/app_shell/auth_page.dart:4](../../lib/app_shell/auth_page.dart) — retain |
| `flutter_saf` | `dependencies` | 5 | [lib/app_runtime/bootstrap_core.dart:3](../../lib/app_runtime/bootstrap_core.dart) — retain |
| `dynamic_color` | `dependencies` | 1 | [lib/main.dart:15](../../lib/main.dart) — retain |
| `shimmer_animation` | `dependencies` | 3 | [lib/features/comic_details/comic_page.dart:6](../../lib/features/comic_details/comic_page.dart) — retain |
| `flutter_memory_info` | `dependencies` | 1 | [lib/features/reader/reader_page.dart:5](../../lib/features/reader/reader_page.dart) — retain |
| `syntax_highlight` | `dependencies` | 1 | [lib/components/code.dart:3](../../lib/components/code.dart) — retain |
| `flutter_7zip` | `dependencies` | 1 | [lib/features/local_comics/import_export/cbz.dart:4](../../lib/features/local_comics/import_export/cbz.dart) — retain |
| `flex_seed_scheme` | `dependencies` | 1 | [lib/main.dart:16](../../lib/main.dart) — retain |
| `flutter_localizations` | `dependencies` | 1 | [lib/main.dart:19](../../lib/main.dart) — retain |
| `yaml` | `dependencies` | 3 | [lib/foundation/app.dart:8](../../lib/foundation/app.dart) — retain |
| `enough_convert` | `dependencies` | 3 | [lib/features/local_comics/import_export/cbz.dart:3](../../lib/features/local_comics/import_export/cbz.dart) — retain |
| `display_mode` | `dependencies` | 1 | [lib/app_runtime/init.dart:3](../../lib/app_runtime/init.dart) — retain |
| `flutter_staggered_grid_view` | `dependencies` | 1 | [lib/features/reader/chapter_comments.dart:3](../../lib/features/reader/chapter_comments.dart) — retain |
| `archive` | `dependencies` | 10 | [lib/features/local_comics/import_export/cbz.dart:2](../../lib/features/local_comics/import_export/cbz.dart) — retain |
| `image` | `dependencies` | 7 | [lib/features/local_comics/import_export/pdf_import.dart:4](../../lib/features/local_comics/import_export/pdf_import.dart) — retain |
| `pdfrx` | `dependencies` | 2 | [lib/features/local_comics/import_export/pdf_import.dart:5](../../lib/features/local_comics/import_export/pdf_import.dart) — retain |
| `xml` | `dependencies` | 1 | [lib/features/local_comics/import_export/epub_import.dart:9](../../lib/features/local_comics/import_export/epub_import.dart) — retain |
| `flutter_test` | `dev_dependencies` | 213 | [test/app_runtime/background_sync_test.dart:2](../../test/app_runtime/background_sync_test.dart) — retain |
| `flutter_lints` | `dev_dependencies` | 0 | [analysis_options.yaml](../../analysis_options.yaml): `include: package:flutter_lints/flutter.yaml` — retain |
| `flutter_to_arch` | `dev_dependencies` | 0 | Remove the dev dependency and its sole transitive dependency io. CI runs build_arch_package.py; retain the same-named top-level configuration consumed by Python. |
| `flutter_rust_bridge` | `dependency_overrides` | 0 | Retain: resolved rhttp 0.15.1 depends on ^2.11.1; the project pins 2.11.1 and validate_release.py checks it. No direct import does not mean unused. |

`html`, `pointycastle`, `crypto` and `enough_convert` are used by js_engine.dart bridges. assets/init.js calls host capabilities and need not mention Dart package names. CHANGELOG, pubspec itself and declared assets remain runtime resources. Retained packages keep their versions, sources and checksums; the lockfile only loses flutter_to_arch and io.

## Tracked artifacts and tools

Enumerated git ls-files and SHA-256 of nonempty files. Checked output/build/coverage/.dart_tool, logs, temporary/backup files, bytecode, archives and largest files; no tracked temporary outputs matched. The following lists all non-test packaging/maintenance scripts and C helpers. Tests and source are not deleted merely because of names or generated-looking data.

| Tool | Entry / decision |
|---|---|
| `.github/scripts/appimage-smoke.Dockerfile` | `.github/scripts/test_appimage.sh` |
| `.github/scripts/appimage_relocate.c` | `.github/scripts/appimage_runtime.py` |
| `.github/scripts/appimage_runtime.py` | `.github/scripts/build_linux_packages.py` |
| `.github/scripts/appimage_webkit_probe.c` | `.github/scripts/test_appimage.sh` |
| `.github/scripts/build_arch_package.py` | `.github/workflows/build.yml` |
| `.github/scripts/build_linux_packages.py` | `.github/workflows/build.yml` |
| `.github/scripts/check_architecture_dependencies.py` | `.github/workflows/analyze.yml` |
| `.github/scripts/check_issue.py` | `.github/workflows/issue_check.yml` |
| `.github/scripts/check_structure_imports.py` | `.github/workflows/analyze.yml` |
| `.github/scripts/generate_sponsors.py` | `.github/workflows/sponsors.yml` |
| `.github/scripts/generate_winget_manifest.py` | `.github/workflows/main.yml`, `.github/workflows/winget.yml` |
| `.github/scripts/prepare_rust_toolchain.py` | `.github/workflows/build.yml`, `.github/workflows/pr_build.yml` |
| `.github/scripts/release_version.py` | `.github/workflows/analyze.yml` |
| `.github/scripts/report_dart_coverage.py` | `.github/workflows/analyze.yml` |
| `.github/scripts/serialized_rustup.py` | `.github/workflows/build.yml` |
| `.github/scripts/smoke_appimage.sh` | `.github/scripts/test_appimage.sh` |
| `.github/scripts/submit_winget_manifest_pr.py` | `.github/workflows/winget.yml` |
| `.github/scripts/sync_afdian_sponsors.py` | `.github/workflows/sponsors.yml` |
| `.github/scripts/test_appimage.sh` | `.github/workflows/build.yml` |
| `.github/scripts/test_windows_startup.ps1` | `.github/workflows/build.yml`, `.github/workflows/pr_build.yml` |
| `.github/scripts/validate_release.py` | `.github/workflows/main.yml` |
| `debian/build.py` | `.github/workflows/build.yml` |
| `update_alt_store.py` | `.github/workflows/update_alt_store.yml` |
| `windows/build.py` | `.github/workflows/build.yml` |
| `windows/build_arm64.py` | Retain pending investigation: no tracked caller; directly executable ARM64 packaging entry references build_arm64.iss and is not equivalent to x64 packaging. Consolidate or establish retirement of manual usage before removal. |
| `patch/font.dart` | `.github/workflows/build.yml` |
| `tool/check_git_dependencies.dart` | `.github/workflows/analyze.yml` |

Other retained categories: fastlane screenshots/store metadata serve publishing; platform icons are consumed by resource manifests, Xcode projects or installers; tags/opencc are app assets; API docs, experiment designs and optimization logs are maintenance material. Four tracked doc/api documents match a historical .gitignore rule but are API documentation, not generated cache.

### Byte-identical file groups

The following nonempty groups share SHA-256. All are resource or project-metadata paths required by separate platforms/build modes; retain them. Identical bytes alone do not establish redundant entries. No maintenance scripts are byte-identical.

- `android/app/src/debug/AndroidManifest.xml`; `android/app/src/profile/AndroidManifest.xml`
- `assets/app_icon.png`; `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png`
- `debian/gui/venera-next.png`; `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png`
- `ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist`; `ios/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist`; `macos/Runner.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist`; `macos/Runner.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist`
- `ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings`; `ios/Runner.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings`
- `ios/Runner.xcworkspace/contents.xcworkspacedata`; `macos/Runner.xcworkspace/contents.xcworkspacedata`
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-20@2x.png`; `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-20@2x~ipad.png`; `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-40~ipad.png`
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-29.png`; `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-29~ipad.png`
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-29@2x.png`; `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-29@2x~ipad.png`
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-40@2x.png`; `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-40@2x~ipad.png`
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-40@3x.png`; `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-60@2x~car.png`; `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon@2x.png`
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon-60@3x~car.png`; `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon@3x.png`
- `ios/Runner/Assets.xcassets/AppIcon.appiconset/AppIcon~ios-marketing.png`; `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png`
- `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png`; `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png`; `ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png`

## Recheck commands and limits

```text
git ls-files
git ls-files -ci --exclude-standard
rg -n "flutter_to_arch|build_arch_package" pubspec.yaml .github
python -m unittest discover -s .github/scripts/tests -p "test_arch_package.py"
dart tool/check_git_dependencies.dart
```

Recheck package references with `rg -n "package:<name>/" lib test tool patch`, followed by pubspec configuration, native plugin metadata and workflows. The Arch regression executes the real --prepare-only entry in a temporary directory, validates the app archive, desktop entry, dependencies and Dockerfile, and forbids external commands. It is not makepkg/Linux installation acceptance. P1.3 symbol candidates and ARM64 tool consolidation remain separate follow-ups.
