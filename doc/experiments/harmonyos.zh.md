# HarmonyOS 独立分支实验

## 2026-10-29 首包反馈后的批量导入适配

[@caiweihan 的实际使用反馈](https://github.com/CyrilPeng/Venera-Next/issues/77#issuecomment-6497355819)确认首包在目录导入时弹出明确的“不支持”提示，逐个导入压缩包效率低；本人同时表示其他功能暂未发现问题。该反馈只记录其使用范围，不等于其他设备、迁移、功耗或续签验收。首包未接入目录，不将其归因于用户操作或签名。

- 已合入 `main` 的 `b8be017`（rc.3）基线；全部新增适配仅在 `HarmonyOS`。第二包独立版本为 `1.18.2-harmony.2+2`，原生 `1.18.2.2+2`，包名／最低与目标 API 不变。
- 目录选择先核实 `FolderSelection` 系统能力，再用 `DocumentSelectMode.FOLDER` 取单个目录 URI。URI 保留在原生内存，不转换成任意文件路径；Dart 收到独占目录回执并登记归属后才触发 `fileIo.copy(uri, sandboxUri)`。系统接口接受目录 URI，并将原目录复制到已存在的目标目录，原目录名及章节层次必须保留，否则不交给导入器。只有目标 URI 来自应用自建路径。
- 复用 `DirectorySelection`／`SelectionOperation` 及既有漫画复制事务；临时副本不能 `retainAccessForSession`，鸿蒙目录和 EhViewer 导入强制复制到漫画库。取消后迟到的选择不开始复制，进行中的复制／消费完成后才收尾；失败保留同一回执供清理重试，不重新复制或重复登记。清理只接受本次 token／路径／inode 对应的独占根，不遍历源目录，不跟随副本中的链接。
- 多归档直接使用系统文件多选，复用既有导入与逐文件失败汇总，不再依赖目录能力；部分成功保留，全部失败不报成功。界面不提供“不复制”开关，说明系统能力不足／权限／空间错误及批量归档替代方式；PDF 导入仍不支持并禁用入口。
- API 26 的目录选择能力需以该设备实际实现为准，不能用 SDK 枚举或云端编译代替平板实际使用。当前参考[系统文件选择指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/select-user-file)和[文件 IO 接口](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-file-fs)，公开 API 20 仅作本机接口预检，不用来推断 API 26 手机／平板支持范围。
- 回归覆盖实际 ArkTS 桥的宿主执行、目录与归档导入／重启、取消／失败／归属／链接保护，以及中英文使用说明和窄屏、横屏大字号的既有风格界面。宿主测试不是真机验收；完整 HAP 仍经新一轮云端构建、下载后精确审计再提供，不使用首包或旧探针替代。
- 本机 Python 34 项、真实桥接宿主 11 项、完整应用所选 Windows 宿主 388 项通过，改动文件分析与架构／导入边界检查通过；另以本机预览字体复查 375 窄屏、1200 暗色平板和 812 横屏 1.8 倍字号，三个界面用例通过。移除帮助按钮的固定宽度以免大字体溢出，不改主题或其他平台的导入方式。以上不计为鸿蒙真机结果。
- `5487373` 的 [40891008790 云端运行](https://github.com/CyrilPeng/Venera-Next/actions/runs/40891008790)全流程成功，完整分析通过，Linux 宿主 356 项通过／32 项按既有平台条件跳过；下载后核对 549 个源码摘要、十个库及离线指南通过。但收尾发现 `main` 刚新增 `9201bcc` 的 #126 批量归档结果／重试修复，因此该中间产物未对外分发；先合并新主线，保留两组翻译并扩展归档回归门禁，再以新运行复核后的包交付，未交付的 `harmony.2` 版本不重复递增。
- 合并后重新准备隔离工程，新增归档批量结果／传输／翻译、CBZ 导入生命周期及鸿蒙桥接／导入相关的本机定向回归共 103 项通过，Python 34 项和架构／导入边界检查通过；云端完整分析、完整所选测试与实际 HAP 审计仍以合并后的新运行结果为准。

## 2026-10-29 改为完整应用日常试用

#77 反馈者明确表示不希望反复验证探针，维护者决定直接推进完整应用实验包，遇到实际使用问题再反馈。本轮不再请求四步报告，先前合成数据复核的边界不变，也不将其作为完整阅读器已验收的证据。

- 构建目录为忽略的 `build/harmonyos/full-app`，入口直接复制现有 `lib/main.dart` 和全部阅读器/源/收藏/下载/同步代码、资产，依赖路径保留项目中的包；没有另写精简阅读器，也不替换主工程依赖锁或版本。
- 完整应用使用独立包名 `com.github.cyrilpeng.veneranext.harmony` 与 `1.18.2-harmony.1+1`，采用原工具链 API 26。SQLite 默认加载器的隔离覆盖适用于后台 isolate；rhttp 明确加载 OHOS 核心库；PNG、ZIP、7Z 重编译锁定原生源码，内嵌网页固定 CPF OHOS WebView 提交。
- 增加真实沙箱路径、系统文件 URI 到应用临时副本、消费结束后的收尾、系统保存与保持亮屏。保留备份导入/导出、CBZ/ZIP/EPUB 和下载后的沙箱漫画；外部长期目录/自定义存储、系统分享、生物认证、PDFium 导入与 Android 专属能力明确未支持。PDF 的既有 Dart 导出保留。
- Actions 在原空白/核心流程后增加完整应用分析、选定宿主回归、全库重编译与完整 HAP 审计，单独导出 `harmonyos-reader-experiment-运行号`。成功后方可交付该产物，失败产物不分发；本段是实施范围，具体成功运行与摘要后续单独归档，不以旧探针构建代替。

日常使用/签装说明见[中文指南](../distribution/harmonyos-reader.zh.md) / [English guide](../distribution/harmonyos-reader.en.md)。仍只在 `HarmonyOS` 分支，不创建稳定 Release、不关闭 #77，不要求账号、证书或私人数据。

## 2026-10-29 首个完整阅读器实验包交付

源码 `8b6f79690d9cd6f18e07dd547798b42b85375f4c` 完整包含 `main` 的 `ce57c66`。[Actions 运行 40825892150](https://github.com/CyrilPeng/Venera-Next/actions/runs/40825892150) 于北京时间 14:07 完成，全流程 `success`。这是实际编译现有 `lib/main.dart` 的阅读器，不是此前探针；只提供独立实验包，不发布稳定 Release。

| 检查 | 实际结果 | 边界 |
|---|---|---|
| 依赖与工具链 | 固定 Flutter OH、CPF WebView 与 API 26 CLI／Native 组件，隔离依赖锁通过 | 不修改主工程依赖锁或版本 |
| 分析与回归 | Python 34 项通过；完整应用分析无问题；Linux 宿主 256 项通过／32 项按既有平台条件跳过；另有 Windows 宿主 288 项通过 | 宿主回归不等于 OHOS 真机功能验收；Windows 使用现有真实宿主 DLL |
| 原生库 | 四个核心库、PNG／ZIP／7Z 及 WebView N-API 辅助库以 API 26 重新编译，精确核对入包哈希 | 不用 Android／Linux 二进制替代 OHOS 库 |
| 完整 HAP | `venera-next-1.18.2-harmony.1-arm64-unsigned.hap`，44,575,167 字节 | 未签名，签装由用户自己的小白环境完成 |
| 实际元数据 | 包名 `com.github.cyrilpeng.veneranext.harmony`，原生 `1.18.2.1+1`，最低／目标 API `260000026`，设备类型精确为 `phone`／`tablet` | 应用内 Dart 版本 `1.18.2-harmony.1+1`；不承诺其他系统／设备兼容 |
| 下载后独立复核 | 清单与 CI 证据一致；549 个源文件摘要与构建提交一致，十个 ARM64 ELF、八个自建库的系统依赖／必要导出及哈希、声明资产和离线指南均通过 | 没有设备安装、运行、真实数据恢复或续签证明 |

原始 unsigned HAP 的 SHA-256 为 `ea4c8cd088bdd460010c0ab84829912befc1ed1b6d4631aa77fe4ef96035a0bd`。[完整阅读器下载](https://github.com/CyrilPeng/Venera-Next/actions/runs/40825892150/artifacts/12877310791)需登录 GitHub，保留至北京时间 **2026-11-12 14:06:47**；内含 HAP、清单、`SHA256SUMS` 及双语指南，勿与旁边的诊断套件混用。永久校验记录见 [harmonyos-full-reader-ci-20261029.json](data/harmonyos-full-reader-ci-20261029.json)；本地完整证据与包保存在忽略的 `build/harmonyos-full-app-20261029/run-40825892150/`。

构建收尾中修正了 ArkTS 命名参数／异常兼容及原生数字版本。包体审计还发现当前 Flutter OH 将 OHOS hook 输入标为 Linux，曾误带 Linux PDFium；现由隔离工程显式 hook 配置阻止，应用 PDF 导入保持明确拒绝，成功 HAP 已确认没有 PDFium。WebView 的真实 N-API 辅助源码纳入同批原生编译，不通过扩大未审库名单或降低哈希要求放行。应用更新入口也与主线安装包隔离，不把 APK Release 误提示为 HAP 更新。

已在 [#77 完整包交接回复](https://github.com/CyrilPeng/Venera-Next/issues/77#issuecomment-6489394128)按反馈者意愿提供下载和小白安装说明，正常使用、出现问题再反馈，**不再要求四步探针、JSON 报告或私人附件**。独立沙箱不会自动继承安卓版或探针数据，迁移前保留原备份／漫画；PDF 导入、外部长期目录、自定义存储、系统分享、生物认证与 Android 专属能力仍未交付。#77 保持开放，不将云端成功、旧平板探针结果或本轮交接当作完整应用真机验收。

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

交接时状态是“已交接，等待设备结果”，不是原作者验收或完整阅读器交付。本阶段不发布 Release，#77 保持开放；实际报告到位后按下节单独复核，不能以无反馈认定通过。

## 2026-10-29 首台平板报告复核

自愿反馈者 `@caiweihan` 于北京时间 09:35 在 [#77 新回复](https://github.com/CyrilPeng/Venera-Next/issues/77#issuecomment-6485441224)报告四步均成功，附上 baseline、restart、upgrade 三份最小 JSON 和升级阶段截图，并提醒配置文件、本地漫画等文件管理适配。该反馈者不是原 issue 作者。

维护者仅将附件作为 JSON 数据下载、人工检查并交给 `review_sideload.py`，结果为 `reported_checks_pass`。报告均匹配 `ef2904f`、本轮配对、`0.3.0+4`／`0.3.1+5` 及 `phone`／`tablet`；内嵌原生构建版本、四库摘要和源码指纹也与已下载复核的云端记录一致。

| 阶段 | 实际证据 | 范围 |
|---|---|---|
| 空白包 | 本人报告通过小白签装和启动 | 没有独立探针 JSON 或维护者现场观察，不认证签名身份 |
| baseline | `baseline_ready`，QuickJS／rhttp／SQLite 均通过，`core_pass_restart_pending` | 首次启动的待重启状态符合预期，不算失败，也不提前算进程恢复通过 |
| 强制停止后重启 | 不同启动标识，合成标记和首次启动标识保持；`process_restart` 及 `core_checks_pass` | 复核报告中的跨进程恢复；不是所有生命周期或后台行为验收 |
| 覆盖 upgrade | 第三个启动，`upgrade_data_present`，合成标记不变；核心和进程恢复均通过 | 仅合成数据保留，不证明签名密钥、过期续签或真实应用数据迁移 |
| 升级截图 | 可见 `upgrade / 0.3.1+5`、正确配对和通过状态，与报告一致 | 不能据此宣称横竖屏、分屏、大字号均已真机测试 |

本轮重跑 Python 工具回归 25 项通过；另用真实报告的副本验证宿主平台、换配对、标记变化、重复启动、缺失／待重启结果、核心失败、漏配平板和 fatal 事件九类输入均被拒绝。未改动复核工具或探针代码，不将这些检查新增计入此前 Flutter 宿主测试数量。

脱敏结论、报告摘要、公开来源和复核边界保存于 [harmonyos-tablet-device-review-20261029.json](data/harmonyos-tablet-device-review-20261029.json)；原始报告和截图仅在忽略的 `build/harmonyos-tablet-20261029/device-feedback-6485441224/`，不提交全文、启动标识或合成标记。历史 CI 记录仍保持“静态构建不验证设备”的原结论，设备反馈另行归档，不反写原构建结果。

已在 [#77 复核回复](https://github.com/CyrilPeng/Venera-Next/issues/77#issuecomment-6486795892)感谢测试并说明通过范围，将文件管理列为下一阶段重点。暂不要求重复相同四步，不请求真实配置、漫画、签名包或凭据；后续先准备独立沙箱和自制小文件。单台自愿报告可支持继续实验，不等于远程硬件认证、全平台支持、原作者验收或完整阅读器交付；#77 保持开放，无 Release。

## 下一阶段文件交互验收

代码审查确认当前 `_App.isMobile` 仅识别 Android／iOS，`file_interaction.dart` 对其他平台会进入既有 `file_selector` 路径；Android 文档选择／SAF 和 Apple 授权目录都有单独分支，不能直接当作鸿蒙能力。应用数据导入已经通过 `selectFile`、独立缓存副本和事务日志处理，本地漫画入口也复用文件／目录选择。鸿蒙适配应接入这些边界，不能复制另一套导入业务、直接把外部 URI 当磁盘路径或伪报插件可用。证据入口见 [平台识别](../../lib/foundation/app.dart)、[文件交互](../../lib/foundation/file_interaction.dart)、[应用数据设置](../../lib/features/settings/app.dart)和[本地漫画导入](../../lib/features/local_comics/import_export/import_comic.dart)。

下表是下一阶段计划，不是已实现功能或新发包内容。先核实当前 API 26 的真实文件选择／访问接口和插件来源，再在 `HarmonyOS` 的独立沙箱中验证：

| 优先项 | 最小测试 | 通过门槛 |
|---|---|---|
| 系统文件选择与授权访问 | 自制小文件，取消、拒绝、不可读／失效授权、不同提供方 | 取得真实可读数据；外部 URI 通过平台访问层处理；明确取消和失败，不申请无关全盘权限 |
| 应用数据导入／导出 | 不含账号或漫画源的合成 `.venera`，导出后重新选择导入并重启 | 复用现有导入格式和事务；内容恢复；损坏／失败不覆盖原状态；外部文件保存真正完成后才报成功 |
| 本地漫画导入与阅读 | 自制图片目录／CBZ，小型中文名、空格名及重名样本 | 沙箱副本和漫画注册一致，导入后及重启后都能用现有阅读器打开；不依赖临时授权继续存在 |
| 临时文件与失败收尾 | 大文件、选择后取消、空间不足、切后台及访问失效 | 有界流式复制；只清理本操作拥有的临时文件；保留外部原文件和原应用数据，不吞错误或留下假成功条目 |
| 目录与后续更新 | 核实系统目录选择和授权保留范围；新包覆盖后检查导入副本 | 不把一次选择等同永久权限；未支持的原地引用／目录能力明确禁用，不擅改包名或用卸载重装绕过升级 |

文件交互边界准备好后再接入已有本地阅读器闭环；PDF／EPUB、系统分享、WebView 和真实备份恢复按各自依赖逐项验证，不因 CBZ 或一个样本通过一并宣布可用。

## 真机结果边界与剩余缺口

云端已解决完整工具链及未签名 HAP 构建问题，首台平板自愿提供的核心运行、重启和合成升级数据报告也已复核通过；维护者本机仍没有 DevEco、开发签名环境或连接的鸿蒙真机，没有独立现场观察或硬件／签名身份认证。当前实验包的编译、目标与最低系统版本均为 `26.0.0`；核心库也以 API 26 构建，不承诺其他设备、旧系统或上游引擎单独标注的兼容范围。

社区签装按小白指南由测试者亲自完成账号授权和设备连接，不要求普通用户安装 DevEco。开发者需要深度调试时仍可选择本机官方工具链；若官方渠道下载或模拟器需要登录，应由维护者完成账号流程。本轮不读取浏览器凭据、不申请或生成维护者的签名凭证，也不把第三方镜像的固定哈希当作官方供应链认证。当前仍未接入已有阅读器、系统插件或真实漫画源闭环。

## 后续顺序与验收门槛

1. **核心依赖剩余验证**：保留首台设备的有限通过记录，补充 HTTPS 合法／非法证书、DNS、现有 QuickJS isolate 包装层生命周期和长期资源回收。设备 API 观察、签名身份与到期续签单独记录；已有小白测试者无需改用 DevEco，不以 loopback HTTP 代替真实网络安全检查。
2. **文件交互与安全导入**：优先按上表核实系统接口并实现窄平台适配，验证文件选择、授权读取、沙箱复制、导入事务、导出完成确认及失败收尾；使用合成配置和自制漫画，不操作正式数据。
3. **已有本地阅读器**：审查移动平台识别、App 沙箱、应用生命周期及方向／系统栏策略，最小加载已有阅读器；完成导入 → 阅读 → 保存进度 → 杀进程 → 离线重启，验证分页／连续／瀑布流及横竖屏。复用现有业务实现，不复制测试版阅读器。
4. **源到离线闭环**：在合法、可控的测试源中完成源安装 → 搜索 → 详情／章节 → 图片阅读 → 下载 → 杀进程 → 离线重启阅读。验证 JS、网络、数据库在真实业务链路上的协作与取消收尾，而非仅看首页能打开。
5. **系统能力逐项接入**：WebView／登录、分享、唤醒／通知／后台、归档／PDF、WebDAV。每个插件记录实际可用平台、维护来源、最低 SDK 和许可证；无等价能力时明确禁用并解释，不伪报成功，不将已有文件小样本扩大为全部系统能力通过。
6. **实验包与合并决策**：上述核心闭环和正式平台回归通过后再考虑受控测试包；仍需审核签名、唯一应用标识、备份与迁移边界、依赖维护成本及 CI。没有维护者批准不合并主线、不标记正式平台支持、不以发布或无反馈自动关闭 #77。

仅保留一个 Flutter / Dart 业务实现。鸿蒙专用改动应集中在平台入口、原生构建与可测试适配层；不复制一套业务源码，不改变 `android-tv` 的构建目标，也不要求其他平台升级到实验 SDK。
