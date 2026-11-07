# HarmonyOS 构建与发布工具

鸿蒙平台适配与完整阅读器统一维护在 `main`，使用独立 Flutter OH SDK 从同一主线提交生成 HAP。普通平台保留官方 Flutter、根 pubspec／lock；鸿蒙依赖覆盖、受控锁、ArkTS 模板与原生工具集中在本目录。用户入口见[测试版安装指南](../../doc/distribution/harmonyos-reader.zh.md)；早期探针记录见[实验记录](../../doc/experiments/harmonyos.zh.md)。

当前主线候选为 **`1.18.3+245`**，包含收藏导航、依赖治理及官方来源调整；
schema 3 的下一配置从调用方 checkout 选择准确主线 SHA，所有平台使用同一来源。
既有 `1.18.3+244` 继续使用提交 `3e1be1391ba784bb228803525696d38c208f471f`
和原锁文件、原生库及 Release 资产；不以新 HAP 覆盖这些历史产物。
后续候选的读者版本门禁为 `>=245`，与主线的冻结 pin 分开验证。

本候选只用于无发布预览。2026-11-06 审计发现的适用 QuickJS-NG 核心缺陷已在
`f5a1f20` 中回移修复；Linux 64／32 位 ASan／UBSan 与 Windows 64／32 位 ASan
均已通过，来源和边界见依赖的 CORE_PATCHES.md／JSON。旧 d07 的泛型 push 没有
后来引入的优化缺陷。主线下一 pin 的 `release_enabled` 保持 false，完整平台构建
与签装、真机运行分别验证，宿主安全回归不作为鸿蒙运行验收。

完整阅读器记录仓库内八个包的输入摘要；滚动列表已回归官方 pub.dev 0.3.8。
主线 Windows 本地包也纳入源码审计，HAP 实际依赖继续由协调的 CPF 平台组覆盖。
源码清单和项目包摘要使用已提交的 canonical Git blob，保持二进制原字节，避免 `.gitattributes` 的 CRLF 检出规则改变摘要；生成前拒绝工作区或暂存源码漂移，不将未提交输入隐藏在固定提交的摘要后。
PNG／7z 由 `packages/venera_native` 的自编桥接和独立固定的官方核心编译成
`libvenera_native.so`，核对九个导出及包内第三方声明；不再获取原组织的两个包装层。
`venera_saf` 随源码同步，鸿蒙继续使用自己的目录能力边界；Android SAF 插件不被
声明为鸿蒙持久授权实现。独立 OH 锁文件仅同步所需来源和覆盖路径。

## 随版完整阅读器

主线 `.github/workflows/harmonyos-release.yml` 保留 `.github/harmonyos-release.json` 的 schema 1 冻结来源，下一候选采用 schema 3 的 `source_mode: release_commit`。构建 checkout 必须精确等于调用方 HEAD，拒绝未提交、暂存和未跟踪输入；普通业务修复无需同步另一条开发分支或更新共同基线。上下文保留准确版本、提交和运行号，预览继续拒绝 Release 发布。

`release_context.py` 验证准确来源提交、版本、构建号、运行号和 changelog 摘要。`prepare_full_app.py` 只在 `build/harmonyos/full-app` 注入版本与 changelog，运行源码与主线 canonical Git blob 一致；本地构建读取同一源码的 `release.json`。`app/pubspec.lock.template` 是独立 OH SDK 的受控锁，CI 使用 `--enforce-lockfile`。

`ci_full_app.py` 在独立工程中执行严格分析、宿主回归、真实 ARM64 HAP 构建及 ELF／资产审计。发布模式输出 `VeneraNext-版本-harmonyos-arm64-unsigned.hap`、`harmonyos-manifest.json`、`harmonyos-SHA256SUMS` 和两份 `harmonyos-install.*.md`；主线再次核对固定 Git 源码清单、包内版本及全部五项资产，草稿上传核验通过后才发布。失败不允许静默略过 HAP。

CPF WebView 保留其 OHOS 实现，并从主线固定的官方 `0aaf7a0` 导出浏览器退出事件 Dart 接口与类型，补齐 Windows 专用代码的静态依赖。生成时先替换主线同名 Git／Windows 本地 overrides，再插入协调的 CPF path 组，拒绝重复 YAML key。覆盖层不改写应用代理逻辑、不生成退出事件；生成工程用于 HAP，Windows 发行使用主线自己的来源。复制的上游类型与生成文件保持原字节，原始和适配后的依赖树均记录摘要。

签名、设备授权与私钥始终留在用户本机；CI 不安装到真机、不签名、不自动关闭或跟踪 issue。首个随版 Release 构建号至少为 244；接入 CI 不创建版本、标签或 Release。`packaging_pass` 不是覆盖升级、续签或全功能真机验收。

在已准备好同一 API 26 SDK 和已审计核心原生库的环境中：

```bash
python3 tool/harmonyos/prepare_full_app.py deps --qjs-source "$QJS_SOURCE"
python3 tool/harmonyos/full_native_build.py --sdk-native "$HARMONY_NATIVE_SDK"
python3 tool/harmonyos/ci_full_app.py --flutter-sdk "$FLUTTER_OH_SDK"
```

## 主线候选构建与早期 SDK 记录

`.github/workflows/harmonyos-experiment.yml` 在相关主线 PR、push 和手动触发时复用 `harmonyos-release.yml`。PR 使用准确 Actions 合并候选 SHA，push 使用准确主线 SHA，与普通 Flutter 校验保持同一来源。临时 Ubuntu runner 独立安装 SDK，只输出候选 artifacts。

此前 Cocos API 21 和 SDL API 24 CLI 均完成下载校验、安装和空白工程尝试，但当前固定 Flutter OH 嵌入层引用了旧 SDK 缺少的接口，ArkTS 编译失败。HAR 中的旧编译元数据不能作为完整 ArkTS 接口兼容的依据；当前 Flutter OH 发布说明要求以 `26.0.0` 编译。现使用[社区 CI 镜像](https://github.com/zhongdaiqi/command-line-tools-for-hmos/releases/tag/clt-26.0.0.851)的 CLI `26.0.0.851` / API 26，并以 GitHub Release 资产摘要固定两个原始分片的大小和 SHA-256。先逐片校验、再按固定顺序拼接 ZIP，并记录完整包摘要；不伪造 SDK 目录或元数据，不删减引擎接口，也不关闭 ArkTS 检查。

这不是华为官方分发地址或官方校验值，完整镜像的真实性仍基于第三方维护者和下载时的 GitHub 资产记录；哈希固定用于防止后续内容静默变化，不表示已完成官方供应链认证。CLI 分发参考保存在 `toolchain.json`。商业 API 26 云端基线与下文公开 API 20 本机基线严格分开。

首次 API 26 运行已确认真实 Native 组件版本为 `26.0.0.105`，空白包、核心库编译、探针分析与 6 项宿主回归均通过；探针 HAP 编译完成后，由于自动 strip 改写库字节而被严格哈希检查拒绝。现固定组件版本和重建 ZIP 的完整 SHA-256，并关闭探针模块的自动 strip 后重新验证；不能把被审计拒绝的那次运行称为全流程成功。

主线候选流程先验证空白工程，再重编译全部核心／完整阅读器原生库并构建完整阅读器；早期核心与升级探针保留为手动实验工具。模块关闭自动 strip，核对 AArch64 ELF、实际入包库及精确哈希，拒绝缺库、内容变化和空包。证据保留 14 天，当前产物使用 `harmonyos-release` 名称但只供未签名候选验证。

只有完整阅读器阶段的 `packaging_pass` 表示 `lib/main.dart` 和原应用代码实际编译入包；空白或探针成功不能替代它。未签名包仍需用户本地签装，CI 不证明原生库真机运行或数据恢复。DevEco 仅保留为开发者调试备选，不要求普通用户安装完整 SDK。

## 早期签装与升级探针记录

早期实验采用“unsigned HAP + 用户本地小白调试助手”路线验证核心探针。以下保留开发与历史核对方法，不是当前阅读器安装入口，也不要求用户重复已完成的探针测试。旧配对指南见[中文](../../doc/distribution/harmonyos.zh.md) / [English](../../doc/distribution/harmonyos.en.md)。CI 不保存签名材料，不声称免开发者账号或永久免续签。

2026-10-29 已将 #77 自愿测试者的三份平板报告与 `ef2904f` 构建配对及原生记录核对，结果为 `reported_checks_pass`；空白包成功按本人反馈单独记录。结论仅覆盖该设备／版本的核心探针、进程重启和合成升级数据，不认证硬件／签名身份，不验证续签、文件导入或完整阅读器。脱敏结论及摘要见[设备复核记录](../../doc/experiments/data/harmonyos-tablet-device-review-20261029.json)，原始 JSON 不进版本控制。后续文档更新触发的新构建不替代这次设备报告所对应的旧配对，也无需测试者重复相同四步。

云端在 baseline `0.3.0+4` 之后构建 upgrade `0.3.1+5`，保持探针包名不变。空白包与两份探针均只声明 `phone`／`tablet`，审计实际入包设备类型，拒绝遗漏平板或扩大到 PC／TV；不混用旧 `0.2.x` 配对。两包携带相同源/原生库配对标识，导出前核对真实 `module.json`、嵌入标识、API 26 与原生库哈希，生成 `sideload-manifest.json`、`SHA256SUMS` 及离线安装指南。只有整条流程成功才提供测试包，仍不创建 Release。宿主测试生成的合成数据不属于真机验收。

```powershell
# prepare_probe 默认准备 baseline；生成 upgrade 时额外传 --sideload-stage upgrade。
# 可用 --native-dir 指定已经通过 verify_native_report 的独立原生报告/arm64-v8a 目录。
# 依赖已缓存时可用 --dart-only --offline 完成不依赖 SDK/网络的宿主准备。
python tool/harmonyos/review_sideload.py --manifest <manifest.json> --baseline <baseline.json> --restart <restart.json> --upgrade <upgrade.json>
```

探针只在 baseline 首次启动创建独立合成标记，upgrade 不补写缺失标记。三份设备报告必须来自同一配对、三个启动且数据一致；复核工具仅检查报告，不证明签名密钥、续签或阅读器已可用。当前最低 SDK 仍为 `26.0.0`；先确认测试设备满足要求，不通过改低字段掩盖兼容问题。

## 准备

- Python 3.12+、Git、Rust 1.92.0，以及独立安装的 Flutter OH SDK；固定版本见 `toolchain.json`。
- OpenHarmony 6.0 公开 SDK 的 Native 组件（API 20，组件内部版本 `6.0.0.47-Beta1`）。校验完整下载包 SHA-256 后解压，不把它冒充商业 HarmonyOS SDK。
- QuickJS 使用主工程 `pubspec.lock` 固定的 `CyrilPeng/flutter_qjs` 提交；可用 `flutter pub get` 已下载的 Git 缓存，也可单独克隆该提交。脚本不改写缓存中的源码。
- SQLite 使用 `toolchain.json` 指定的官方源码和 `sqlite3.c` 校验值；主工程 Windows 构建已有的同一份 amalgamation 也可复用。
- 本机 HAP 构建仍需完整 DevEco / HarmonyOS SDK（当前实验工程默认 API 26）、配套 ohpm、hvigor、Node、JDK；也可仅使用上述云端流程。签名和设备账号由开发者本机配置，不提交私钥、证书、UDID 或账号数据。

安装 Flutter OH 时不要覆盖主工程原有 SDK。也不要运行全局 `flutter upgrade` 或修改全局 Flutter 配置：

```powershell
# 示例路径按本机安装位置调整；在仓库根目录执行。
$flutterOh = 'D:/soft/flutter_ohos'
git clone --filter=blob:none --sparse --depth 1 --branch '3.41.9+ohos-1.0.2' `
  https://gitcode.com/CPF-Flutter/flutter_flutter.git $flutterOh
git -C $flutterOh sparse-checkout set bin packages dev examples

# 仅影响当前 PowerShell 进程。网络不通时再启用本地代理。
$env:PUB_HOSTED_URL = 'https://pub.dev'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:FLUTTER_OHOS_STORAGE_BASE_URL = 'https://flutter-ohos.obs.cn-south-1.myhuaweicloud.com'
$env:FLUTTER_GIT_URL = 'https://gitcode.com/CPF-Flutter/flutter_flutter.git'
# $env:HTTPS_PROXY = 'http://127.0.0.1:7897'
# $env:HTTP_PROXY = $env:HTTPS_PROXY

rustup target add aarch64-unknown-linux-ohos --toolchain 1.92.0-x86_64-pc-windows-msvc
& "$flutterOh/bin/flutter.bat" --version
```

普通 Flutter 引擎资源和 OHOS 引擎资源使用两个不同的存储地址，不能都设为 OHOS OBS 地址。公开 SDK 下载地址和哈希保存在 `toolchain.json`，解压后 `--sdk-native` 应指向包含 `oh-uni-package.json`、`llvm/`、`sysroot/` 的 Native 目录。

## 构建原生库

```powershell
$native = 'D:/soft/ohos_sdk_public/20/native'
$qjs = '<固定提交的 flutter_qjs 源码目录>'
$sqlite = '<固定版本的 sqlite3.c>'
python tool/harmonyos/native_build.py --sdk-native $native --qjs-source $qjs --sqlite-source $sqlite
python -m unittest discover -s tool/harmonyos -p 'test_*.py' -v
```

输出位于 `build/harmonyos/native/arm64-v8a/`；报告位于 `build/harmonyos/native/native-build.json`。检查 AArch64 ELF、所需动态库、关键 FFI 导出和文件 SHA-256。只有全量构建和检查均通过才记为 `cross_compile_pass`，部分构建不能用来准备探针。

该报告永远不会因为编译成功就把 `runtime_verified` 或 `hap_built` 置为 true。OpenHarmony API 20 交叉编译通过不等于商业 HarmonyOS 的 ABI、加载或运行通过；云端 HAP 需要以选定商业 SDK 重新全量编译核心库，不能直接使用这些 API 20 产物。

## 准备与检查测试工程

```powershell
# 缺少 DevEco 时只做 Dart 依赖解析，不生成 OHOS 插件注册，不宣称可构建 HAP。
python tool/harmonyos/prepare_probe.py --flutter-sdk $flutterOh --qjs-source $qjs --dart-only
Push-Location build/harmonyos/probe
try {
  & "$flutterOh/bin/flutter.bat" analyze --no-pub
  & "$flutterOh/bin/flutter.bat" test --no-pub --reporter expanded
} finally { Pop-Location }
```

`prepare_probe.py` 会校验 SDK 提交、构建脚本/基线指纹、rhttp 当前源码和每个原生库的哈希，拒绝过期或失败的构建。QuickJS 只在 `build/harmonyos/deps/` 下导出固定提交，增加一个 OHOS `DynamicLibrary.open('libqjs.so')` 加载分支；补丁锚点变化时失败，不静默猜测。FRB 使用既有的显式库加载入口，不编辑生成代码。SQLite 使用包本身提供的 loader override。

默认 Flutter 回归运行 17 项、跳过 3 项原生宿主逻辑测试，包含小白签装合成状态、升级和平板横竖屏／分屏报告复制及旋转状态回归。在 Windows 上已有主工程编译产物时，可将当前终端的 `HARMONYOS_PROBE_HOST_LIBDIR` 指向含 `rhttp.dll`、`sqlite3.dll`、`flutter_qjs_plugin.dll` 的构建目录，并将该目录加到本进程 PATH，再执行同一测试命令。这样共运行 20 项，可检查探针逻辑本身；加载的是 Windows DLL，绝不计为 OHOS ELF 运行通过。原生宿主测试会在系统临时目录保留一份很小的合成 SQLite fixture，便于诊断，不读取应用数据。

测试源码以 `.template` 保存，避免被主工程的 Dart 分析当成已接入的平台代码；生成工程、库、日志和签名信息都不进版本控制。脚本会覆盖生成工程中的探针源码；签名、SDK 等本机配置不要放进模板。Dart 依赖使用独立锁文件，不修改主工程 `pubspec.yaml` / `pubspec.lock`。

## DevEco / 真机阶段

1. 安装完整 DevEco 工具链，使用当前终端的 `DEVECO_SDK_HOME` / `HOS_SDK_HOME`、`NODE_HOME` / PATH 指向安装路径及 ohpm、hvigor、JDK；先确认 `flutter doctor -v` 能识别它们。不要伪造 SDK 元数据绕过检查。
2. **先用 `flutter create --platforms ohos` 在另一独立目录创建空白工程，完成空白 HAP 构建、开发签名及真机启动。** 这样能区分工具链问题和本项目依赖问题。
3. 重新执行 `prepare_probe.py`，去掉 `--dart-only`；默认产品的目标及兼容版本由 `toolchain.json` 决定（当前 `26.0.0`），可用 `--target-sdk` 为新生成工程指定已安装且支持当前嵌入层的版本。当前核心库也以 API 26 编译，因此实验包不承诺旧系统兼容；不要直接照抄上游仅针对引擎的运行最低版本。已有工程的本机 SDK/签名选择不会被脚本反复覆盖；调整时在 DevEco 检查 `ohos/build-profile.json5`，不能把最低系统版本设得低于原生库编译所需 API。
4. 在 DevEco 打开 `build/harmonyos/probe/ohos`，按官方流程配置本机开发签名。未签名构建命令为 `flutter build hap --release --no-codesign --target-platform ohos-arm64`；构建成功不等于可安装，实际安装/运行使用 DevEco 或 `flutter run -d <设备>` 的已签名流程。
5. 点击 `Run core checks`，保存第一次报告；强制停止进程，不清数据，重新启动后再运行，保存第二次报告。相同进程不提供重跑按钮；不得把数据库关闭重开当作杀进程恢复通过。不要导入个人收藏、账号或漫画源，只使用探针自建的沙箱测试数据。

探针检查 QuickJS 运算 / Promise / Dart 回调 / ArrayBuffer / 异常 / 反复创建释放；rhttp / FRB 的本机 HTTP/1.1 字节、流、重定向、取消；SQLite 的提交、回滚、FTS5、关闭重开与跨进程标记。整个原生检查在独立 isolate 中执行，崩溃、提前退出或超时不能转为成功；超时会停止 worker，本进程不再重试。卡住的原生线程不保证能被 Dart 立即中断，仍需强制停止进程并检查设备日志。

复制的 JSON 不主动包含个人路径、凭据或设备标识，失败只记录类型及受控检查名称。分享设备诊断日志前仍需人工脱敏。即使探针全部通过，HTTPS 证书 / DNS / HTTP2 / HTTP3、现有 `IsolateQjs` 包装层、内存长期回收、WebView、系统插件以及真实阅读/下载流程仍未验证。
