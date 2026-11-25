# 贡献指南

English version: [CONTRIBUTING.en.md](CONTRIBUTING.en.md)

感谢你关注 VeneraNext。本仓库只维护阅读器本体，不维护、提供或排查任何漫画源。

## 可以提交什么

- 可在不依赖特定源站或具体作品的情况下复现的阅读器缺陷。
- 阅读模式、本地漫画、WebDAV、归档、同步、设置、平台构建和文档改进。
- 有清晰使用场景、实现边界和验证方式的功能建议。

## 不要提交什么

不要提交源站内容、搜索结果、具体作品可用性、章节缺失、图片可用性或版权问题。此类问题应反馈给对应扩展、源站或网络服务提供者。

## 提交 Issue

使用[分类表单](https://github.com/CyrilPeng/Venera-Next/issues/new/choose)，按实际出错的功能选择崩溃、阅读性能、本地数据、网络／WebDAV、界面操作或功能建议。一个 Issue 记录一个独立问题，标题写清触发条件与症状。

崩溃、导入／数据和网络失败需脱敏日志；阅读卡顿需手动阅读诊断；纯界面问题和功能建议不强制日志。无法取得时说明具体原因并提供替代证据。固定规则列出缺项，补齐后更新同一条提示，不自动关闭或追补旧报告。详见[分类与诊断采集说明](doc/user/issue_reporting.zh.md)。

## 翻译贡献

当前支持简体中文、繁体中文、英文、德语和日语。现有翻译的遗漏、错误或术语不一致可直接提交 PR，说明对应页面、原文与修改后的含义；英文原文也是翻译键，修改时需同步所有语言词典。文件、参数规则、术语表和校验命令见[翻译维护](doc/development/build.zh.md#翻译维护)。

新增语种先使用[功能建议表单](https://github.com/CyrilPeng/Venera-Next/issues/new?template=06-enhancement.yaml)提交需求；已有同语种请求时在原 Issue 补充。请在需求场景和建议方案中写明：

- 语言名称、地区及期望的语言标识，例如 BCP 47 标签；地区变体应说明差异。
- 实际需求来源、主要使用平台和优先使用的功能。
- 是否愿意提供翻译、独立校对或后续维护，以及可参与的范围。
- 可公开的现有翻译或术语参考；没有参考或校对者时如实说明。

首批新增语种为德语和日语，欢迎熟悉这两种语言的读者参与母语校对和持续维护；当前译文已按原文核对关键操作含义，但尚无社区母语校对者。后续语种继续按需求和校对能力确定范围后再提交新词典。机器翻译可提供初稿；删除、覆盖、备份恢复及错误提示需由熟悉该语言的校对者核实对象、后果和操作含义。贡献者可以分批提交草稿，但语言选择入口须在词典和验收完整后开放。

翻译 PR 应注明所依据的源码提交、完成范围、校对范围和校对参与者，并附语言切换、英文回退、手机／桌面及大字号布局的验证结果。安装包使用 GitHub 工作流从对应 commit 构建，记录运行链接；校对与布局反馈应对应同一份文案。漫画源脚本自己的翻译由相应维护者维护，应用界面翻译不代表源站内容会被翻译。

## 开发要求

先使用仓库指定的 Flutter 版本，并从锁文件解析依赖：

```bash
flutter pub get --enforce-lockfile
```

先按[测试执行与维护](doc/development/testing.zh.md)准备适用 host 的原生库，再按完整清单执行并核对 CI 证据。新增平台／原生用例同步执行归属和已审查的跳过声明；合并／删除说明替代保障。

提交前至少运行：

```bash
python .github/scripts/release_version.py --check
python .github/scripts/check_structure_imports.py
python .github/scripts/check_architecture_dependencies.py
python .github/scripts/test_suites.py --strict-imports --output build/test-audit/inventory.json
python -m unittest discover -s .github/scripts/tests -p "test_*.py"
flutter analyze --no-pub --fatal-infos --fatal-warnings
python .github/scripts/run_flutter_tests.py --suite default --coverage --output build/test-audit/default
git diff --check
```

仅修改 Issue 表单、Python 自动检查或配套文档时，先运行 Python 脚本测试、版本／结构检查和 `git diff --check`；Flutter 分析、完整测试及平台门禁由 PR 的现有质量流程验证。

新增依赖必须说明来源、版本或 commit、使用原因、许可证、上游状态和替代方案。不要提交 `any` 依赖或未固定的 Git 分支。具体规则见[依赖治理](doc/development/dependencies.zh.md)。

提交应保持单一目的，提交信息使用 `<type>(<scope>): <中文描述>` 的 Conventional Commits 格式。提交前同步更新 `CHANGELOG.md`，说明本批已完成的用户行为或仓库维护变更。

## Pull Request

PR 描述应包含问题、方案、影响范围、测试命令和未验证的平台。涉及数据迁移、发布流程或依赖升级时，必须明确回滚方式。

安全漏洞请不要公开创建 Issue，参阅[安全政策](SECURITY.md)。参与项目时请遵守[行为准则](CODE_OF_CONDUCT.md)。
