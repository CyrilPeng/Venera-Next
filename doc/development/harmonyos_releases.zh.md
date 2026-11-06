# 鸿蒙随版构建

鸿蒙以独立 `HarmonyOS` 分支、Flutter OH SDK 和锁文件构建完整阅读器，主线仍使用原有工具链。随版 HAP 是 ARM64 手机／平板测试版，不是全面平台支持声明；签名、设备授权和私钥始终留在用户本机。

## 固定来源

`.github/harmonyos-release.json` 保存完整 `source_commit`、共同 `main_baseline` 和 `first_release_build`。两个 checkout 都必须包含共同基线；鸿蒙 checkout 必须精确等于固定提交，不能使用分支名、短 SHA 或工作区改动。

基线之后允许主线调整文档、工作流、发版元数据和 `pubspec.yaml` 的版本行。运行代码、资源、测试、依赖锁或原生工具链变化会阻止随版构建，直到重新同步并审查鸿蒙分支。不要仅修改基线数字绕过同步，也不要将旧 HAP 改名上传。

1. 将公共修复合并进主线与鸿蒙分支，保留共同提交的祖先关系；不要在建立 pin 后用 squash/rebase 丢掉该基线。
2. 验证独立 OH 锁文件、平台宿主回归和真实 HAP 构建，检查平台限制是否改变。
3. 将新的完整鸿蒙 SHA 和共同基线写入 pin，提交 changelog 与必要的安装指南更新。
4. pin／发布工作流变更的 PR 会运行 `HarmonyOS Release HAP`；只有同一候选代码的质量与 HAP 检查通过后才合并。

## 冻结的 244 与下一候选

`1.18.3+244` 继续使用 schema 1 的 `.github/harmonyos-release.json`，其来源、独立锁文件和历史 Release 资产保持冻结。构建号至少为 245 的新版本使用 schema 2 的 `.github/harmonyos-next.json`；禁止回退到旧 pin。两个 pin 都必须来自调用方已提交的 Git 文件。

主线 PR 和分支手动运行使用 `--preview-next`。即使主线仍为 244，预览也使用候选自身的 `1.18.3+245` 版本、构建号和 changelog，并分别保存真实调用方提交、版本、构建号及 Actions run ID。八个项目包按候选 Git 文件计算摘要，七个受管原生库、PNG／7z 导出及生成的第三方 NOTICE 参与完整 HAP 审计。鸿蒙既有的 Rhttp 显式加载接口按其真实平台变体核验。

下一 pin 当前为 `release_enabled: false`。完成[QuickJS 核心审计中的修复](remaining_git_audit_20261106.zh.md)和平台审核前，tag 构建不得启用下一候选分发。预览和未绑定实际 tag 的 schema 2 产物均拒绝 Release 验证；通过预览不会自动改变发布状态。

## 版本与产物

发布工作流校验调用方的 Git 提交、版本、构建号、运行号及 changelog 摘要。只有独占生成工程被写入调用方版本，固定源 checkout 不被改写。原生版本名为三段数字，Dart 版本保留 RC 后缀；构建号沿用主线并递增。第一个包含 HAP 的标签构建号至少为 **244**，不回填 `v1.18.2` 等旧 Release。

每次发布必须包含：

- `VeneraNext-版本-harmonyos-arm64-unsigned.hap`
- `harmonyos-manifest.json`
- `harmonyos-SHA256SUMS`
- `harmonyos-install.zh.md`
- `harmonyos-install.en.md`

HAP 采用 `com.github.cyrilpeng.veneranext.harmony` 包名和 `VeneraNext (HarmonyOS Beta)` 显示名，最低／目标 SDK 为 API 26。复核真实 `module.json`、AArch64 ELF、原生库精确摘要、完整 Dart／资源源码清单和包内版本，安装指南来自固定鸿蒙提交。下载页须继续明确未签名及测试版身份，不能把编译通过说成真机升级或续签验收。

## 发布门禁与无发布验证

完整构建的 `Release` 同时依赖 Quality、原平台 Build 与 HarmonyOS。HAP 缺失、内容损坏、源码过期或摘要错误都不得 `continue-on-error`。先创建草稿并上传，再从 GitHub API 核对全部五项鸿蒙资产的名称、大小、上传状态和 SHA-256；通过后才公开，公开后再复核一次。任一阶段失败须查看日志，不允许静默去掉鸿蒙包后继续。

`HarmonyOS Release HAP` 的分支手动运行和目标主线的 PR 运行只产出下一候选的 Actions artifacts，不创建标签或 Release；鸿蒙分支 PR 使用独立候选流程核验其准确 head。常用检查：

```bash
python3 -m unittest discover -s .github/scripts/tests -p test_harmonyos_release.py -v
python3 .github/scripts/harmonyos_release.py config
python3 .github/scripts/harmonyos_release.py config --preview-next
gh workflow run harmonyos-release.yml --ref main
```

平台脚本与 SDK 基线见 `HarmonyOS` 分支的 `tool/harmonyos/README.md`。商业 API 26 SDK 从受摘要固定的社区 CI 镜像获取，不冒充官方校验；主线脚本不会读取签名密钥。安装与不支持的功能见[用户指南](../distribution/harmonyos-reader.zh.md)。本流程不评论、关闭、重开或跟踪 issue。
