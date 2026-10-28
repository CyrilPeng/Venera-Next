# HarmonyOS 核心依赖探针

仅用于 `HarmonyOS` 实验分支。复用主工程固定的 Dart / Rust / QuickJS / SQLite 依赖，不是 ArkTS 重写，也不是完整阅读器版本。当前结果及后续门槛见[实验记录](../../doc/experiments/harmonyos.zh.md)。

## GitHub Actions 云端尝试

`.github/workflows/harmonyos-experiment.yml` 仅在 `HarmonyOS` 分支的相关构建文件更新或手动触发时运行，使用临时 Ubuntu runner，不依赖维护者本机 SDK、不访问签名密钥、不创建 Release、不更新应用版本。

此前 Cocos API 21 和 SDL API 24 CLI 均完成下载校验、安装和空白工程尝试，但当前固定 Flutter OH 嵌入层引用了旧 SDK 缺少的接口，ArkTS 编译失败。HAR 中的旧编译元数据不能作为完整 ArkTS 接口兼容的依据；当前 Flutter OH 发布说明要求以 `26.0.0` 编译。现使用[社区 CI 镜像](https://github.com/zhongdaiqi/command-line-tools-for-hmos/releases/tag/clt-26.0.0.851)的 CLI `26.0.0.851` / API 26，并以 GitHub Release 资产摘要固定两个原始分片的大小和 SHA-256。先逐片校验、再按固定顺序拼接 ZIP，并记录完整包摘要；不伪造 SDK 目录或元数据，不删减引擎接口，也不关闭 ArkTS 检查。

这不是华为官方分发地址或官方校验值，完整镜像的真实性仍基于第三方维护者和下载时的 GitHub 资产记录；哈希固定用于防止后续内容静默变化，不表示已完成官方供应链认证。CLI 分发参考保存在 `toolchain.json`。商业 API 26 云端基线与下文公开 API 20 本机基线严格分开。

首次 API 26 运行已确认真实 Native 组件版本为 `26.0.0.105`，空白包、核心库编译、探针分析与 6 项宿主回归均通过；探针 HAP 编译完成后，由于自动 strip 改写库字节而被严格哈希检查拒绝。现固定组件版本和重建 ZIP 的完整 SHA-256，并关闭探针模块的自动 strip 后重新验证；不能把被审计拒绝的那次运行称为全流程成功。

云端依次构建空白 ARM64 未签名 HAP，再以同一商业 SDK 重编译四个核心库，生成并分析／回归测试隔离探针，最后构建探针 HAP。探针模块关闭打包阶段的自动 strip，保留已审计原生库的原始字节；打包检查会核对 AArch64 ELF、四个库是否真正入包及其精确哈希，拒绝缺库、内容变化和空包。证据与日志保留 14 天；仅全流程成功才上传 `harmonyos-unsigned-lab-haps-*` 测试产物。

Actions 的 `packaging_pass` 只表示未签名打包及静态审计通过，不是完整阅读器、不代表可直接安装，也不代表原生库真机加载、运行或数据恢复通过。社区测试按下文小白签装指南完成；DevEco 保留为开发者本机调试备选，不要求普通测试者安装完整 SDK。不要将 CI 编译成功作为关闭 #77 的依据。

## 小白签装与升级探针

社区实验采用 Kazumi 的“unsigned HAP + 用户本地小白调试助手”路线；先验证现有探针，尚不接入完整阅读器。用户操作、账号与安全边界、失败处理见[中文签装指南](../../doc/distribution/harmonyos.zh.md) / [English guide](../../doc/distribution/harmonyos.en.md)。不要求普通测试者安装 DevEco，不在 CI 保存签名材料，也不声称免开发者账号或永久免续签。

云端在 baseline `0.2.0+2` 之后构建 upgrade `0.2.1+3`，保持探针包名不变。两包携带相同源/原生库配对标识，导出前核对真实 `module.json`、嵌入标识、API 26 与原生库哈希，生成 `sideload-manifest.json`、`SHA256SUMS` 及离线安装指南。只有整条流程成功才提供测试包，仍不创建 Release。宿主测试生成的合成数据不属于真机验收。

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

默认 Flutter 回归运行 6 项、跳过 3 项原生宿主逻辑测试。在 Windows 上已有主工程编译产物时，可将当前终端的 `HARMONYOS_PROBE_HOST_LIBDIR` 指向含 `rhttp.dll`、`sqlite3.dll`、`flutter_qjs_plugin.dll` 的构建目录，并将该目录加到本进程 PATH，再执行同一测试命令。这样共运行 9 项，可检查探针逻辑本身；加载的是 Windows DLL，绝不计为 OHOS ELF 运行通过。原生宿主测试会在系统临时目录保留一份很小的合成 SQLite fixture，便于诊断，不读取应用数据。

测试源码以 `.template` 保存，避免被主工程的 Dart 分析当成已接入的平台代码；生成工程、库、日志和签名信息都不进版本控制。脚本会覆盖生成工程中的探针源码；签名、SDK 等本机配置不要放进模板。Dart 依赖使用独立锁文件，不修改主工程 `pubspec.yaml` / `pubspec.lock`。

## DevEco / 真机阶段

1. 安装完整 DevEco 工具链，使用当前终端的 `DEVECO_SDK_HOME` / `HOS_SDK_HOME`、`NODE_HOME` / PATH 指向安装路径及 ohpm、hvigor、JDK；先确认 `flutter doctor -v` 能识别它们。不要伪造 SDK 元数据绕过检查。
2. **先用 `flutter create --platforms ohos` 在另一独立目录创建空白工程，完成空白 HAP 构建、开发签名及真机启动。** 这样能区分工具链问题和本项目依赖问题。
3. 重新执行 `prepare_probe.py`，去掉 `--dart-only`；默认产品的目标及兼容版本由 `toolchain.json` 决定（当前 `26.0.0`），可用 `--target-sdk` 为新生成工程指定已安装且支持当前嵌入层的版本。当前核心库也以 API 26 编译，因此实验包不承诺旧系统兼容；不要直接照抄上游仅针对引擎的运行最低版本。已有工程的本机 SDK/签名选择不会被脚本反复覆盖；调整时在 DevEco 检查 `ohos/build-profile.json5`，不能把最低系统版本设得低于原生库编译所需 API。
4. 在 DevEco 打开 `build/harmonyos/probe/ohos`，按官方流程配置本机开发签名。未签名构建命令为 `flutter build hap --release --no-codesign --target-platform ohos-arm64`；构建成功不等于可安装，实际安装/运行使用 DevEco 或 `flutter run -d <设备>` 的已签名流程。
5. 点击 `Run core checks`，保存第一次报告；强制停止进程，不清数据，重新启动后再运行，保存第二次报告。相同进程不提供重跑按钮；不得把数据库关闭重开当作杀进程恢复通过。不要导入个人收藏、账号或漫画源，只使用探针自建的沙箱测试数据。

探针检查 QuickJS 运算 / Promise / Dart 回调 / ArrayBuffer / 异常 / 反复创建释放；rhttp / FRB 的本机 HTTP/1.1 字节、流、重定向、取消；SQLite 的提交、回滚、FTS5、关闭重开与跨进程标记。整个原生检查在独立 isolate 中执行，崩溃、提前退出或超时不能转为成功；超时会停止 worker，本进程不再重试。卡住的原生线程不保证能被 Dart 立即中断，仍需强制停止进程并检查设备日志。

复制的 JSON 不主动包含个人路径、凭据或设备标识，失败只记录类型及受控检查名称。分享设备诊断日志前仍需人工脱敏。即使探针全部通过，HTTPS 证书 / DNS / HTTP2 / HTTP3、现有 `IsolateQjs` 包装层、内存长期回收、WebView、系统插件以及真实阅读/下载流程仍未验证。
