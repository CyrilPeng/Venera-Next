# 发布流程与当前验收

本页维护发布规则和当前验收入口。逐版本的构建过程、失败重试及旧决策通过 Git 历史检索，不继续累积为日常发布步骤。平台环境见[构建指南](build.zh.md)，鸿蒙来源与设备政策见[鸿蒙发布指南](harmonyos_releases.zh.md)。

## 当前公开版本

- 稳定渠道为 [v1.18.3](https://github.com/CyrilPeng/Venera-Next/releases/tag/v1.18.3)。最新候选为 [v1.18.4-rc.3（1.18.4-rc.3+252）](https://github.com/CyrilPeng/Venera-Next/releases/tag/v1.18.4-rc.3)，源码为 `266177d6ad5790bcb9854f4e8fdbbab093fdee7f`。
- [该标签的完整 CI](https://github.com/CyrilPeng/Venera-Next/actions/runs/43778233475)通过。24 项公开资产已下载并核验摘要，八个 APK 的签名／版本／ABI，以及 Windows、iOS 和鸿蒙包内版本与来源均已核验。
- 鸿蒙仍为 ARM64／API 26 未签名 Beta，`signed: false`、`runtime_verified: false`。构建、来源核验和公开安装包不替代设备签装、真实授权、冷启动或同密钥升级。
- RC3 已通知 #180、#167、#152、#178 对应测试。#139 的特定 JPEG、#129 的本地封面残留继续按[诊断指南](reader_diagnostics.md#设备复现与验收)定位；#159 长期目录见[实施条件](harmonyos_releases.zh.md#长期外部漫画目录)。#163、#81、#123 的新增功能继续暂缓。

## 准备同一来源

1. 完成改动与 CHANGELOG，核对干净、已提交的来源。应用版本、构建号、`release.json`、安装器及根锁保持一致。
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

`.github/workflows/main.yml` 先验证元数据，再执行 Quality；普通平台 Build 和 HarmonyOS 均依赖 Quality，Release 等待全部必需结果。保留完整 Flutter 分片、覆盖率汇总、Windows／TV、JVM／Swift、原生 ABI／sanitizers、真实 Provider 及脚本门禁。

核对 Android 手机／TV 各 ABI、Windows、macOS、iOS、Linux x64／ARM64、鸿蒙 HAP 与其 manifest／来源／安装说明／校验附件。资产名称、数量、大小、上传状态和 SHA-256 均与本次构建清单一致，另核验包内版本、包身份、APK 签名／ABI、ELF 导出、NOTICE 与鸿蒙来源摘要。

发布源码 checkout 与输出目录分开，生成安装说明、解包或下载不污染受审查来源。GitHub 草稿通过鉴权列表与 Release ID 查找；草稿期不依赖仅返回公开版本的 tag 查询。公开前重新读取并核验准确草稿与全部附件，公开后重新下载核验实际资产。

## 设备报告与稳定渠道

鸿蒙 schema 3 的 `stable_required` 允许无设备报告的候选版公开，正式版必须有准确 HAP 的合格验收；已有失败或无效报告均阻止通过。历史 schema／`required` 按原政策恢复，不追改旧标签。

独立设备模板最初全部为 `not_run`，绑定源码、版本、构建号和未签名原 HAP SHA-256。启动、来源／阅读、归档与目录导入、下载、备份导出／导入、同密钥覆盖升级、冷重启及 UI／能力按真实结果填写。报告不含账号、设备标识或签名材料，由有权限的维护者核验并上传；后续重跑保留原构建资产，未签装或未执行的项目不能填为通过。

稳定版在设备与发布门禁完成后推进更新渠道、AltStore 和 Winget；RC 仅在 Release 手动下载。Winget 收录以 Microsoft 审核为准。通知只对应本次实际交付和新增验收条件，已有充分反馈不重复索取；Issue 是否完成依据实际反馈及适用范围判断。

## 证据保留与恢复

长期保留来源／版本、CI run、资产摘要、签名／来源核验、设备报告和通知回执。本地安装包副本、下载 SDK、编译缓存和临时工程可在验收完成后清理，报告先另存；CI artifacts 目前保留 14 天。

旧测试整理、依赖审计、Issue 快照、平台实验和历史操作的原始资料保存在 [v1.18.4-rc.3 文档树](https://github.com/CyrilPeng/Venera-Next/tree/v1.18.4-rc.3/doc)。冻结鸿蒙来源与恢复标签见[历史来源](harmonyos_releases.zh.md#历史来源与恢复)。代码回滚按普通 revert 恢复同组源码、配置与锁，独立安全修复保留；回退安装前另存备份并核对数据兼容与原签名身份。
