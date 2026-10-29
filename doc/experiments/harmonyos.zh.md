# HarmonyOS 独立分支实验

## 范围与决策

- 分支精确命名为 `HarmonyOS`，从 `e634d887e14a7c3daaa5fbb2bc439ce5115d9192` 开始；鸿蒙改动不合入 `main` 或 `android-tv`。
- 采用 Flutter OH SDK，尽可能复用当前 Flutter / Dart 阅读器、漫画源接口和存储格式。不以社区 ArkTS 重写版替换主工程，也不把某个 fork 的 debug HAP 当作本分支验证结果。
- 先验证工具链与核心依赖，再接入已有阅读器。不通过静默 stub、忽略插件异常、关闭证书校验或直接访问正式数据来制造“已适配”的结果。
- 本文是实验记录，不是发布日期或平台支持承诺；#77 仍未交付，本轮不关闭 issue，也不发布 Release 或正式安装包。CI 仅保留短期未签名实验产物。

## 2026-10-27 本机初步验证

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

## 2026-10-27 云端完整构建通过

[Actions 运行 40479827996](https://github.com/CyrilPeng/Venera-Next/actions/runs/40479827996) 在 `HarmonyOS` 提交 `14f978e446e19d1ed0238a828956d1f8da6e21bb` 上全流程成功。运行于临时 Ubuntu 24.04 runner，不依赖维护者本机的 HarmonyOS SDK。下载后的两个 HAP 另行完成整包 SHA-256、包内 ELF／原生库哈希、原生编译报告及源码／构建指纹复核，也未使用本机 SDK。

| 阶段 | 实际结果 | 边界 |
|---|---|---|
| 完整 CLI / SDK | CLI `26.0.0.851`、API 26 Native `26.0.0.105`；两个分片及完整 ZIP 的大小／SHA-256 已固定并校验 | 第三方社区 CI 镜像，不是华为官方来源认证 |
| 空白 ARM64 HAP | `harmonyos-blank-arm64-unsigned.hap`，20,627,191 字节，构建与包体检查通过 | 未签名、未安装／启动 |
| 核心原生库 | rhttp／FRB、QuickJS、SQLite 以同一 API 26 SDK 全量重编译；四个库的 AArch64 ELF、动态依赖和关键 FFI 导出检查通过 | 不等于设备加载、网络或落盘行为通过 |
| 分析与宿主回归 | Python 17 项通过；探针分析无问题；Flutter 6 项通过、3 项可选原生宿主测试跳过 | 不将跳过项或 Linux 宿主回归算作 OHOS 原生运行 |
| 核心探针 ARM64 HAP | `harmonyos-probe-arm64-unsigned.hap`，30,079,595 字节；四个库入包字节与审计报告完全一致 | 不是完整阅读器，也不是可直接安装的包 |

产物与日志在该运行页的 Artifacts 中保留 14 天，HAP 产物名为 `harmonyos-unsigned-lab-haps-40479827996`。永久保留的精简结果、整包／原生库校验值与来源见 [harmonyos-ci-20261027.json](data/harmonyos-ci-20261027.json)；本地下载与复核文件位于忽略的 `build/harmonyos-ci-research/run-40479827996/`。没有创建 Release、配置签名或更改应用版本，`main` 和 `android-tv` 不受影响。

排错中确认 API 21 和 API 24 缺少当前嵌入层使用的 ArkTS 接口；HAR 的旧编译元数据不足以判断完整接口兼容，最终对齐固定 Flutter OH 发布说明的 API 26 编译要求。首次 API 26 探针虽编译出 HAP，仍因自动 strip 改写库字节而被审计拒绝；关闭探针模块自动 strip 后才通过完整复核，未删减引擎接口、伪造 SDK 元数据、关闭 ArkTS 检查或放宽哈希校验。详见[云端构建说明](../../tool/harmonyos/README.md#github-actions-云端尝试)。

## 2026-10-28 小白社区签装方案落地

`HarmonyOS` 已同步 `main` 的 `ce57c66`，包含 `8bf22f0`（`1.18.2-rc.2+238`）基线及其后的阅读器缓存键修复与回归（#125），主线和 `android-tv` 不变。社区原生包选择“项目构建未签名 HAP，用户通过小白调试助手本地签装”，卓易通保留为 Android 兼容运行的备用路径。先用独立探针验证分发，不立即把完整阅读器标为已适配；同步阅读器源码不等于探针已经覆盖主阅读器性能或原设备复测。

- 准备同包名的 baseline `0.2.0+2` / upgrade `0.2.1+3`，内嵌配对、源提交和版本标识；CI 审计实际 HAP 元数据、API 26、原生库和导出摘要，生成操作指南及配对清单，不使用签名材料、不创建 Release。
- baseline 创建独立沙箱合成标记，upgrade 只检查原标记；缺失、损坏或配对不符不补写、不覆盖。报告分开呈现核心检查和数据保留，不将前者算作签装/升级验收。
- 三份报告覆盖首次运行、强制停止后重启、同签名覆盖升级；离线复核拒绝宿主冒充、缺项、混包、重复启动和数据标记变化。工具只核对报告，不证明签名身份、证书续签或真实漫画数据迁移。
- 首轮需要满足当前最低 API 的真实手机，以及由用户亲自完成的账号登录和调试授权。安装、运行、覆盖升级、续签与独立用户复现目前均未验收；不自动降低兼容版本，不关闭 #77。
- 本地 Python 23 项、Flutter 宿主 13 项通过，3 项可选原生宿主测试跳过，探针静态分析无问题；包含窄屏大字号、横屏操作及合成升级状态回归。本地准备复用了已核对整包／原生库摘要和当前源码指纹的历史云端 API 26 产物，不冒充本轮原生重编译或 OHOS 设备运行；依赖按原锁文件从 `pub.dev` 缓存离线解析，不更改主工程依赖。

详细步骤见[中文签装指南](../distribution/harmonyos.zh.md) / [English guide](../distribution/harmonyos.en.md)。本轮先完成测试套件和云端打包验证；真机结果到位后再进入现有阅读器接入。

## 2026-10-28 主线同步后的签装套件云端验证

合并提交 `6f212fdeec47d32f99c3251b81c3d4f2374653e5` 完整包含 `main` 的 `ce57c66`。[Actions 运行 40696828912](https://github.com/CyrilPeng/Venera-Next/actions/runs/40696828912) 于北京时间 21:38 完成，结论为 `success`；不是以合并前的运行替代本轮验证。

| 检查 | 实际结果 | 验证边界 |
|---|---|---|
| 工具链与原生库 | 固定 CLI `26.0.0.851` / Native `26.0.0.105`，重新编译并审计四个 ARM64 核心库 | 第三方镜像未作官方来源认证；未在设备加载 |
| 脚本与探针回归 | Python 23 项通过；baseline、upgrade 各分析无问题、Flutter 宿主 13 项通过、3 项跳过 | Linux 宿主回归不是 OHOS 真机运行 |
| 主线修复本地回归 | 定向图片代理／滚动 25 项及相关阅读器集成 199 项通过，变更 Dart 分析无问题 | 集成测试使用已有 Windows DLL；不代表 #125 原 Android 设备已复测 |
| 空白 unsigned HAP | `harmonyos-blank-arm64-unsigned.hap`，20,627,191 字节 | 仅签装排查对照，不是 baseline |
| baseline unsigned HAP | `harmonyos-probe-baseline-arm64-unsigned.hap`，30,113,126 字节，`0.2.0+2` | 未签名、未安装／启动 |
| upgrade unsigned HAP | `harmonyos-probe-upgrade-arm64-unsigned.hap`，30,113,125 字节，`0.2.1+3` | 未验证同签名覆盖升级或数据保留 |
| 下载后独立复核 | 三包大小／SHA-256、实际包名／版本／API、配对／源码指纹、原生报告及库字节、清单／SHA256SUMS／中英文指南均一致 | 静态检查不证明签名身份、设备行为或证书续签 |

两份探针实际包名为 `com.github.cyrilpeng.harmonyos_probe`，共享配对标识 `b467df52dcc545d76bfb0e7a003dc369b1b3712270234bff477087ada7800f13`。三包实际 `deviceTypes` 均仅为 `phone`，最低／目标 SDK 均为 `26.0.0`，不承诺平板、PC 或旧系统兼容。

精简证据与完整校验值归档于 [harmonyos-sideload-ci-20261028.json](data/harmonyos-sideload-ci-20261028.json)。本地原始证据、日志及测试套件保存在忽略的 `build/harmonyos-sideload-20261028/run-40696828912/`；Actions 产物 `harmonyos-unsigned-lab-haps-40696828912` 保留 14 天，包含三份 HAP、配对清单、摘要和离线指南。结果记录提交仅更新文档；本节实际核验的构建源提交是 `6f212fd`。

下一步仍由测试者按指南亲自完成小白账号授权、空白包签装、baseline 首次运行、强制停止重启和同签名覆盖 upgrade，提供三份最小合成报告后再复核。当前没有签名、真机或续签结果，没有接入完整阅读器，也未创建 Release 或关闭 #77。

## 2026-10-29 自愿平板测试验证与交接

[#77 的自愿反馈](https://github.com/CyrilPeng/Venera-Next/issues/77#issuecomment-6472701935)确认设备为 MatePad Pro 13.2（2024），系统 `7.0.0.111 SP12`，已安装小白调试助手鸿蒙版 `3.1.0`。只记录其公开提供的兼容信息，不收集账号、证书或设备唯一标识。

[华为官方升级指南](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/upgrade-adaptation)说明 HarmonyOS 7.0 对应 API `26.0.0`，与当前固定 CLI／SDK 相符；具体补丁版本、安装及运行仍需本人设备验证，不能据此填写真机已通过。当前不降低最低 API，不要求用户升级／刷机，也不把用户已安装其他应用当成本探针可用的证明。

- 空白包和两份探针均声明且审计实际 `phone`／`tablet` 目标，拒绝仅手机、缺失、重复或扩大到 PC／TV 的入包设备类型；配对清单、内嵌标识和离线报告同步核对目标范围。
- 新配对为 baseline `0.3.0+4`／upgrade `0.3.1+5`，不混用旧 `0.2.x` 包或不同源提交。合成状态从构建标识读取基线版本，缺少版本或原数据／配对不符时拒绝通过，不伪造迁移。
- 沿用既有响应式探针布局，覆盖平板竖屏、横屏、分屏、大字号及旋转后报告复制和启动标识保持；宿主模拟复制的失败报告不属于 OHOS 核心运行结果。
- 中英文指南区分“已经安装鸿蒙端小白”和“从零准备”的路径：前者无需重装助手或添加 Windows／Java／DevEco；从同一次构建取得 ZIP，解压后选择原始 HAP，空白包先行，遇签名不匹配、卸载提示或不兼容则停止并反馈。

[Actions 运行 40790980474](https://github.com/CyrilPeng/Venera-Next/actions/runs/40790980474) 于北京时间 08:08 完成，源码为 `ef2904f2e67cda61e1d61978ae3623b5bc01dbfd`，全流程结论为 `success`。本轮从头编译原生库和三份 HAP，不以历史产物替代本轮云端验证。

| 检查 | 实际结果 | 验证边界 |
|---|---|---|
| 脚本与探针回归 | Python 25 项通过；baseline、upgrade 各分析通过、Flutter 宿主 17 项通过、3 项可选测试跳过 | 宿主布局／复制回归不等于平板原生运行；未重跑上一轮主阅读器 224 项回归 |
| 工具链与目标审计 | 固定 CLI `26.0.0.851` / Native `26.0.0.105`；四个 ARM64 核心库重新编译；三包实际 `deviceTypes` 均精确为 `phone`／`tablet`，最低／目标 API 均为 `260000026` | 只表示声明和包体通过检查，不证明具体系统补丁可签装或启动 |
| 空白 unsigned HAP | `harmonyos-blank-arm64-unsigned.hap`，20,627,218 字节 | 用于先排查签装与启动，不是诊断探针 |
| baseline unsigned HAP | `harmonyos-probe-baseline-arm64-unsigned.hap`，30,113,234 字节，`0.3.0+4` | 未签名、未安装／启动 |
| upgrade unsigned HAP | `harmonyos-probe-upgrade-arm64-unsigned.hap`，30,113,233 字节，`0.3.1+5` | 未验证同签名覆盖升级、合成数据保留或证书续签 |
| 下载后独立复核 | 三包大小／SHA-256、实际包名／版本／设备类型／API、内嵌配对／源码、原生报告／库字节、清单／SHA256SUMS／中英文离线指南均一致 | 静态复核不是签名身份或真机运行证明 |

两份探针的包名仍为 `com.github.cyrilpeng.harmonyos_probe`，配对标识为 `15269ae323f7c4131fdf88c2faf767a5e7e2bc6b60030a4c9453cd904308a250`。[本轮测试套件](https://github.com/CyrilPeng/Venera-Next/actions/runs/40790980474/artifacts/12861798036)需登录 GitHub 下载，保留至北京时间 2026-11-12 08:08；不得与旧配对混用。永久保留的精简证据及完整校验值见 [harmonyos-tablet-ci-20261029.json](data/harmonyos-tablet-ci-20261029.json)，本地原始证据与下载复核结果位于忽略的 `build/harmonyos-tablet-20261029/run-40790980474/`。本次结果记录提交仅更新文档，实际二进制的构建源仍为 `ef2904f`。

下载复核通过后，已在 [#77 测试交接回复](https://github.com/CyrilPeng/Venera-Next/issues/77#issuecomment-6484190474)向自愿反馈者 `@caiweihan` 提供本轮套件、固定提交的中文指南、配对标识及步骤：沿用鸿蒙端小白，先只签装和启动空白包；成功后再依次进行 baseline 首次运行、强制停止后重启、同签名覆盖 upgrade，提供三份最小合成 JSON 报告。API 不符、签名不匹配或出现卸载提示时停止并反馈，不以卸载重装绕过，不导入真实漫画、收藏或账号，也不公开证书、密钥、设备唯一标识或私人签名 HAP。

目前状态是“已交接，等待设备结果”，不是原作者验收或完整阅读器交付。本阶段不发布 Release，#77 保持开放；收到实际报告后再分别复核签装、核心运行与数据保留，不能以无反馈认定通过。

## 待完成的真机验证

云端已解决完整工具链及未签名 HAP 构建问题。本机仍没有 DevEco、开发签名环境或连接的鸿蒙真机，尚未完成安装、进程启动、原生库加载及探针运行。当前实验包的编译、目标与最低系统版本均为 `26.0.0`；核心库也以 API 26 构建，不承诺上游引擎单独标注的旧系统最低兼容范围。

社区签装按小白指南由测试者亲自完成账号授权和设备连接，不要求普通用户安装 DevEco。开发者需要深度调试时仍可选择本机官方工具链；若官方渠道下载或模拟器需要登录，应由维护者完成账号流程。本轮不读取浏览器凭据、不申请或生成维护者的签名凭证，也不把第三方镜像的固定哈希当作官方供应链认证。当前仍未接入已有阅读器、系统插件或真实漫画源闭环。

## 后续顺序与验收门槛

1. **空白工程及核心依赖**：为已通过云端构建的空白包和核心探针完成官方开发签名、安装和设备启动；三项核心探针均通过，杀进程重启后 SQLite 标记恢复；补充 HTTPS 合法/非法证书、DNS、流取消与原有 QuickJS isolate 生命周期测试。记录系统/API/设备架构与工具链，未通过项不能被平台兜底吞掉。
2. **已有本地阅读器**：审查移动平台识别、App 沙箱、应用生命周期及方向/系统栏策略，最小加载已有阅读器；验证分页/连续/瀑布流、横竖屏、进退阅读器及进度保存。使用专门测试数据，不覆盖现有正式安装。
3. **源到离线闭环**：在合法、可控的测试源中完成源安装 → 搜索 → 详情/章节 → 图片阅读 → 下载 → 杀进程 → 离线重启阅读。验证 JS、网络、数据库在真实业务链路上的协作与取消收尾，而非仅看首页能打开。
4. **系统能力逐项接入**：WebView/登录、文件选择/权限、导入导出/分享、唤醒/通知/后台、归档/PDF、WebDAV。每个插件记录实际可用平台、维护来源、最低 SDK 和许可证；无等价能力时明确禁用并解释，不伪报成功。
5. **实验包与合并决策**：上述核心闭环和正式平台回归通过后再考虑受控测试包；仍需审核签名、唯一应用标识、备份与迁移边界、依赖维护成本及 CI。没有维护者批准不合并主线、不标记正式平台支持、不以发布或无反馈自动关闭 #77。

仅保留一个 Flutter / Dart 业务实现。鸿蒙专用改动应集中在平台入口、原生构建与可测试适配层；不复制一套业务源码，不改变 `android-tv` 的构建目标，也不要求其他平台升级到实验 SDK。
