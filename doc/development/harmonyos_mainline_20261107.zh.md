# 鸿蒙统一主线实施记录

日期：2026-11-07。

## 源码与构建

以整理后的 `main`（`7bdfb93e61a0deb18770cc9babe69dad25dd4bb4`）为基础，整合最后一版鸿蒙候选 `ca5f7ef98ec03872d087f0b691e40f0de0080939` 的平台适配、导入生命周期、合集归档、更新提示、ArkTS 桥接、工程模板和回归。本次直接追加主线单父提交，保留此前两条整理记录。

普通平台沿用官方 Flutter、根 `pubspec.yaml`／`pubspec.lock` 和现有官方来源；鸿蒙平台在 `tool/harmonyos/` 固定 Flutter OH SDK、CPF 插件组、受控独立锁、原生构建与审计。生成器复制同一份应用运行源码，仅在生成工程与下载的依赖覆盖层应用平台配置。Rhttp 的可选 `ExternalLibrary` 接口成为共同源码的一部分，普通平台仍采用默认库加载。

主线版本统一为 `1.18.3+245`。根依赖锁、Cargo 锁、QuickJS 固定来源、已发布版本和资产均未因整合而更新。系统分享、PDF 导入、生物认证、外部持久目录等鸿蒙能力边界继续保留。

## 来源与 CI

`.github/harmonyos-next.json` 使用 schema 3 的 `source_mode: release_commit`，从调用方 checkout 的 HEAD 选择完整源码 SHA，拒绝浮动分支名和嵌入自身 SHA。构建 checkout 必须等于调用方 commit，运行上下文记录相等的 `source_commit`／`release_commit`，版本、构建号、run ID 和 changelog 摘要也必须匹配。

两个 checkout 均拒绝未提交、暂存和未跟踪来源。现有 canonical Git blob、八个项目包、七个受管原生库、PNG／7z 导出、第三方 NOTICE、全部应用资产、HAP 元数据和真实 ELF 审计继续执行。旧 schema 1／2 保留历史验证能力；schema 2／3 的预览和未经真实 tag 绑定的产物禁止分发。

鸿蒙候选工作流监听 `main` 的相关 PR／push，复用随版 HAP 工作流，避免维护两套阅读器构建步骤。PR 使用准确 Actions 合并候选 SHA，push／手动构建使用准确主线 SHA，与普通平台质量和构建校验保持同一源码。下一候选继续 `release_enabled: false`，构建验证不自动启用正式发布。

## 本地验证

- 官方 Flutter 3.41.6 离线、强制锁解析通过，根锁无差异。
- 普通 Flutter 严格分析通过；本次 28 个 Dart 文件格式校验无变化。
- 鸿蒙适配、导入、更新提示、目录／文件生命周期及阅读平台效果相关 188 项 Flutter 回归通过。
- 发布及治理 Python 测试 246 项：239 项通过，7 项平台跳过。其中新增的 7 项真实 Git／合成 HAP 测试覆盖主线来源一致、普通修复无需改 pin、错误来源、工作区漂移、发布开关与产物篡改。
- 鸿蒙 Python 工具测试 46 项通过，ArkTS 目录桥接的 Node 测试 13 项通过。
- 架构边界、构建元数据、实际 Git／本地依赖来源和许可证、两份鸿蒙工作流解析通过。

普通平台安装包及真实 API 26 HAP 由云端对准确主线提交构建；本地 Flutter 回归中的 Windows DLL 缺失回退不作为原生库验收。构建、真机签装、覆盖升级和续签分别记录。

## 分支清理与恢复

清理以主线统一构建通过为前提。保留 `main` 和两项归档标签：

- `harmonyos-frozen-244`：`3e1be1391ba784bb228803525696d38c208f471f`，保留 244 schema 1 固定来源。
- `harmonyos-branch-final-245`：`ca5f7ef98ec03872d087f0b691e40f0de0080939`，保存最后一版双分支候选。

移除远端 `HarmonyOS` 和 `codex/harmonyos-frozen-244` 开发分支。旧本地工作分支没有开放 PR，相关工作已整合；清理分支前将关联旧工作区停留在原 commit 的 detached HEAD，不删除工作区目录、不改其文件或暂存内容。旧原生工作区的 42 项状态差异已核对，canonical blob 均等于原 HEAD；仍逐文件保存物理字节并验证清理前后相等。

清理前全部引用保存在 `C:/Users/pengs/.codex/tmp/harmonyos-main-unification-20261107/before-unification.bundle`，大小 13,417,834 字节，SHA-256：

`0181e7c73c342e718fbda7b1fdaafb2586827f7e43b4e4aa5feef738b8fdd83a`。

同目录保存清理前 refs、各工作区状态、补丁、物理文件摘要及原生工作区核查报告。已验证 bundle 可读取；分支删除不配合对象强制清理，归档标签和原有版本标签继续保留。
