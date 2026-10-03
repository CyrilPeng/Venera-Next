# 直接依赖与仓库产物用途审查

日期：2026-10-03。审查起点：`9b06917` 的 881 个已跟踪路径及其当前工作区内容；不包括未跟踪用户文件。本文记录 P1.4/P1.5 的用途核对，不替代 P1.3 公开符号/动态入口可达性清单，也不是安全、许可证或跨平台构建完成声明。

## 依赖判定

逐项比较 pubspec 的 dependencies、dev_dependencies、dependency_overrides 与已跟踪 Dart import/export；再检查工作流、平台插件注册、配置、assets/init.js 与 JS 宿主桥。下表列完整包清单、匹配文件数及首个入口；数量只表示显式引用，不推断未引用符号可删除。Git fork 的功能差异与许可待办继续见 [原审计](../development/dependency_audit.zh.md)。

| Package | Scope | Dart files | 用途证据 / 决定 |
|---|---|---:|---|
| `flutter` | `dependencies` | 227 | [lib/app_runtime/headless.dart:3](../../lib/app_runtime/headless.dart) — 保留 |
| `path_provider` | `dependencies` | 3 | [lib/features/local_comics/local.dart:15](../../lib/features/local_comics/local.dart) — 保留 |
| `intl` | `dependencies` | 2 | [lib/features/image_favorites/image_favorites_item.dart:3](../../lib/features/image_favorites/image_favorites_item.dart) — 保留 |
| `window_manager` | `dependencies` | 4 | [lib/components/window_frame.dart:11](../../lib/components/window_frame.dart) — 保留 |
| `sqlite3` | `dependencies` | 54 | [lib/features/favorites/favorite_row.dart:1](../../lib/features/favorites/favorite_row.dart) — 保留 |
| `sqlite3_flutter_libs` | `dependencies` | 0 | 保留：sqlite3 的五平台原生库；已解析 0.5.42 pubspec 声明插件及本机 Windows/Linux/macOS 生成注册均含该包。生成注册不纳入 Git。 |
| `flutter_qjs` | `dependencies` | 17 | [lib/components/js_ui.dart:5](../../lib/components/js_ui.dart) — 保留 |
| `crypto` | `dependencies` | 3 | [lib/features/history/image_favorites_provider.dart:2](../../lib/features/history/image_favorites_provider.dart) — 保留 |
| `dio` | `dependencies` | 13 | [lib/features/comic_source/source_repository_page.dart:3](../../lib/features/comic_source/source_repository_page.dart) — 保留 |
| `html` | `dependencies` | 1 | [lib/foundation/js_engine.dart:10](../../lib/foundation/js_engine.dart) — 保留 |
| `pointycastle` | `dependencies` | 1 | [lib/foundation/js_engine.dart:13](../../lib/foundation/js_engine.dart) — 保留 |
| `url_launcher` | `dependencies` | 10 | [lib/components/js_ui.dart:6](../../lib/components/js_ui.dart) — 保留 |
| `path` | `dependencies` | 15 | [lib/features/comic_storage/file_system_layout.dart:1](../../lib/features/comic_storage/file_system_layout.dart) — 保留 |
| `photo_view` | `dependencies` | 7 | [lib/features/comic_details/cover_viewer.dart:5](../../lib/features/comic_details/cover_viewer.dart) — 保留 |
| `mime` | `dependencies` | 1 | [lib/foundation/file_type.dart:1](../../lib/foundation/file_type.dart) — 保留 |
| `share_plus` | `dependencies` | 1 | [lib/foundation/file_interaction.dart:10](../../lib/foundation/file_interaction.dart) — 保留 |
| `scrollable_positioned_list` | `dependencies` | 2 | [lib/features/reader/continuous_view.dart:9](../../lib/features/reader/continuous_view.dart) — 保留 |
| `flutter_reorderable_grid_view` | `dependencies` | 4 | [lib/features/favorites/local_favorites_page.dart:6](../../lib/features/favorites/local_favorites_page.dart) — 保留 |
| `uuid` | `dependencies` | 6 | [lib/features/comic_source/source_repositories.dart:5](../../lib/features/comic_source/source_repositories.dart) — 保留 |
| `desktop_webview_window` | `dependencies` | 2 | [lib/main.dart:14](../../lib/main.dart) — 保留 |
| `flutter_inappwebview` | `dependencies` | 3 | [lib/features/comic_source/comic_source_page.dart:7](../../lib/features/comic_source/comic_source_page.dart) — 保留 |
| `app_links` | `dependencies` | 1 | [lib/routing/app_links.dart:3](../../lib/routing/app_links.dart) — 保留 |
| `sliver_tools` | `dependencies` | 4 | [lib/features/comic_details/comments_preview.dart:2](../../lib/features/comic_details/comments_preview.dart) — 保留 |
| `flutter_file_dialog` | `dependencies` | 1 | [lib/foundation/file_interaction.dart:5](../../lib/foundation/file_interaction.dart) — 保留 |
| `file_selector` | `dependencies` | 1 | [lib/foundation/file_interaction.dart:3](../../lib/foundation/file_interaction.dart) — 保留 |
| `zip_flutter` | `dependencies` | 10 | [lib/features/local_comics/archive_download_task.dart:14](../../lib/features/local_comics/archive_download_task.dart) — 保留 |
| `lodepng_flutter` | `dependencies` | 1 | [lib/foundation/image_processing.dart:10](../../lib/foundation/image_processing.dart) — 保留 |
| `rhttp` | `dependencies` | 2 | [lib/app_runtime/bootstrap_core.dart:4](../../lib/app_runtime/bootstrap_core.dart) — 保留 |
| `webdav_client` | `dependencies` | 4 | [lib/features/sync/comic_backup.dart:8](../../lib/features/sync/comic_backup.dart) — 保留 |
| `battery_plus` | `dependencies` | 1 | [lib/features/reader/status_info.dart:3](../../lib/features/reader/status_info.dart) — 保留 |
| `local_auth` | `dependencies` | 2 | [lib/app_shell/auth_page.dart:4](../../lib/app_shell/auth_page.dart) — 保留 |
| `flutter_saf` | `dependencies` | 5 | [lib/app_runtime/bootstrap_core.dart:3](../../lib/app_runtime/bootstrap_core.dart) — 保留 |
| `dynamic_color` | `dependencies` | 1 | [lib/main.dart:15](../../lib/main.dart) — 保留 |
| `shimmer_animation` | `dependencies` | 3 | [lib/features/comic_details/comic_page.dart:6](../../lib/features/comic_details/comic_page.dart) — 保留 |
| `flutter_memory_info` | `dependencies` | 1 | [lib/features/reader/reader_page.dart:5](../../lib/features/reader/reader_page.dart) — 保留 |
| `syntax_highlight` | `dependencies` | 1 | [lib/components/code.dart:3](../../lib/components/code.dart) — 保留 |
| `flutter_7zip` | `dependencies` | 1 | [lib/features/local_comics/import_export/cbz.dart:4](../../lib/features/local_comics/import_export/cbz.dart) — 保留 |
| `flex_seed_scheme` | `dependencies` | 1 | [lib/main.dart:16](../../lib/main.dart) — 保留 |
| `flutter_localizations` | `dependencies` | 1 | [lib/main.dart:19](../../lib/main.dart) — 保留 |
| `yaml` | `dependencies` | 3 | [lib/foundation/app.dart:8](../../lib/foundation/app.dart) — 保留 |
| `enough_convert` | `dependencies` | 3 | [lib/features/local_comics/import_export/cbz.dart:3](../../lib/features/local_comics/import_export/cbz.dart) — 保留 |
| `display_mode` | `dependencies` | 1 | [lib/app_runtime/init.dart:3](../../lib/app_runtime/init.dart) — 保留 |
| `flutter_staggered_grid_view` | `dependencies` | 1 | [lib/features/reader/chapter_comments.dart:3](../../lib/features/reader/chapter_comments.dart) — 保留 |
| `archive` | `dependencies` | 10 | [lib/features/local_comics/import_export/cbz.dart:2](../../lib/features/local_comics/import_export/cbz.dart) — 保留 |
| `image` | `dependencies` | 7 | [lib/features/local_comics/import_export/pdf_import.dart:4](../../lib/features/local_comics/import_export/pdf_import.dart) — 保留 |
| `pdfrx` | `dependencies` | 2 | [lib/features/local_comics/import_export/pdf_import.dart:5](../../lib/features/local_comics/import_export/pdf_import.dart) — 保留 |
| `xml` | `dependencies` | 1 | [lib/features/local_comics/import_export/epub_import.dart:9](../../lib/features/local_comics/import_export/epub_import.dart) — 保留 |
| `flutter_test` | `dev_dependencies` | 213 | [test/app_runtime/background_sync_test.dart:2](../../test/app_runtime/background_sync_test.dart) — 保留 |
| `flutter_lints` | `dev_dependencies` | 0 | [analysis_options.yaml](../../analysis_options.yaml): `include: package:flutter_lints/flutter.yaml` — 保留 |
| `flutter_to_arch` | `dev_dependencies` | 0 | 删除开发依赖及其独占传递包 io；CI 只运行 build_arch_package.py。同名顶层配置仍由 Python 消费，保留。 |
| `flutter_rust_bridge` | `dependency_overrides` | 0 | 保留：已解析 rhttp 0.15.1 声明 ^2.11.1；项目固定 2.11.1，validate_release.py 校验。直接 import 缺失不等于无用。 |

`html`、`pointycastle`、`crypto`、`enough_convert` 等在 js_engine.dart 的桥接实现中使用；assets/init.js 使用宿主暴露的能力，不要求 JS 再出现 Dart 包名。pubspec 声明的 CHANGELOG、pubspec 自身和资源文件仍为运行时资产。未升级任何保留包，也未变更其来源或校验值；锁文件只删除 flutter_to_arch 与 io 两块。

## 已跟踪产物与工具

按 git ls-files 全量遍历路径和非空文件 SHA-256，检查 output/build/coverage/.dart_tool、日志、临时/备份文件、字节码、归档及最大文件；这些临时输出模式没有已跟踪命中。以下逐项记录所有非测试打包/维护脚本和 C 辅助程序；测试代码与源码本身不因文件名含 test 或大量生成数据而删除。

| 工具 | 调用入口 / 决定 |
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
| `windows/build_arm64.py` | 保留待调查：无已跟踪调用者，仍是直接可执行的 ARM64 打包入口，引用 build_arm64.iss；与 x64 脚本不等价。后续需合并实现或确认人工入口退役后再删除。 |
| `patch/font.dart` | `.github/workflows/build.yml` |
| `tool/check_git_dependencies.dart` | `.github/workflows/analyze.yml` |

其他保留类别：fastlane 截图/商店元数据由发布流程使用；平台图标由资源清单、Xcode 工程或安装包读取；tags/opencc 为应用资源；API 文档、实验设计和优化执行记录是维护材料。四份 doc/api 文档虽命中历史 .gitignore 规则，但属于已跟踪 API 文档，不是生成缓存。

### 内容完全相同的文件组

下列非空文件组具有相同 SHA-256；均为不同平台/构建模式要求的资源或工程元数据路径，保留，不以字节相同代替入口分析。无字节相同的维护脚本。

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

## 复核命令与边界

```text
git ls-files
git ls-files -ci --exclude-standard
rg -n "flutter_to_arch|build_arch_package" pubspec.yaml .github
python -m unittest discover -s .github/scripts/tests -p "test_arch_package.py"
dart tool/check_git_dependencies.dart
```

包引用可用 `rg -n "package:<包名>/" lib test tool patch` 复查，再核对 pubspec 配置、原生插件元数据和工作流。Arch 回归在临时目录执行真实 --prepare-only 入口，验证应用归档、桌面文件、依赖列表与 Dockerfile，禁止外部工具调用；它不等价于 makepkg/Linux 安装验收。P1.3 符号候选清单及 ARM64 工具整合仍单独追踪。
