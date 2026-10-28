# HarmonyOS 实验签装与升级验证

English: [HarmonyOS Experimental Sideload Checks](harmonyos.en.md)

> 仅适用于 `HarmonyOS` 分支的诊断探针，不是 Venera-Next 阅读器发行版。当前未完成小白签装、真机运行、覆盖升级或证书续签验收；不要用 CI 成功代替这些结果。主线正式版和 Android TV 不受影响，#77 仍保持未交付。

## 方案与当前范围

参考 [Kazumi 安装教程](https://kazumi.app/docs/misc/how-to-install-in-ohos)，项目构建并提供未签名 HAP，用户使用[小白调试助手](https://github.com/likuai2010/auto-installer)以自己的账号完成授权、签名和安装。用户不需要下载源码、自行编译或安装 DevEco；但开发者账号、调试授权和签名有效期并未因此消失。项目不提供逐台代签服务。

- 首轮验证 ARM64 鸿蒙手机，Windows 电脑作为辅助设备；macOS 为后续验证路径。小白 README 提及的平台不等于每次 Release 都提供相应安装包。
- 2026-10-28 核对的小白最新公开 Release 是 [3.1.0](https://github.com/likuai2010/auto-installer/releases/tag/3.1.0)，提供 Windows、macOS、HarmonyOS 包。本项目未安装或全面审计该第三方工具。
- **当前探针最低 SDK 为 `26.0.0`，HAP 中最低/目标 API 编码为 `260000026`。** 这是现有实验包的限制，不是所有 Flutter 鸿蒙应用的普遍下限；不能仅凭设备的营销系统名称推断可安装，也不能照抄 Kazumi 的兼容范围。若设备不满足要求，应先反馈并评估降低运行基线，不改元数据强装。
- 保持 Flutter/Dart 业务实现，后续在 `HarmonyOS` 分支接入现有阅读器；小白只解决分发签装，不解决插件、后台、文件或阅读器适配。卓易通仍可作为 Android 兼容运行的备用路径，两者不是同一测试。

## 获取测试包

维护者先在 `HarmonyOS` 分支运行 `HarmonyOS Experimental HAP` 工作流。仅全流程成功时，运行页 Artifacts 才提供 `harmonyos-unsigned-lab-haps-<run_id>`，保留 14 天；下载 Actions 产物可能需要 GitHub 登录。此阶段不创建公共 Release，不把探针附加到主线版本。

解压同一次运行的测试包，包含：

| 文件 | 用途 |
|---|---|
| `harmonyos-blank-arm64-unsigned.hap` | 首次工具链/签装排查用的空白应用 |
| `harmonyos-probe-baseline-arm64-unsigned.hap` | 基线探针 `0.2.0+2`，创建合成数据 |
| `harmonyos-probe-upgrade-arm64-unsigned.hap` | 升级探针 `0.2.1+3`，只验证已存在的基线数据 |
| `sideload-manifest.json` | 包名、版本、源提交、配对标识、最低 SDK、原始 HAP 摘要 |
| `SHA256SUMS` | 基线/升级原始 HAP 的 SHA-256 |
| `install.zh.md` / `install.en.md` | 本说明的离线副本 |

两份探针的原始包名均为 `com.github.cyrilpeng.harmonyos_probe`，与 Android 正式应用及未来完整鸿蒙应用隔离。不要将空白应用当作基线探针，也不要混用不同运行/不同配对标识的包。CI 逐包读取 HAP 内 `module.json` 和内嵌构建标识，检查真实包名、递增版本与最低/目标 API，并复核原生库字节和导出文件摘要，而非只看文件名。

下载后可以用 PowerShell 核对原始 HAP：

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\harmonyos-probe-baseline-arm64-unsigned.hap
Get-FileHash -Algorithm SHA256 -LiteralPath .\harmonyos-probe-upgrade-arm64-unsigned.hap
```

与同一包内 `SHA256SUMS` 对照。摘要用于检查原始包，不是来源真实性的独立担保；请从本项目运行页获取。用户重签名后包体会变化，不应再拿重签后的 HAP 与原始摘要比较。

## 首次准备与空白包验证

1. 从小白官方仓库下载 Windows 助手；按其要求准备 Java。请勿安装来历不明的修改版。
2. 在目标鸿蒙手机开启开发者选项与无线调试，在可信网络中按工具提示连接/授权。不同系统的菜单可能不同，以实际设备和工具文档为准。
3. 按 Kazumi/工具指引准备用户自己的华为开发者账号。用户亲自在可确认的华为官方页面登录和授权，不向维护者提交密码、验证码、Token、私钥、证书口令或 UDID。
4. 选择空白 unsigned HAP，确认工具显示的包与设备要求，由小白签名安装。先确认应用能打开，再进行探针对照。
5. 若安装被拒绝，保留错误阶段、脱敏错误码、设备/系统/助手版本，不通过关闭签名检查、修改包名或清理正式数据绕过问题。完成测试后关闭不再需要的无线调试连接。

首次准备需要辅助设备。助手的鸿蒙客户端本身也需要先通过其他平台安装，不能宣传“只有一台全新鸿蒙手机就能从零完成”。本项目不内置或重新分发助手，不接管其登录流程。

## 基线、重启与覆盖升级

全程只操作独立探针，**不要导入真实漫画源、收藏、账号或下载数据**。

1. **基线**：通过小白安装 baseline HAP，核对页面 `baseline / 0.2.0+2` 与配对标识。点击 `Run core checks`，等待结束；`Sideload data` 应为 `baseline_ready`，三项核心检查应通过。点击 `Copy report`，保存完整 JSON 为 `baseline.json`。
2. **重启**：强制停止探针进程，不清数据，再次打开并运行检查。数据仍为 `baseline_ready`，`process_restart` 应通过，总状态应为 `core_checks_pass`。另存 `restart.json`。仅在原进程中重复运行、切到后台或关闭/重开数据库不算强制停止。
3. **覆盖升级**：不要卸载探针或清数据。保持原有签名身份/密钥，通过小白安装配对的 upgrade HAP，打开后核对 `upgrade / 0.2.1+3`。运行检查，数据应为 `upgrade_data_present`，核心及重启检查通过，另存 `upgrade.json`。
4. 记录设备型号、完整系统版本、助手版本、测试时间、安装/升级方式，以及工具是否保持包名、是否出现签名不匹配或卸载提示。**同一个账号或助手，不保证一定使用同一把签名密钥。** 不要把私人签名包或签名材料上传到 issue。

合成标记只在 baseline 首次成功创建；upgrade 缺少标记时返回 `missing_baseline`，不补写；其他配对或损坏状态返回 `pair_mismatch` / `invalid_state`，不覆盖原数据。核心检查通过不能抵消这些失败。

三份报告需来自同一配对及三个独立启动，保留相同合成标记和首次启动标识。忘记保存首次报告、前次失败或已有不同配对时，不要伪造报告或手工编辑标记；先记录原因。确需重新开始时，只在明确知晓会删除**独立诊断探针合成数据**的前提下重置探针，再完整重做；这不是正式阅读器的数据恢复方案。

## 维护者复核

维护者取得用户自愿提供且人工检查过的最小报告后，在仓库执行：

```powershell
python tool/harmonyos/review_sideload.py --manifest <测试包中的sideload-manifest.json> --baseline <baseline.json> --restart <restart.json> --upgrade <upgrade.json>
```

工具只把 JSON 当数据读取，不下载附件、不执行报告内容。输入不完整、宿主平台冒充、核心失败、重复启动标识、换包/换配对、标记丢失或重建都会拒绝通过。`reported_checks_pass` 只表示报告中的核心、进程重启和合成升级数据检查一致，不是硬件远程证明，也不验证证书/签名密钥、续签、完整阅读器或真实数据迁移。

独立测试者复现成功后，再决定进入完整阅读器接入。记录脱敏的结论、设备范围和失败项即可；不要把用户报告全文、设备标识或凭据提交到仓库。公共截图和日志仍需用户先人工脱敏。

## 续签、后续更新与发布门槛

- 不统一承诺 14/180 天或一年；证书、Profile 与其他测试规则是不同对象，以实际有效期和平台政策为准。
- 按助手支持方式在用户本地妥善保存签名材料。更新证书不等于更换密钥；同签名覆盖升级通过也不等于过期续签已经通过。
- 换签或续签后遇到覆盖失败，应先保留数据并检查原因。不要默认卸载重装；完整阅读器必须先具备可靠备份/恢复与迁移说明。
- 首个阅读器 Alpha 先提供手动下载后交给助手的更新路径；应用内下载与助手文件交接另行验证，不猜测 URI scheme，不承诺静默更新。
- 只有源到离线闭环、WebView/文件/备份及升级验收满足约定范围后，才考虑公开阅读器 Alpha。使用独立 `harmonyos-*` 标签、Pre-release、非 Latest，另行验证不会触发现有 `v*` 发布或污染主线更新选择。当前不创建这些标签或发布任务。
- 所有代码提交前同步更新 CHANGELOG，采用中文约定式提交。#77 不因 CI 成功、发包或暂时无反馈自动关闭。
