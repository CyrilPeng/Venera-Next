# 文档索引

English index: [README.en.md](README.en.md)

本文档是 `doc/` 目录的默认中文入口。新增文档时优先按类型放入子目录，并使用 `topic.zh.md` / `topic.en.md` 维护语言版本。`experiments/` 目录例外，实验设计和任务跟踪文档只要求中文。

## 目录约定

| 目录 | 类型 | 语言约定 |
|---|---|---|
| `api/` | 开发 API、扩展接口、脚本接口 | 中英文双版本 |
| `architecture/` | 仓库结构、模块边界、架构约定 | 中英文双版本，中文为默认维护入口 |
| `development/` | 本地开发、构建、测试和开发故障排查 | 中英文双版本，中文为默认维护入口 |
| `distribution/` | 发布、分发、包管理器和工作流维护 | 中英文双版本，中文为默认维护入口 |
| `user/` | 用户使用说明、导入格式、命令行用法 | 中英文双版本 |
| `experiments/` | 实验设计、任务跟踪、技术预研 | 中文即可，不作为正式路线图承诺 |

## 开发 API

- [漫画源开发说明](api/comic_source.zh.md) / [Comic Source Guide](api/comic_source.en.md)
- [JavaScript API](api/js.zh.md) / [JavaScript API](api/js.en.md)

## 架构和结构

- [项目结构约定](architecture/project_structure.zh.md) / [Project Structure](architecture/project_structure.en.md)

## 开发和构建

- [构建与开发](development/build.zh.md) / [Build and Development](development/build.en.md)
- [依赖治理](development/dependencies.zh.md) / [Dependency Governance](development/dependencies.en.md)

## 分发和发布

- [Windows 分发](distribution/windows.zh.md) / [Windows Distribution](distribution/windows.en.md)

## 用户和命令行

- [本地漫画导入](user/import_comic.zh.md) / [Import Comic](user/import_comic.en.md)
- [无头命令模式](user/headless.zh.md) / [Headless Mode](user/headless.en.md)

## 实验和任务跟踪

- [图片增强实验](experiments/image_enhancement.zh.md)

## 维护原则

- README 只保留用户最需要的入口，不承载长篇开发文档。
- 除 `experiments/` 外，新增文档应同时提供中文和英文版本。
- 中文文档是默认入口；当中英文内容无法完全同步时，应优先保证中文版本完整准确。
- `experiments/` 文档用于记录判断、风险和任务，不在功能稳定前写进 README 的功能宣传。
- 源相关文档只描述扩展接口和运行时契约，不提供、推荐、维护或验证任何第三方漫画源。
