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

提交代码前至少运行：

```bash
python .github/scripts/check_structure_imports.py
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

涉及发布版本时再运行：

```bash
python .github/scripts/release_version.py --check
```

仓库模块边界和入口约定见[项目结构约定](../architecture/project_structure.zh.md)。

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
flutter build apk --release
```

构建产物通常位于 `build/app/outputs/apk/release/`。

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

Android release 工作流需要以下仓库 Secrets：

- `ANDROID_KEYSTORE`：keystore 文件的 Base64 内容
- `ANDROID_KEY_PROPERTIES`：`key.properties` 文本内容

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
