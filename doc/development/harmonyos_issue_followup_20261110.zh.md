# 鸿蒙问题修复与外部目录后续条件

核对日期：2026-11-10。本轮基于已提供的日志、截图、准确源码和布局回归实施，不要求报告者重复提交已经足够定位的材料。修复待发版，不自动关闭报告。

## 当前报告的实际范围

| 报告 | 环境与证据 | 本轮处理与保留项 |
| --- | --- | --- |
| [#159](https://github.com/CyrilPeng/Venera-Next/issues/159) | MatePad mini／HarmonyOS 7.0，原生 HAP；日志明确由 `DirectoryPicker` 的长期外部目录保护抛出 `UnsupportedError` | 设置页说明并禁用不支持的迁移，保持恢复重试；报错发生于选择／迁移前。外部目录长期使用仍需后续实现与真机验证，入口修复不等于需求完成 |
| [#158](https://github.com/CyrilPeng/Venera-Next/issues/158) | Mate 40 Pro／鸿蒙 4.2，报告选择 Android，实际为 APK；截图显示普通进度覆盖标题、快速收藏箭头没有跟随全宽外框 | 主线共用组件修复徽标范围、局部选择框宽度与大字号描述高度；按 Android 分类，不能计为原生 HAP 运行故障 |
| [#157](https://github.com/CyrilPeng/Venera-Next/issues/157) | Android／Windows 收藏窗口空间利用建议 | 保留界面改进建议，后续独立评估，不混入本轮平台修复 |

同时巡检目录迁移、应用锁、详情分享、图片分享与 PDF 导入入口。鸿蒙禁用不支持的存储迁移／开启锁，允许关闭导入锁；详情复制标题与链接，图片保留保存、禁用系统分享。PDF 导入原有禁用继续保留，Android 音量键、刷新率与平台服务已有条件检查。本轮没有扩大 PDFium、系统认证或系统分享的原生接入。

本机 `hdc list targets` 为 `[Empty]`。离屏 Flutter 截图、控件几何／语义断言、宿主测试和 HAP 构建都不代替真机签装、持久目录、真实数据升级及完整功能验证。发布必须按[主线发布说明](harmonyos_releases.zh.md#准确-hap-的真机验收)等待准确包的维护者验收；不生成多轮候选标签，也不改动已发布 `v1.18.3`。

本地完成 305 项 Flutter 回归，覆盖真实收藏新建／导入／转移、JavaScript 选择弹窗、图片收藏时间筛选、追更、设置保存和漫画布局。选择器使用可参与固有尺寸测量的布局；六项常规／内容弹窗回归在原实现上复现失败，修正后通过，并验证选值交互。布局场景使用真实收藏列表组件及列表高度，覆盖手机、横屏、平板、大字号与普通／双行进度；布局、能力入口和分享测试同时纳入鸿蒙完整包构建。

274 项发布／Issue 等脚本测试完成（7 项宿主环境相关跳过），47 项鸿蒙工具测试和 13 项目录桥接回归通过；严格分析、架构边界、依赖来源、格式、表单／工作流 YAML、文档链接和新增翻译检查通过。截图留在忽略的 `build/harmonyos-ui-qa/`。云端平台门禁须验证同一准确提交的完整 Flutter 套件、真实 QuickJS 选择结果生命周期及 HAP 构建；本地布局回归不替代这些检查。

## 长期外部目录的实施条件

鸿蒙系统本身提供文件持久授权能力；当前限制是本项目尚未完整接入，不能得出“鸿蒙无法使用外部目录”的结论。华为官方说明：

- [文件持久化授权能力](https://developer.huawei.com/consumer/en/doc/doccenter-capabilities/file-persistpermission)
- [fileShare API](https://developer.huawei.com/consumer/en/doc/doccenter-references/api/js-apis-fileshare)

Picker URI 的临时授权会在退出／重启后失效。`fileShare.persistPermission` 保存授权，后续启动须 `activatePermission`；需声明 `ohos.permission.FILE_ACCESS_PERSIST`，并核实 `SystemCapability.FileManagement.AppFileService.FolderAuthorization`。只能持久化系统真实授予的 URI 与访问模式，不手工构造权限；远程 URI 不支持，卸载会清除授权。

| 层面 | 接入与验收要求 |
| --- | --- |
| 系统能力 | API 26 的实际手机／平板分别查询目录选择与持久授权能力；系统拒绝／无能力时保留归档替代，说明原因 |
| 授权生命周期 | 仅保存真实 picker 授权 URI；按实际读写模式持久化，每次冷启动激活；撤销、删除目录或授权过期时进入恢复状态 |
| 存储适配 | 现有漫画库使用 `Directory`／`File`、原生路径解析与迁移所有权检查；系统 URI 不能直接冒充普通 Dart 路径。补齐目录枚举、读写／seek、创建、重命名、删除、跨 isolate 和句柄收尾，并与实际系统文件服务验证 |
| 安全迁移 | 沿用 `LocalStorageMigration`／`LocalStorageRelocation` 的暂存、复制、事务提交与恢复机制；源／目标别名、重叠、只读、容量不足、取消和中断不会破坏旧库。验证新库持久可读前不删除旧副本 |
| 旧数据与恢复 | 先保留独立备份；旧版本应用内漫画、相对／绝对位置、导入配置中的其他平台路径需明确处理；授权撤销时允许重新选择／恢复，不伪报成功 |
| 真机退出条件 | 实际外部目录下载、导入、阅读、备份往返、完全退出／重启及同密钥覆盖升级后仍可读；大文件、中文名称、只读／撤销／中断恢复分别留证据 |

只有完整存储适配、迁移回滚、持久授权生命周期和上述真机条件通过，才将 `DirectoryPicker.supportsPersistentDirectories` 对鸿蒙启用。现有 `DirectorySelection.ownedCopy` 保持复制导入用途；临时沙箱副本和一次选择成功均不能解除长期目录保护。
