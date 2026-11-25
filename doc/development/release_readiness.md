# 发布流程与当前验收

本页维护发布规则和当前验收入口。逐版本的构建过程、失败重试及旧决策通过 Git 历史检索，不继续累积为日常发布步骤。平台环境见[构建指南](build.zh.md)，鸿蒙来源与设备政策见[鸿蒙发布指南](harmonyos_releases.zh.md)。

## 当前公开版本

- 本轮正式版本为 [v1.18.4（1.18.4+253）](https://github.com/CyrilPeng/Venera-Next/releases/tag/v1.18.4)，汇总 RC1–RC3 与后续反馈修复；以该标签的[完整构建](https://github.com/CyrilPeng/Venera-Next/actions/workflows/main.yml)和公开资产核验结果确认交付，不能把分支测试包改名为正式包。
- #178 的 Android 120 Hz 阅读及 #188 的目录切换已由原提出者确认；#129、#152 已有可安装修复且超过 72 小时未收到新失败反馈，按维护者约定接受。超时接受与真机明确确认分别记录。
- #166 强 Cloudflare／TLS 兼容问题与 #186 原设备更新检查网络故障因证据不足暂缓，不声明已修复；白边裁剪的扫描痕迹／压缩灰点边界见[诊断指南](reader_diagnostics.md#设备复现与验收)。#159 长期目录见[实施条件](harmonyos_releases.zh.md#长期外部漫画目录)，#163、#81、#123 的新增功能继续暂缓。
- 鸿蒙改为[独立 Actions Beta](https://github.com/CyrilPeng/Venera-Next/actions/workflows/harmonyos-release.yml)，普通正式 Release 不附 HAP。仍为 ARM64／API 26 未签名包，`signed: false`、`runtime_verified: false`；构建、来源核验和下载不替代设备签装、真实授权、冷启动或同密钥升级。历史 RC3 的[完整 CI 与 24 项资产](https://github.com/CyrilPeng/Venera-Next/actions/runs/43778233475)保留。

## 准备同一来源

1. 完成改动与 CHANGELOG，核对干净、已提交的来源。应用版本、构建号、`release.json`、安装器及根锁保持一致。
   发布分支先演练并完成修正，按内容整理提交后合入主分支；最终标签重新执行同一套门禁与正式构建。已公开标签、来源和附件保持原样。
2. 在发布前运行版本、结构、架构、依赖与测试清单检查。普通平台使用根 Flutter／Dart／Rust 锁，鸿蒙使用固定独立 SDK 和受控覆盖层。
3. 标签必须与发布配置精确匹配。分支手动构建只生成验证产物；新版本从其标签重新构建，验收报告绑定准确源码与实际包。

```text
python .github/scripts/release_version.py --check
python .github/scripts/validate_release.py --build-only
python .github/scripts/check_structure_imports.py
python .github/scripts/check_architecture_dependencies.py
dart tool/check_git_dependencies.dart
python .github/scripts/test_suites.py --strict-imports
```

## 完整 CI 与资产核验

`.github/workflows/main.yml` 先验证元数据，再执行 Quality 和 Security；普通平台 Build 依赖两者，`Verify_Packages` 汇总平台回执，Release 等待全部必需结果。`distribution: independent_beta` 明确要求随版 HarmonyOS 任务跳过；历史或显式 `bundled` 配置仍要求该任务成功。普通平台失败、元数据缺失或分发状态不符均不能公开。保留完整 Flutter 分片、覆盖率汇总、Windows／TV、JVM／Swift、原生 ABI／sanitizers、真实 Provider 及脚本门禁。

安全扫描使用固定 cargo-audit 与每次新拉取的 RustSec 数据库，先准备完整锁定依赖的 registry 索引，再冻结漏洞库执行扫描；依赖下载、索引查询或漏洞库查询失败直接阻止发布。报告记录原提交、锁文件摘要、数据库提交、漏洞计数和扫描时间，有效期为 24 小时；草稿等待或原包恢复超期时重新扫描原锁文件，通过后继续使用原包。PR 历史扫描通过不能替代本次发布门禁。

核对 Android 手机／TV 各 ABI、Windows、macOS、iOS、Linux x64／ARM64。资产名称、数量、大小、上传状态和 SHA-256 均与本次构建清单一致，另核验包内版本、包身份和 APK 签名／ABI。独立 Beta 的 HAP、manifest、校验附件及设备模板留在其 Actions 运行中，继续验证 ELF 导出、NOTICE 与准确来源摘要；禁止将 HAP 或鸿蒙设备报告混入普通正式版。

普通安装包统一使用 `.github/scripts/release_assets.py`：各平台在可读取实际包的原生运行器上检查内容，再生成 `release-receipt-*`。Android 手机／TV 使用原签名清单；Windows 核对便携包并保留真实安装启动检查；macOS 挂载只读 DMG，iOS 读取 IPA；Linux 使用 libarchive 读取 zstd DEB、RPM、Arch，并解包 AppImage 的真实内容。版本与源码资源从准确 Git blob 读取，DEB 保持既有安装目录，ARM64 字体变换和编码路径逐项核验。回执绑定源码提交、版本、构建号、运行号及实际文件摘要；汇总必须包含配置推导的完整附件和全部平台回执，不能用当前目录里的文件反推“应有附件”。

发布源码 checkout 与输出目录分开，生成安装说明、解包或下载不污染受审查来源。GitHub 草稿通过鉴权列表与 Release ID 查找；草稿期不依赖仅返回公开版本的 tag 查询。公开前重新读取并核验准确草稿与全部附件，公开后重新下载核验实际资产。

完整构建的手动 `mode=build` 完成全部构建与包核验，仅保留 Actions 产物；`mode=rehearsal` 使用 `rehearsal-<run_id>-<attempt>` 命名的内部草稿验证真实上传、GitHub 文件名转换和下载回读，始终禁止公开与渠道同步。开启 `rehearsal_interrupt` 后，第一个附件上传完成即返回约定的中断状态，由第二个进程读取绑定原提交、清单摘要及资产 ID 的回执恢复上传，确认已有资产未替换。最终按准确草稿 ID 清理，已公开、来源不符或不属于本次运行的 Release 不能被演练清理。

正式发布将 `release-verification.json` 随包上传，长期记录提交、版本、运行号、安全扫描和普通平台资产摘要；回执附件与配置推导的普通资产清单分别列出。缺失附件只能补传相同原构建文件，已有附件冲突立即停止。公开前及公开后都回读实际文件；已经公开但复核失败时只执行复核，不再次发布或替换资产。AltStore 从正式标签完整构建成功后推进，Winget 收录仍以微软审核为准。

## 设备报告与稳定渠道

普通正式版按已提交的 `independent_beta` 配置分发，鸿蒙另行验收。当前主线采用 `runtime_acceptance: optional`，以后切换随版时，正式版和候选版都可在缺少真机报告时发布或恢复草稿；仍保留未签名 Beta 及未完成真机验收标记，源码、版本、原生库和包体摘要核验继续强制执行。主动上传的失败或无效报告仍阻止通过。历史随版鸿蒙 schema 3 的 `stable_required` 允许无设备报告的候选版公开，包含 HAP 的正式版必须有准确 HAP 的合格验收。恢复流程读取原构建提交中的策略，不用当前配置豁免旧版本，历史 schema／`required` 按原政策恢复。

独立设备模板最初全部为 `not_run`，绑定源码、版本、构建号和未签名原 HAP SHA-256。启动、来源／阅读、归档与目录导入、下载、备份导出／导入、同密钥覆盖升级、冷重启及 UI／能力按真实结果填写。报告不含账号、设备标识或签名材料，由有权限的维护者核验并上传；后续重跑保留原构建资产，未签装或未执行的项目不能填为通过。

稳定版在对应发布门禁和资产核验完成后推进更新渠道、AltStore 和 Winget；RC 仅在 Release 手动下载，鸿蒙独立 Beta 从 Actions 下载。Winget 收录以 Microsoft 审核为准。修复提供可安装包后，72 小时无新失败反馈按约定接受；证据不足、没有可验收修复或有明确失败的问题不能套用超时通过。通知只对应本次实际交付，已有充分反馈不重复索取。

## 证据保留与恢复

长期保留来源／版本、CI run、资产摘要、签名／来源核验、设备报告和通知回执。本地安装包副本、下载 SDK、编译缓存和临时工程可在验收完成后清理，报告先另存；普通安装包及平台核验回执的 CI artifacts 保留 30 天，测试日志按各工作流的保留策略清理。

`resume-release.yml` 先核实原标签运行，再扫描其准确原锁文件；新增必需任务从原提交的 `.github/release-policy.json` 读取，没有该文件的历史运行沿用原门禁，不要求当时不存在的核验任务。发布步骤与原发布按同一标签串行，使用原产物和原清单恢复。源码、依赖或实际打包输入发生变化时重新构建验证；上传和分发故障分别恢复对应阶段。每次运行的 Summary 分别报告门禁结果，详细交付与演练回执保留 30 天，日常规则只维护本页。

旧测试整理、依赖审计、Issue 快照、平台实验和历史操作的原始资料保存在 [v1.18.4-rc.3 文档树](https://github.com/CyrilPeng/Venera-Next/tree/v1.18.4-rc.3/doc)。冻结鸿蒙来源与恢复标签见[历史来源](harmonyos_releases.zh.md#历史来源与恢复)。代码回滚按普通 revert 恢复同组源码、配置与锁，独立安全修复保留；回退安装前另存备份并核对数据兼容与原签名身份。
