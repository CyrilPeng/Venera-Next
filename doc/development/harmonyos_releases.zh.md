# 鸿蒙主线构建与发布

阅读器和鸿蒙平台适配统一在 `main`。普通平台使用根 `pubspec.yaml`／`pubspec.lock` 与官方 Flutter；鸿蒙使用同仓库 `tool/harmonyos/` 中固定的 Flutter OH SDK、CPF 插件覆盖、独立锁模板、ArkTS 桥接和原生构建配置。生成工程位于 `build/harmonyos/full-app`，应用运行源码与调用方的 canonical Git blob 一致。

## 同一提交的来源约束

构建号至少为 245 的主线使用 schema 3 的 `.github/harmonyos-next.json`：`source_mode: release_commit`。配置不保存自身 commit SHA，也不解析浮动分支名；选择器从调用方 checkout 的 HEAD 得到完整 SHA，第二个构建 checkout 必须精确相等。运行上下文记录相等的 `source_commit`／`release_commit`、版本、构建号、Actions run ID 和 changelog 摘要。

PR 校验使用 Actions 的准确合并候选 SHA，push 和手动构建使用准确主线 SHA，与普通 Flutter 工作流的来源一致。两个 checkout 的未提交、暂存和未跟踪输入均被拒绝；普通业务修复无需同步另一条开发分支或修改共同基线。

`.github/workflows/harmonyos-experiment.yml` 监听主线相关源码、依赖、工具和发布配置变化，复用 `harmonyos-release.yml` 的完整阅读器构建。保持独立 SDK 目录、受控 OH lock、原生交叉编译、严格分析、宿主回归、真实 API 26 HAP、完整资产及原生导出审计。生成器仅修改生成工程与下载后的覆盖层，不修改官方 Flutter、共享 Pub cache 或主线根锁。

## 冻结的 244 与随版分发

244 的 schema 1 `.github/harmonyos-release.json`、固定 Git 输入和历史资产保留。`harmonyos-frozen-244` 归档标签保留原来源的可达性；`harmonyos-branch-final-245` 保存最后一次双分支候选。后续开发只使用 `main`。旧 schema 2 解析保留用于历史验证，当前主线使用 schema 3。

维护者于 2026-11-07 明确要求此后每次发包都包含鸿蒙版，主线配置已启用 `release_enabled: true`。候选版和正式版均必须重新构建同提交的未签名 ARM64 测试版 HAP，并携带全部五项鸿蒙分发资产；不能只发布其他平台。发布开关在标签元数据阶段检查，禁用时立即阻止整次发布。

开关授权的是经过源码、构建及资产审核的未签名测试版分发。它不表示设备签装、覆盖升级或功能验收已完成；manifest 中的 `signed: false`、`runtime_verified: false` 与安装指南继续准确记录验证范围。schema 2／3 的预览或未绑定实际 tag 的产物均拒绝 Release 验证，归档标签也不会触发 `v*` 发布。

源码及八个项目包摘要使用已提交的 canonical Git blob；七个受管原生库、PNG／7z 导出、第三方 NOTICE 和全部应用资产继续参与审计。适用的 QuickJS 核心修复固定到 `f5a1f20`，历史来源见[依赖实施记录](official_dependency_implementation_20261107.zh.md)。

## 版本与产物

发布工作流校验调用方的 Git 提交、版本、构建号、运行号及 changelog 摘要。只有独占生成工程被写入调用方版本，源 checkout 不被改写。原生版本名为三段数字，Dart 版本保留 RC 后缀；构建号沿用主线并递增。第一个公开的主线随版 HAP 为 `v1.18.3-rc.3`，构建号 **248**；RC1／RC2 保留已构建的标签与 Actions 记录，均未公开 Release。主线 schema 3 的首个允许构建号为 245，旧 244 来源只保留历史验证；不回填 `v1.18.2` 等旧 Release。

正式版 `v1.18.3` 使用构建号 **249**，与其他平台从同一正式版提交重新构建；候选验收产物不重命名为正式包。正式版仍随包提供未签名 Beta HAP 和四项伴随文件，继续保留尚未完成的鸿蒙真机签装、阅读、真实数据升级与续签验收边界。

每次发布必须包含：

- `VeneraNext-版本-harmonyos-arm64-unsigned.hap`
- `harmonyos-manifest.json`
- `harmonyos-SHA256SUMS`
- `harmonyos-install.zh.md`
- `harmonyos-install.en.md`

HAP 采用 `com.github.cyrilpeng.veneranext.harmony` 包名和 `VeneraNext (HarmonyOS Beta)` 显示名，最低／目标 SDK 为 API 26。复核真实 `module.json`、AArch64 ELF、原生库精确摘要、完整 Dart／资源源码清单和包内版本，安装指南来自准确构建提交。下载页须继续明确未签名及测试版身份，不能把编译通过说成真机升级或续签验收。

## 发布门禁与无发布验证

完整构建的 `Release` 同时依赖 Quality、原平台 Build 与 HarmonyOS。HAP 缺失、内容损坏、源码过期或摘要错误都不得 `continue-on-error`。先创建草稿并上传，再从 GitHub API 核对全部五项鸿蒙资产的名称、大小、上传状态和 SHA-256；通过后才公开，公开后再复核一次。任一阶段失败须查看日志，不允许静默去掉鸿蒙包后继续。

GitHub 按标签查询的 Release 接口只返回已公开版本。草稿阶段使用鉴权发布列表的完整分页定位唯一同标签草稿，再按其数字 ID 重新读取附件；缺失、重名、状态或 ID／标签变化都停止发布。公开后改用标签接口复核，创建 Release 时显式绑定调用方源码 SHA。RC2 的 26 项附件已上传为草稿，但旧查询接口返回 404；本修复由 RC3 重新验证完整发布链路。

发布任务的两个源码 checkout 位于工作区的 `release-source/` 与 `harmonyos-source/`；说明和产物分别位于同级的 `release_notes.md` 与 `outputs/`。脚本从 `release-source/` 执行，全部生成输入留在源码目录外，两个 Git checkout 仍须通过未跟踪与未提交输入检查。

`HarmonyOS Release HAP` 的分支手动运行和目标主线的 PR 运行只产出下一候选的 Actions artifacts，不创建标签或 Release；主线相关 PR／push 使用同一候选流程核验普通平台与鸿蒙的准确源码 SHA。常用检查：

```bash
python3 -m unittest discover -s .github/scripts/tests -p test_harmonyos_release.py -v
python3 .github/scripts/harmonyos_release.py config
python3 .github/scripts/harmonyos_release.py config --preview-next
gh workflow run harmonyos-release.yml --ref main
```

平台脚本与 SDK 基线见主线的 `tool/harmonyos/README.md`。商业 API 26 SDK 从受摘要固定的社区 CI 镜像获取，不冒充官方校验；主线脚本不会读取签名密钥。安装与不支持的功能见[用户指南](../distribution/harmonyos-reader.zh.md)。本流程不评论、关闭、重开或跟踪 issue。
