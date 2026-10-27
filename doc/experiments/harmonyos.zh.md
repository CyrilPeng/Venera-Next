# HarmonyOS 独立分支实验

## 范围与决策

- 分支精确命名为 `HarmonyOS`，从 `e634d887e14a7c3daaa5fbb2bc439ce5115d9192` 开始；鸿蒙改动不合入 `main` 或 `android-tv`。
- 采用 Flutter OH SDK，尽可能复用当前 Flutter / Dart 阅读器、漫画源接口和存储格式。不以社区 ArkTS 重写版替换主工程，也不把某个 fork 的 debug HAP 当作本分支验证结果。
- 先验证工具链与核心依赖，再接入已有阅读器。不通过静默 stub、忽略插件异常、关闭证书校验或直接访问正式数据来制造“已适配”的结果。
- 本文是实验记录，不是发布日期或平台支持承诺；#77 仍未交付，本轮不关闭 issue，也不发布安装包。

## 2026-10-27 已完成

| 项目 | 实际结果 | 不能据此推断 |
|---|---|---|
| 独立 Flutter OH SDK | `3.41.9+ohos-1.0.2` / Dart `3.11.5` 启动成功，固定提交 `62357a93d653bf844f730bb1f4b7cc9e2139d14e` | 未替换主工程 SDK；不代表 HAP 构建成功 |
| 空白 OHOS 模板 | `flutter create --platforms ohos --no-pub` 成功 | 未完成签名、安装或启动 |
| 公开 Native SDK | 官方 OpenHarmony 6.0 下载包 SHA-256 已核对，内部 Native 组件 `6.0.0.47-Beta1` / API 20 | 不是商业 HarmonyOS SDK，也不是 API 21 验证 |
| rhttp / FRB | 沿用现有 Cargo.lock 与 FRB `2.11.1`，`aarch64-unknown-linux-ohos` release 编译成功 | 未验证设备加载、网络及 TLS |
| QuickJS | 当前自有 fork 固定提交的 C/C++ 核心编译成功 | 未验证 OHOS 加载、Dart 回调和现有 IsolateQjs 包装层 |
| SQLite | 同一份官方 `3.52.0` amalgamation 编译成功，保留 FTS5 / RTREE / SESSION 等既有开关 | 未验证设备落盘、重启恢复或旧数据迁移 |
| 原生静态审计 | 四个 AArch64 ELF 的动态依赖、关键 FFI 符号和 SHA-256 通过检查 | ELF 检查不能替代设备 ABI / 安全策略验证 |
| 隔离探针 | 可生成固定依赖的 Flutter OHOS 工程；静态分析无问题，Python 10 项与 Flutter 宿主回归 9 项通过（含 3 项 Windows 原生探针逻辑测试） | 宿主测试不运行 OHOS ELF，不属于鸿蒙真机通过 |
| HAP 构建尝试 | `flutter build hap --release --no-codesign --target-platform ohos-arm64 --no-pub` 因缺少完整 Hmos SDK 退出 | 没有 HAP，也没有可安装的阅读器 |

构建摘要保存于 [harmonyos-native-20261027.json](data/harmonyos-native-20261027.json)，原始本机输出在忽略的 `build/harmonyos-bootstrap/`，完整构建报告和库在 `build/harmonyos/native/`。所有版本、官方地址及源码校验值以 [toolchain.json](../../tool/harmonyos/toolchain.json) 为准，复现步骤见[探针说明](../../tool/harmonyos/README.md)。

## 当前阻碍

本机没有 DevEco / 商业 HarmonyOS SDK、ohpm、hvigor，也没有连接鸿蒙真机。公开 Native SDK 足以做本次交叉编译，但当前固定 Flutter OH 的工程生成/打包阶段需要 Hmos SDK，不能用改名目录、伪造组件元数据或改工具源码来代替。

新增仅运行于 `HarmonyOS` 的 GitHub Actions 云端尝试，先空白 HAP、再核心库商业 SDK 重编译与探针 HAP；不要求本机安装完整 SDK。Cocos API 21 与 SDL API 24 CLI 均已通过下载校验和安装，但空白工程因 Flutter 嵌入层所需接口不存在而失败，不能通过修改目录、删减接口或关闭检查来绕过。HAR 的旧编译元数据不足以确定完整接口兼容，现对齐 Flutter OH 发布说明要求的 `26.0.0` 编译基线，使用社区 CI 的 `26.0.0.851` / API 26 镜像，固定 GitHub 资产大小及 SHA-256 后重建完整 ZIP。它不是华为官方分发或官方校验值，不宣称已完成官方供应链认证。真实组件元数据与各阶段结果由构建证据保存。流程不使用签名凭证、不生成 Release，未签名包不能视作可安装阅读器。详见[云端说明](../../tool/harmonyos/README.md#github-actions-云端尝试)。

本机开发签名、安装和真机测试仍需完整 DevEco 工具链及设备；若官方渠道下载或模拟器需要登录，应由维护者完成账号流程。本轮不读取浏览器凭据、不申请或生成维护者的签名凭证。API 20 原生库只作为初步可行性证据，需结合商业 SDK 重新编译和实际设备 ABI 验证，再考虑交付。

## 后续顺序与验收门槛

1. **空白工程及核心依赖**：完成真实 HAP 构建、开发签名和设备启动；三项核心探针均通过，杀进程重启后 SQLite 标记恢复；补充 HTTPS 合法/非法证书、DNS、流取消与原有 QuickJS isolate 生命周期测试。记录系统/API/设备架构与工具链，未通过项不能被平台兜底吞掉。
2. **已有本地阅读器**：审查移动平台识别、App 沙箱、应用生命周期及方向/系统栏策略，最小加载已有阅读器；验证分页/连续/瀑布流、横竖屏、进退阅读器及进度保存。使用专门测试数据，不覆盖现有正式安装。
3. **源到离线闭环**：在合法、可控的测试源中完成源安装 → 搜索 → 详情/章节 → 图片阅读 → 下载 → 杀进程 → 离线重启阅读。验证 JS、网络、数据库在真实业务链路上的协作与取消收尾，而非仅看首页能打开。
4. **系统能力逐项接入**：WebView/登录、文件选择/权限、导入导出/分享、唤醒/通知/后台、归档/PDF、WebDAV。每个插件记录实际可用平台、维护来源、最低 SDK 和许可证；无等价能力时明确禁用并解释，不伪报成功。
5. **实验包与合并决策**：上述核心闭环和正式平台回归通过后再考虑受控测试包；仍需审核签名、唯一应用标识、备份与迁移边界、依赖维护成本及 CI。没有维护者批准不合并主线、不标记正式平台支持、不以发布或无反馈自动关闭 #77。

仅保留一个 Flutter / Dart 业务实现。鸿蒙专用改动应集中在平台入口、原生构建与可测试适配层；不复制一套业务源码，不改变 `android-tv` 的构建目标，也不要求其他平台升级到实验 SDK。
