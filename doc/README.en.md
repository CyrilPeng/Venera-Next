# Documentation Index

Default Chinese index: [README.md](README.md)

This is the English companion index for `doc/`. Documents are grouped by type and use `topic.zh.md` / `topic.en.md` language suffixes. The `experiments/` directory is the exception: experiment plans and task notes are maintained in Chinese only.

## Directory Rules

| Directory | Type | Language rule |
|---|---|---|
| `api/` | Developer APIs, extension interfaces, script contracts | Chinese and English |
| `architecture/` | Repository structure, module boundaries, architecture rules | Chinese and English; Chinese is the default maintenance entry |
| `development/` | Local development, builds, testing, and developer troubleshooting | Chinese and English; Chinese is the default maintenance entry |
| `distribution/` | Release, distribution, package manager, and workflow notes | Chinese and English; Chinese is the default maintenance entry |
| `user/` | User guides, import formats, command-line usage | Chinese and English |
| `experiments/` | Experiments, task tracking, technical research | Chinese only; not a public roadmap commitment |

## Developer API

- [漫画源开发说明](api/comic_source.zh.md) / [Comic Source Guide](api/comic_source.en.md)
- [JavaScript API](api/js.zh.md) / [JavaScript API](api/js.en.md)

## Architecture

- [项目结构约定](architecture/project_structure.zh.md) / [Project Structure](architecture/project_structure.en.md)

## Development and Builds

- [构建与开发](development/build.zh.md) / [Build and Development](development/build.en.md)
- [依赖治理](development/dependencies.zh.md) / [Dependency Governance](development/dependencies.en.md)

## Distribution

- [Windows 分发](distribution/windows.zh.md) / [Windows Distribution](distribution/windows.en.md)

## User And CLI

- [本地漫画导入](user/import_comic.zh.md) / [Import Comic](user/import_comic.en.md)
- [无头命令模式](user/headless.zh.md) / [Headless Mode](user/headless.en.md)

## Experiments

- [图片增强实验](experiments/image_enhancement.zh.md)

## Maintenance Rules

- Keep the root README focused on the most useful user-facing entry points.
- Except for `experiments/`, every new document should have both Chinese and English versions.
- Chinese documents are the default entry. If the two versions cannot be perfectly synchronized, keep the Chinese version complete and accurate first.
- `experiments/` documents record decisions, risks, and tasks before a feature is stable.
- Comic source documents describe only the extension interface and runtime contract. They must not provide, recommend, maintain, or verify third-party comic sources.
