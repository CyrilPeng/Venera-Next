# 漫画源开发说明

本文档说明如何为 VeneraNext 编写兼容 JavaScript 扩展 API 的漫画源扩展。英文版本见 [comic_source.en.md](comic_source.en.md)，JavaScript API 参考见 [js.zh.md](js.zh.md) 和 [js.en.md](js.en.md)。

## 重要声明

VeneraNext 只维护漫画阅读器本体和扩展运行环境。

本仓库不提供、内置、托管、推荐、维护或验证任何第三方漫画源、源列表、源站内容或版权状态。请不要在本仓库反馈与具体源仓库、源站、作品、章节缺失、图片可用性或版权相关的问题。

## 漫画源列表

应用可以显示用户自行配置的漫画源列表。源列表应指向一个 JSON 文件，格式如下：

```json
[
  {
    "name": "Source Name",
    "key": "example_source",
    "fileName": "source.js",
    "version": "1.0.0",
    "description": "A brief description of the source"
  }
]
```

`name` 和 `key` 必填，`key` 应与扩展中的同名字段一致。使用 `url` 或 `fileName` 指定下载地址，字段名称区分大小写；两者同时提供时，优先使用非空的 `url`。`description` 可选。

`url` 可以是完整的 HTTP(S) 地址，也可以是相对路径；`fileName` 通常是相对路径。相对地址以本次成功加载列表所使用的 URL 为基准解析，例如列表地址为 `https://example.com/repo/index.json` 时，`source.js` 指向 `https://example.com/repo/source.js`。

在应用中修改仓库地址后，点击“刷新”。成功加载并解析列表后才会保存新地址；仅编辑输入框或刷新失败不会覆盖上次成功配置。清空输入框并刷新可以清除仓库地址，不会卸载已安装的扩展。当前列表使用其加载时绑定的地址，不受输入框后续编辑影响。

## 开发准备

- 安装 VeneraNext，调试阶段建议直接用 Flutter 运行项目。
- 准备支持 JavaScript 的编辑器。
- 阅读 JavaScript API 文档，并创建本地 `.js` 文件进行测试。
- 确认扩展只处理接口逻辑，不把源站内容或第三方源列表提交到本仓库。

## 基础模板

漫画源通常继承 `ComicSource`，并提供基本信息、探索页、搜索、详情页、章节图片等能力。

```javascript
class NewComicSource extends ComicSource {
    name = ""
    key = ""
    version = "1.0.0"
    minAppVersion = "1.0.0"
    url = ""

    async init() {
        // Optional initialization.
    }
}
```

常见必填项：

- `name`：展示名称。
- `key`：唯一标识。发布后不要随意修改，否则会影响收藏、历史和缓存关联。
- `version`：扩展版本。
- `minAppVersion`：最低兼容应用版本。
- `url`：扩展更新地址，可按实际情况留空。

## 常见能力

漫画源可以按需实现以下能力：

- 探索页：提供首页、推荐、排行等入口。
- 分类页：提供分类、筛选和分页加载。
- 搜索：根据关键词返回漫画列表。
- 漫画详情：返回标题、封面、简介、标签、章节列表等信息。
- 章节图片：返回章节内图片地址或图片加载信息。
- 收藏：对支持网络收藏的站点提供收藏、取消收藏、收藏夹等能力。
- 评论：对支持评论的站点提供评论读取、发送、点赞或投票能力。
- 设置：为扩展提供独立配置项。
- 翻译：为扩展内文本提供本地化。

具体函数签名和运行时对象请参考 [js.zh.md](js.zh.md) 与 [js.en.md](js.en.md)。

## 兼容性

VeneraNext 会尽量在实际可行的范围内保持 JavaScript 漫画源扩展接口兼容。这里的兼容只指扩展接口和运行时契约，不代表本仓库提供、推荐或验证任何第三方源。

## 调试建议

- 先用最小功能跑通 `search`、`loadComic` 和章节图片加载。
- 对网络请求、HTML 解析和分页逻辑分别做日志输出。
- 保持 `key` 稳定，避免测试阶段频繁更换导致历史、收藏或缓存混乱。
- 如果扩展依赖用户登录、Cookie 或站点特定配置，应放入扩展设置，不要写死在脚本中。
- 如果图片加载失败，先确认扩展生成的请求参数、headers、referer 和站点访问状态。
