# 开放 Issue 复查与处理记录

核对日期：2026-11-12。基于主线 `10cdda67e466f9d17fcadef28a2ce3f111bf5d93` 及本地未发布改动；GitHub 复查仍有 12 个开放 Issue。稳定版为 `v1.18.3+249`，候选版为 `v1.18.4-rc.1+250`。本记录不代替新安装包或原设备验收。

## 范围与当前结果

| Issue | 核对事实 | 本地处理与后续验收 |
| --- | --- | --- |
| [#162](https://github.com/CyrilPeng/Venera-Next/issues/162) | 已发布 HAP 的应用与启动器 base 名称为 `VeneraNext (HarmonyOS Beta)`，启动器中文／英文资源仍为 `venera_next`；并非包名问题 | 准备阶段统一所有语言为 `VeneraNext`；检查成品 `module.json` 引用和实际 `resources.index`，发布验证也执行此检查。需要包含修复的新 HAP 验证桌面名称及同密钥覆盖升级 |
| [#152](https://github.com/CyrilPeng/Venera-Next/issues/152) | 报告者于 11 月 11 日确认 Windows 11 26H2、RC1 的多选／筛选／移动／复制／删除通过；追加顶栏快捷操作与 Esc 建议 | 宽度和字号允许时顶栏显示全选／反选／取消选择；窄屏保留菜单；Esc 先关弹窗，再退出多选，保留活跃搜索，下一次退出搜索。新增行为需后续安装包体验 |
| [#157](https://github.com/CyrilPeng/Venera-Next/issues/157) | 本地目录原先被限制在不超过 360 像素或半屏高度，外层还有一个滚动列表 | 取消内层高度限制，统一目录与网络收藏滚动，固定顶栏提供新建；覆盖大量目录、横屏、大字号及原始收藏顺序与创建生命周期 |
| [#139](https://github.com/CyrilPeng/Venera-Next/issues/139) | 主线没有自动白边裁剪 | 新增默认关闭的纵向连续／瀑布流显示选项，检查完整像素列，保留缓冲；逐页后台检测、限量缓存、原图恢复及退出收尾。保留下载／保存／导出原图；浅色边缘、动图与超预算图片采用保守处理 |
| [#159](https://github.com/CyrilPeng/Venera-Next/issues/159) | RC1 只修正入口说明和禁用未实现的迁移；鸿蒙系统提供持久授权 API，但工程没有完整存储桥 | 新增系统目录选择／目录持久授权能力的只读采集与启动日志，缺失／失败记为未知。长期外部漫画库仍未完成，不解除持久目录保护；下方列出实现与真机条件 |
| [#155](https://github.com/CyrilPeng/Venera-Next/issues/155) | RC1 已提供当前父目录的子目录排序入口；尚无报告者的新验收结果 | 复测管理入口、持久排序及过期页面所有权，保留等待原 Android／Windows 反馈 |
| [#158](https://github.com/CyrilPeng/Venera-Next/issues/158) | Mate 40 Pro／鸿蒙 4.2 中使用的是 Android APK；RC1 已修正封面进度徽标和收藏选择器布局 | 复测真实漫画卡片及选择器在窄屏、横屏与大字号的布局，等待原设备反馈，不能记为原生 HAP 的验收 |
| [#143](https://github.com/CyrilPeng/Venera-Next/issues/143) | 连续新建与大小写区分已随稳定版交付 | 复测新建弹窗及名称大小写、原页面与数据库生命周期；保留原 Android 实际使用验收 |
| [#129](https://github.com/CyrilPeng/Venera-Next/issues/129) | 封面转场控制器的生命周期修复已随稳定版交付 | 复测共享 Navigator、连续导航与返回时的转场收尾；原 Android 偶发封面残留仍需实际使用反馈 |
| [#163](https://github.com/CyrilPeng/Venera-Next/issues/163)、[#81](https://github.com/CyrilPeng/Venera-Next/issues/81)、[#123](https://github.com/CyrilPeng/Venera-Next/issues/123) | 按维护者要求暂缓 | 本轮不扩展列表批量管理、分卷导出或收藏层级 |

阅读菜单锁与本轮改动一同保留：触摸、右键与 TV 入口遵循锁定状态；翻页、滚动和缩放继续可用；章节及模式切换、旋转保持锁定，退出或另一部漫画重置。点击靠边小锁先解锁，TV 确定键也可先解锁。

## #162 成品检查与历史兼容

直接核验 RC1 原 HAP 的官方 SHA-256 后读取资源，启动器 `EntryAbility_label` 的 base 与 `en_US`／`zh_CN` 存在上述差异。修改基础资源不足以覆盖系统语言，因此准备时必须遍历 AppScope 和 entry 的全部限定资源目录。

成品检查使用锁定工具链的 RestoolV2 格式解析 DATA 表和 UTF-8 值，检查边界、资源 ID、基础值、重复记录及所有语言值；应用标签和 mainElement 启动器标签必须指向预期资源。新增标签策略文件纳入源摘要，新源不能通过删除 manifest 声明跳过检查。旧源码、旧 manifest 未声明该策略的 HAP 仍按历史规则验证和恢复，不修改已发布包的摘要或资源。

## #159 长期外部目录的实施顺序

1. **系统能力与真实授权**：在实际 API 26 手机／平板记录 `FolderSelection` 与 `FolderAuthorization`。查询只说明系统能力，不说明应用已经获权。由真实系统 Picker 取得 URI 和访问模式，声明必要的 `FILE_ACCESS_PERSIST` 权限，以 `fileShare.persistPermission` 持久化，并在每次冷启动激活；拒绝、撤销和不支持应保留原记录并进入恢复。
2. **存储桥**：现有漫画库、下载、备份与导出依赖 Dart 文件和目录操作；不能把授权 URI 转成普通路径。提供基于授权对象的枚举、创建、读写／seek、重命名、删除及跨 isolate 访问，保留真实句柄直到当前 I/O 收尾。URI 和授权模式单独保存，不记录到公开诊断；检查源／目标别名、同一对象和目录重叠。
3. **迁移与恢复**：接入现有 `LocalStorageMigration`／`LocalStorageRelocation` 暂存、复制、事务与恢复流程。外部库在退出、冷启动和同密钥覆盖升级后可读之前，保留旧库；验证只读、容量不足、授权撤销、取消、中断、中文名及大文件。支持重新选择以恢复原授权，不用临时沙箱副本冒充长期位置。

详细系统参考与验收清单见[此前的鸿蒙存储跟进](harmonyos_issue_followup_20261110.zh.md#长期外部目录的实施条件)。本机未找到可用鸿蒙真机及配套 hdc／资源编译工具，未采集真实能力结果、构建新 HAP 或完成持久目录验收；已补只读桥和 Dart 宿主测试，未声称这项需求完成。

## 本地验证

本机使用 Windows、Flutter 3.41.6／Dart 3.11.4；项目声明的 Flutter 版本仍为 3.41.4，未修改 SDK 约束、依赖或锁文件。以下结果来自包含本轮未发布改动的工作区。

| 检查 | 结果与范围 |
| --- | --- |
| `flutter analyze --fatal-infos --fatal-warnings` | 通过，无问题 |
| Flutter 全量测试 | 6,058 项通过，4 项跳过，退出码 0；日志为 `build/issues-all-flutter-tests.log` |
| TV flavor 专项 | 使用 CI 的九个测试文件及 `EXPECT_TV=true`、`TV_BUILD=ci-test`、`TV_REVISION=tv-test`，89 项通过；日志为 `build/issues-tv-flavor-tests.log` |
| Windows Release 构建 | `flutter build windows --release --no-pub` 通过，退出码 0，生成 `build/windows/x64/runner/Release/VeneraNext.exe` 及配套文件；日志为 `build/issues-windows-release.log` |
| 图像与裁剪生命周期专项 | 43 项通过，覆盖裁剪恢复、缓存身份、动图、队列上限、暂停重试、退出收尾及滚动加载；日志为 `build/issues-image-lifecycle-tests.log` |
| 收藏面板与阅读设置专项 | 42 项通过，覆盖大量目录、横屏、大字号、收藏顺序、网络操作、连续新建、过期目标及设置持久保存；日志为 `build/issues-panel-and-settings-tests.log` |
| 鸿蒙工具 Python 测试 | 50 项通过；日志为 `build/issues-harmonyos-python-tests.log` |
| `.github/scripts/tests` Python 全套 | 293 项，其中 7 项因宿主条件跳过，其余通过；其中鸿蒙发布验证的 67 项也单独通过。日志为 `build/issues-python-tests.log` 与 `build/issues-harmonyos-release-tests.log` |
| 结构、架构、发布版本同步、依赖来源及许可证 | 全部通过 |
| Dart 格式与 diff 空白检查 | 修改的 26 个 Dart 文件格式检查通过；`git diff --check` 通过 |

跳过项与 Windows 宿主限制有关，未将其记为通过。Flutter 的故障注入日志及 Python 历史提交检查中预期出现的异常信息不代表测试失败；上述结果按最终摘要和退出码记录。

Windows 构建保留了第三方 WebView 插件既有的 CMake CMP0175 开发警告，未阻止构建；未为此改动依赖或构建策略。

这些离屏布局与宿主检查不代替 Android／Apple／Linux 的平台构建、原设备实际使用或鸿蒙验收。以上本地验证时尚未构建新 HAP；#162 桌面名称和 #159 真实目录能力仍需符合记录条件的鸿蒙设备验证。本轮改动已同步更新日志和跟进文档，尚未发布安装包；开放 Issue 状态未变更。
