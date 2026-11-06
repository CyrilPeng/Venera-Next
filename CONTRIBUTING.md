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

## 开发要求

先使用仓库指定的 Flutter 版本，并从锁文件解析依赖：

```bash
flutter pub get --enforce-lockfile
```

提交前至少运行：

```bash
python .github/scripts/check_structure_imports.py
python -m unittest discover -s .github/scripts/tests -p "test_*.py"
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

仅修改 Issue 表单、Python 自动检查或配套文档时，先运行 Python 脚本测试、版本／结构检查和 `git diff --check`；Flutter 分析、完整测试及平台门禁由 PR 的现有质量流程验证。

新增依赖必须说明来源、版本或 commit、使用原因、许可证、上游状态和替代方案。不要提交 `any` 依赖或未固定的 Git 分支。具体规则见[依赖治理](doc/development/dependencies.zh.md)。

提交应保持单一目的，提交信息使用简洁的 Conventional Commits 风格。涉及用户可见行为或仓库维护方式时同步更新 `CHANGELOG.md`。

## Pull Request

PR 描述应包含问题、方案、影响范围、测试命令和未验证的平台。涉及数据迁移、发布流程或依赖升级时，必须明确回滚方式。

安全漏洞请不要公开创建 Issue，参阅[安全政策](SECURITY.md)。参与项目时请遵守[行为准则](CODE_OF_CONDUCT.md)。
