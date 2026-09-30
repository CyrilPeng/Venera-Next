# 架构优化执行记录

English: [Execution Record](optimization_progress.en.md)

## P0：工具与检查基线（2026-09-30）

- 起点：`550fcff`。工作区原有阅读菜单锁定、长按自动阅读暂停、相关设置与测试、README 和翻译修改；它们参与工作区测试但不纳入本阶段提交。
- `flutter test --coverage --reporter expanded`：579 项通过，无失败；本次生成的行覆盖率 34.62%（10018/28938）。
- 修正分析范围后 `flutter analyze --no-pub --no-fatal-infos`：无 error/warning，24 个 info。原两个错误及一个提示来自 `build/`，仅排除此生成目录。
- 原 Python 脚本测试：44 项通过（3 项跳过）；新增依赖检查器有 7 项测试，覆盖条件引用、相对/包引用、part、注释/字符串、间接 UI 导出、新依赖及循环识别。
- 新检查器在 CI 阻止新增功能域依赖。现有聚合依赖环为：comic_details、favorites、history、local_comics、reader、search、sync。该环包含 UI 导航，不等同于纯业务依赖环。
- `dependency_baseline.json` 明确记录现存依赖与 UI 文件；业务入口在后续迁移时登记，当前数量为零，不声称已对旧业务层实现隔离。
- 日志位于本机 `output/architecture-baseline-tests.log`、`output/architecture-analysis.log`、`output/architecture-python-tests.log`，不将生成日志提交到仓库。

### 性能基线与平台补验

本阶段完成代码质量基线和检查设施；真实设备性能与五平台构建尚未验证，不能将整个 P0 的设备验收标记完成。进入 P5 前固定目标设备、release/profile 模式和合成数据集，重复至少三次记录切章、快速跳页、长图滚动的耗时、帧耗时与内存峰值。P6 前记录目录扫描、同步和批量导入耗时及吞吐。

同设备同样本对比重构前后结果，先测量自然波动再设置回退阈值；不能用测试套件运行时间代替 UI 性能。Android/iOS/Linux/macOS 平台验证交给对应 runner/设备，未执行项保持未验证状态。

## 后续阶段

P1 首批清理已完成：Channel 只有专属测试调用，组件聚合导出无生产调用，已删除二者及 Channel 测试，并将路径加入退场检查。动态 JS/平台入口、迁移代码和依赖包没有充分删除证据，保留；临时产物不属于本次清理范围。P2–P8 待实施。每次完成可验收任务后更新本记录和 CHANGELOG，独立提交；保持原有未提交功能改动。
