# 构建与开发

English version: [build.en.md](build.en.md)

本文面向准备从源码构建、测试或维护 VeneraNext 的开发者。安装和使用说明请阅读仓库根目录的 [README](../../README.md)。

## 环境要求

- Flutter `3.41.4`
- Dart `>=3.8.0 <4.0.0`
- JDK `17`，用于 Android 构建
- Rust 工具链；Android 构建需要安装对应 Android targets
- 目标平台原生构建环境，例如 Android SDK / NDK、Xcode、Visual Studio 或 Linux GTK/WebKit 依赖
- Windows 本地构建需要开启系统“开发者模式”；PDF 导入依赖的 `pdfrx` native assets 会在构建时创建符号链接

先检查 Flutter 环境：

```bash
flutter doctor -v
flutter --version
```

## 获取依赖

克隆仓库后，使用仓库锁文件获取依赖：

```bash
git clone https://github.com/CyrilPeng/venera-next.git
cd venera-next
flutter pub get --enforce-lockfile
```

不要在不了解依赖影响的情况下删除或重新生成 `pubspec.lock`。

Git fork 的来源、固定 commit 和升级要求见[依赖治理](dependencies.zh.md)。

### 关键依赖锁定

项目依赖 `rhttp 0.15.1`，必须保持 `flutter_rust_bridge 2.11.1`。版本不匹配时，构建可能成功，但应用启动后无法联网，并提示：

```text
flutter_rust_bridge has not been initialized
```

在 PowerShell 中可以检查锁定版本：

```powershell
Select-String pubspec.lock -Pattern "flutter_rust_bridge" -Context 0,6
```

结果应包含：

```yaml
version: "2.11.1"
```

## 质量检查

先按[测试执行与维护](testing.zh.md)准备本机适用的原生库，提交代码前至少运行：

```bash
python .github/scripts/release_version.py --check
python .github/scripts/check_structure_imports.py
python .github/scripts/check_architecture_dependencies.py
python .github/scripts/test_suites.py --strict-imports --output build/test-audit/inventory.json
python -m unittest discover -s .github/scripts/tests -p "test_*.py"
flutter analyze --no-pub --fatal-infos --fatal-warnings
python .github/scripts/run_flutter_tests.py --suite default --coverage --output build/test-audit/default
git diff --check
```

需要早期反馈时运行 `python .github/scripts/run_flutter_tests.py --partition fast --concurrency 4`。完整质量流程由快速组、原生准备与 sanitizers、三个全量分片和真实 TV flavor 组成；「Flutter 测试与覆盖率」汇总门禁核对必需状态、文件并集、实际用例及来源摘要，并合并 `coverage/lcov.info`。当前覆盖率用于观察模块与关键路径，尚未设置统一百分比硬阈值。

PR 保留 `依赖安全审查` 和 `PR 平台冒烟构建`。相关 Flutter、根测试、原生、依赖、脚本及工作流变更触发 Android 手机版／TV Debug 和 Windows 原生／窗口回归；原生平台路径另触发 Linux、macOS 与 iOS 构建。鸿蒙继续使用独立固定 SDK 的 host 与 HAP 门禁。文档等不影响平台构建的改动按原路径规则跳过；具体触发以工作流为准。Dart 格式检查只检查本次修改的文件，`main` 继续要求既有质量、依赖与平台门禁，禁止直接强推或删除分支。

## 翻译维护

当前支持简体中文、繁体中文、英文、德语和日语。[语言注册表](../../lib/foundation/app_language.dart)统一维护设置选项、Flutter 支持列表及翻译标识；已保存的 `zh-CN`、`zh-TW`、`en-US` 不变，新增 `de-DE`、`ja-JP`；词典与 JS `APP.locale` 使用 `zh_CN`、`zh_TW`、`en_US`、`de_DE`、`ja_JP`。系统语言按偏好顺序匹配，德语地区变体和未带地区的日语均能识别，应用默认仍跟随系统。漫画源脚本的独立词典仍按现有地区／语言回退规则读取，德日不套用中文标签词库。

应用英文原文同时作为翻译键和默认回退文案，[translation.json](../../assets/translation.json)维护相同键集合的简中、繁中、德语和日语词典。新增或润色文案时同步调用与所有词典，不使用插值生成翻译键。参数使用 `@name`（英文字母开头，后续可含数字或下划线），通过 `tlParams` 传入同名参数；名称和出现次数应与原文一致，可调整顺序。运行时按完整参数名替换，保留未知参数和未知文案。品牌、格式、技术缩写和自然通用的词可与英文相同，不能用成段英文代替未完成的翻译。

沿用同模块的术语，例如画廊／畫廊、备份／備份、覆盖／覆寫。删除、覆盖及恢复提示必须保留操作对象、后果和确认含义。新增语种另行安排需求与校对者，完成词典、组件和布局验证后再开放语言选择。

在 `tool/code_audit` 执行 `dart pub get --enforce-lockfile`、`dart run bin/self_check.dart` 和 `dart run bin/check_translations.dart ../..`。CI 使用语法树检查跨行、拼接、转义、条件和列表中的静态键，并核对词典结构、重复键和参数；变量及其他动态文案仍需相应运行时回归，不能将静态扫描通过视为全部动态文案已翻译。实际资源加载、语言切换及英文回退由 `test/foundation/translations_test.dart` 和标签／语言回归验证。

### 术语参考

下表取自现有词典，用于理解功能边界；新增语种应按该语言习惯建立对应术语并保持一致。完整句子仍以实际页面与操作含义为准。

| 英文原文 | 简体中文 | 繁体中文 | 德语 | 日语 | 含义 |
| --- | --- | --- | --- | --- | --- |
| Comics | 漫画 | 漫畫 | Comics | 漫画 | 应用管理或阅读的作品 |
| Comic Source | 漫画源 | 漫畫源 | Comic-Quelle | 漫画ソース | 提供作品信息的扩展 |
| Favorites | 收藏 | 收藏 | Favoriten | お気に入り | 用户保存的作品与目录 |
| History | 历史 | 歷史 | Verlauf | 履歴 | 已有阅读记录 |
| Gallery | 画廊 | 畫廊 | Galerie | ギャラリー | 图片集合，沿用对应源的展示语义 |
| Continuous | 连续 | 連續 | Fortlaufend | 連続 | 同一章节内连续滚动 |
| Waterfall | 瀑布流 | 瀑布流 | Wasserfall | ウォーターフォール | 跨章节连续阅读 |
| Read later | 稍后阅读 | 稍後閱讀 | Später lesen | あとで読む | 保存计划阅读的作品 |
| Restore | 恢复 | 恢復 | Wiederherstellen | 復元 | 从备份恢复数据，保留覆盖后果的说明 |
| Backup | 备份 | 備份 | Backup | バックアップ | 用于恢复的备份副本 |
| Overwrite | 覆盖 | 覆寫 | Überschreiben | 上書き | 替换已有数据，提示中保留对象和后果 |
| Import | 导入 | 匯入 | Importieren | インポート | 将外部文件或数据加入应用 |
| Export | 导出 | 匯出 | Exportieren | エクスポート | 将应用内的数据写到外部文件 |
| Save | 保存 | 儲存 | Speichern | 保存 | 保存当前修改或图片，与下载整部作品区分 |

### 新语种验收

需求和校对参与方式见[翻译贡献](../../CONTRIBUTING.md#翻译贡献)。新增语种时，维护者同步语言注册表、系统语言匹配、Flutter 组件支持和翻译审查范围，并评估标签与漫画源语言回退；现有中文词典和英文回退继续校验。按语言拆分词典可与首批语种一起评估，当前文件格式保持现状。

- 核对同一源码提交的全部应用文案、参数名称与次数，并检查实际加载、显式切换、系统语言变化及英文回退；设置、阅读器、收藏、导入导出、备份恢复和错误提示都应覆盖。
- 记录校对者与已审校范围，逐项确认删除、覆盖、恢复提示和错误操作含义。静态审查通过后仍需验证动态文案与实际 Flutter 组件。
- 使用对应 commit 的 GitHub 构建产物，验证手机、桌面、窄屏及大字号下的设置、菜单、确认框与错误提示；记录语言、平台、文字缩放及构建运行链接。
- 完成词典、组件和布局验收后开放语言选择，并由语言维护者随功能变更更新文案。

德日的真实字体布局回归复用 `test/foundation/translations_test.dart`，覆盖手机、横屏、桌面及两倍字号的实际设置、菜单和覆盖确认。质量工作流上传 `i18n-layout` 截图与原始测试记录；组件核验不替代社区母语校对或设备验收。根 `README.md` 保持中文，四种 README 的语言入口和赞助展示需同步维护。

## Android 构建

本地 release 签名文件放置在：

```text
android/keystore.jks
android/key.properties
```

`android/key.properties` 示例：

```properties
storePassword=你的 store 密码
keyPassword=你的 key 密码
keyAlias=你的 key alias
storeFile=../keystore.jks
```

构建 APK：

```bash
flutter pub get --enforce-lockfile
flutter build apk --release --flavor mobile
flutter build apk --release --flavor tv
```

构建产物分别位于 `build/app/outputs/apk/mobile/release/` 和 `build/app/outputs/apk/tv/release/`。Android 必须明确指定 `--flavor mobile` 或 `--flavor tv`；不设置全局 `default-flavor`，避免影响 iOS/macOS 的原有 Xcode scheme。GitHub Actions 开启 Android 时会同时构建两种。TV 的独立包名、版本码偏移、更新方式和发布校验见 [Android TV 分发说明](../distribution/android_tv.zh.md)。

签名文件和密码属于敏感信息，不应提交到仓库。

## 桌面端与 iOS 构建

在对应操作系统和原生工具链就绪后执行：

```bash
flutter pub get --enforce-lockfile
flutter build windows
flutter build linux
flutter build macos
```

iOS 可先执行无签名构建验证：

```bash
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign
```

Windows 安装器、便携包和 winget manifest 的维护方法见 [Windows 分发](../distribution/windows.zh.md)。

## GitHub Actions 与发布版本

仓库工作流负责持续集成、手动构建、tag 发布和分发元数据维护。发布版本号统一维护在 `release.json`：

```json
{
  "version": "1.2.3",
  "build": 123
}
```

准备发布时先更新 `release.json`，再同步并校验相关文件：

```bash
python .github/scripts/release_version.py --write
python .github/scripts/release_version.py --check --tag v1.2.3
```

`pubspec.yaml`、发布 tag 和 `CHANGELOG.md` 版本章节必须与 `release.json` 一致。`alt_store.json` 不是版本源；正式版 GitHub Release 成功后，工作流会根据发布资产更新它，RC 预发布不会更新 AltStore 源。

`代码分析` 工作流会运行版本与结构检查、Python 脚本测试、修改文件的 Dart 格式检查、`flutter analyze`、完整 Dart 测试及覆盖率汇总。`依赖安全审查` 会检查 PR 新增或升级的依赖，`PR 平台冒烟构建` 会按改动范围验证 Android 和 Windows 编译。`完整构建` 在开始多平台构建前会复用同一质量工作流；手动平台构建和 tag 发布则共同复用 `.github/workflows/build.yml`，避免两套构建定义产生差异。

`完整构建` 同时等待准确提交的最新 RustSec 扫描和各平台真实安装包回执。手动运行默认 `mode=build`，全部包核验成功后留在 Actions；`mode=rehearsal` 额外演练内部草稿的真实上传及下载，`rehearsal_interrupt=true` 验证中断后复用原包恢复。手动模式不公开 Release、不推进 AltStore 或 Winget；正式标签通过完整门禁后发布。安全报告超过 24 小时先重新扫描原锁文件，普通安装包与回执保留 30 天。具体条件见[发布流程](release_readiness.md)。本项目的实际安装包构建均使用 GitHub Actions。

Android release 工作流需要以下仓库 Secrets：

- `ANDROID_KEYSTORE`：keystore 文件的 Base64 内容
- `ANDROID_KEY_PROPERTIES`：`key.properties` 文本内容

发布后的 AltStore 更新会复用固定分支 `automation/update-altstore` 并创建 PR。仓库需要配置可向当前仓库推送分支并创建 PR 的 `ALTSTORE_PR_TOKEN`；未单独配置时会复用 `WINGET_PKGS_TOKEN`。令牌缺失或 PR 创建失败会使任务明确失败，不再产生只有分支、没有 PR 的成功记录。

Issue 分类与格式检查默认运行，不需要 AI API：`.github/scripts/issue_policy.py` 校验新表单、按类型要求诊断并维护分类／补充信息标签。新建、编辑、重新打开及评论变化会复查，同一提示评论更新；机器人事件、PR、已关闭和旧格式报告跳过。首次需要时自动创建分类标签，保留已有同名标签的颜色和说明。用户采集步骤见[Issue 提交说明](../user/issue_reporting.zh.md)。

可选 AI 摘要默认关闭，仅对格式检查通过的新建／编辑报告运行。确认 `API_URL`、`API_KEY` 可用后，将仓库变量 `ENABLE_AI_ISSUE_CHECK` 设为 `true`；`ISSUE_CHECK_MODEL` 可覆盖模型。格式和 AI 各自按 Issue 串行更新，机器人事件在作业入口跳过，不占用用户事件的待运行位置；AI 耗时不阻塞后续格式复查。AI 更新单独标记的评论，读取已有正文及报告者／维护者补充，失败不影响固定规则；只给维护者建议，不自动关闭。Issue 正文不插入 shell 命令，附件不由自动检查下载。

不要把 Secrets、签名文件或实际密码写入代码、日志和文档示例。

## 构建问题排查

### 构建成功但应用无法联网

优先确认 `flutter_rust_bridge` 仍为 `2.11.1`，并确认依赖是通过当前仓库的 `pubspec.lock` 获取。不要通过盲目升级依赖解决初始化错误。

### 提示 `flutter_rust_bridge has not been initialized`

通常是依赖版本漂移。恢复仓库中的 `pubspec.lock`，确认 Flutter 版本符合要求，再运行：

```bash
flutter pub get --enforce-lockfile
```

### 提示 `Unable to satisfy pubspec.yaml using pubspec.lock`

通常是 Flutter/Dart 版本或包源环境不匹配。先核对本页要求的 Flutter 版本和 `flutter doctor -v` 输出，不要直接删除锁文件。

### Gradle 下载过慢

可以在本地临时切换 Gradle wrapper 镜像或配置网络代理，但环境相关地址不应提交到仓库。提交前应确认 `gradle-wrapper.properties` 没有混入本地镜像改动。

## 历史记录与恢复

已完成的历史整理、依赖迁移、测试优化及 Issue 快照从 [v1.18.4-rc.3 文档树](https://github.com/CyrilPeng/Venera-Next/tree/v1.18.4-rc.3/doc)检索。恢复历史实现使用对应标签或保存的 Git bundle，在独立工作区核对来源、锁与版本；历史 SHA 和已发布资产继续对应当时的输入。鸿蒙冻结／最后分支来源见[恢复标签](harmonyos_releases.zh.md#历史来源与恢复)。

临时命令与分析日志放入 `logs/`，生成工程、SDK、安装包下载和编译缓存放入忽略的 `build/`。验收完成后保留来源、最终结果、关键失败、安全与设备报告，清理可重建副本；长期规则合并进现有指南，避免每个版本新增计划和跟进文档。
