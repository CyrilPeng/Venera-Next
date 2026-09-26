# 漫画源编写指南

[English](comic_source.en.md) · [JavaScript API](js.zh.md) · [本地调试](../development/source_debugging.zh.md) · [返回 README](../../README.md#漫画源开发)

本文以当前仓库中的 [JS 运行时](../../assets/init.js)、[源解析器](../../lib/features/comic_source/parser.dart) 和[数据模型](../../lib/features/comic_source/models.dart)为准，说明怎样编写、调试和发布一个源。示例只使用虚构地址，不是可用的漫画源或源推荐。

VeneraNext 保留 Venera 的扩展接口；不同版本的管理界面和运行时细节可能有差异。多仓库、统一“添加来源”和新的重载流程目前属于主分支未发布功能，稳定版 v1.16.0 仍使用原有导入界面。

## 阅读路线

1. 先运行最小结构，打通搜索 → 详情 → 章节图片。
2. 核对 ID、返回类型、章节顺序和图片请求。
3. 按需加入探索、分类、账号、网络收藏、评论与设置。
4. 用本地调试验证，再通过脚本链接或仓库目录分发。

## 1. 脚本与最小示例

扩展是一个 UTF-8 `.js` 文件，声明一个继承 `ComicSource` 的入口类。使用类字段与箭头函数定义回调，可在回调中通过 `this` 访问源实例。不要使用 `import`、`export`、`require` 或依赖浏览器页面的全局变量；这不是 Node.js 或完整浏览器环境。

| 字段 | 规则 |
|---|---|
| `name` | 非空展示名称 |
| `key` | 稳定且唯一；匹配 `^[a-zA-Z_][a-zA-Z0-9_]*$`，发布后不要随意更改 |
| `version` | 源版本字符串，使用三段数字，如 `1.0.0`；后缀比较规则见发布章节 |
| `minAppVersion` | 显式填写实际验证过的最低应用版本，如 `1.16.0`；基类默认空字符串不是有效版本 |
| `url` | 源脚本的原始 HTTP(S) 下载地址；没有分发地址时可留空，不能填写 GitHub 文件展示页或源列表地址 |
| `init()` | 可选初始化；保持简短，不在这里加载整站内容 |

入口类至少声明有效的基本信息；要让用户能打开和阅读漫画，还需实现 `comic.loadInfo`、`comic.loadEp`，并提供搜索、探索、分类或链接等访问入口。未实现的可选能力应省略，不要保留空函数伪装成支持。

完整模板：[minimal_source.js](../examples/minimal_source.js)。它使用虚构 JSON 服务演示请求、搜索、详情、章节、图片请求头和标签跳转。原样导入只能检查脚本结构，真实内容加载需替换域名、路径与字段映射。其示例接口约定是：

| 请求 | 示例响应形状 |
|---|---|
| `GET /api/search?q=...&page=1` | `{items: [{id, title, author, cover, tags}], totalPages: 1}` |
| `GET /api/comics/demo` | `{title, author, cover, description, updatedOn: "2026-09-01", chapters: [{id: "1", title: "第 1 章"}]}` |
| `GET /api/comics/demo/chapters/1` | `{images: ["https://example.invalid/images/1.jpg"]}` |

最核心的结构如下（静态数据用于说明返回契约）：

```javascript
class MinimalSource extends ComicSource {
    name = "Minimal Example";
    key = "minimal_example";
    version = "1.0.0";
    minAppVersion = "1.16.0";
    url = "";

    search = {
        optionList: [],
        load: async (keyword, options, page) => ({
            comics: page === 1 ? [
                new Comic({
                    id: "demo",
                    title: "Demo",
                    cover: "https://example.invalid/cover.jpg"
                })
            ] : [],
            maxPage: 1
        })
    };

    comic = {
        loadInfo: async id => new ComicDetails({
            title: "Demo",
            cover: "https://example.invalid/cover.jpg",
            tags: { author: ["Example Author"] },
            chapters: { ep_1: "Chapter 1", ep_2: "Chapter 2" },
            updateTime: "2026-09-01"
        }),
        loadEp: async (comicId, epId) => ({
            images: ["https://example.invalid/" + epId + "/1.jpg"]
        })
    };
}
```

无需自己注册 `ComicSource.sources`，应用会在安装/加载时完成注册。

## 2. 数据与章节规则

### 漫画列表和详情

可使用 `new Comic({...})`、`new ComicDetails({...})`，或返回同形状的普通对象。使用字符串键、数组和明确的基本类型；不要依赖 JS 原生 `Map`/`Set` 或任意类实例跨桥接转换。

| 数据 | 主要字段 |
|---|---|
| `Comic` 列表项 | `id: string`、`title: string`、`cover: string`；可选 `subtitle`、`tags: string[]`、`description`、`language`、`stars`、`maxPage`、`favoriteId` |
| `ComicDetails` 详情 | 必填 `title: string`、`cover: string`、`tags: {命名空间: string[]}`，没有标签时用 `{}`；`chapters` 可为 null，可选 `subtitle`、`description`、`updateTime`、`uploadTime`、`url` |
| 详情中的可选能力数据 | `thumbnails: string[]`、`recommend: Comic[]`、`comments: Comment[]`、`isFavorite`、`isLiked`、`likesCount`、`commentCount`、`subId`、`uploader`、`stars`、`maxPage` |
| 章节图片 | `comic.loadEp(comicId, epId)` 返回 `{images: string[]}`，不能直接返回数组或 `{images: [{url: ...}]}` |

`Comic.tags` 是数组，`ComicDetails.tags` 是按命名空间分组的对象。列表和详情的 `stars` 都是 0～5；`comic.starRating` 收到的评分参数则是 0～10。统一使用 `subtitle`：列表和 `new ComicDetails(...)` 构造函数兼容 `subTitle` 别名，但直接返回详情普通对象时不转换该别名。详情的漫画 ID 和源标识由调用参数补入。

ID 应在搜索、详情、收藏、下载和历史中保持一致。URL 签名或访问令牌变化不应导致漫画 ID、章节 ID 随之改变。

### 章节与阅读顺序

无分章作品使用 `chapters: null`，`loadEp` 应能处理 `epId == null`。不要用空章节对象代替无分章作品。

普通章节：

```json
{
  "ep_1": "第 1 章",
  "ep_2": "第 2 章"
}
```

分组章节：

```json
{
  "正篇": {
    "main_1": "第 1 章",
    "main_2": "第 2 章"
  },
  "番外": {
    "extra_1": "番外 1"
  }
}
```

- 按实际阅读顺序返回章节，通常为从旧到新；图片数组也必须按阅读顺序排列。
- 不混用分组和非分组结构，分组之间的章节 ID 也应唯一。
- JavaScript 会优先按数值顺序枚举整数形式的对象键。需要保留自定义次序时可使用稳定的非整数键，再在 `loadEp` 中映射回站点 ID，模板使用了 `ep_` 前缀。
- 详情页正序/倒序是显示偏好；源不要随用户显示偏好反转底层章节。
- 瀑布流会预加载相邻章节，并依赖章节及图片顺序；不要在 `loadEp` 中把下一章的图片混入当前章。
- 请求可能并发执行。不要用“当前漫画/当前章节”的全局变量保存请求参数，始终使用回调提供的 `comicId`、`epId`。
- 双页拆分、夜间调光、墨水屏刷新和自动阅读由阅读器负责；原图比例识别也无需扩展声明阅读模式。

### 追更日期与作者标签

追更调用 `comic.loadInfo`，读取 `updateTime`，或在该字段缺失时读取 `更新`、`最後更新`、`最后更新`、`update`、`last update` 命名空间的首个标签。

日期请返回 `YYYY-MM-DD`，也接受日期后接空格与时间；不要返回时间戳、相对时间或带 `T` 的 ISO 时间字符串。当前逻辑按日期比较，因此同一天内多次更新不能靠不同时间区分。不要用“本次请求时间”伪造更新日期；没有可靠日期时省略，单纯章节数量变化不会自动代替日期判断。

作者标签可使用 `author`、`authors`、`artist`、`artists`、`作者` 或 `画师`。配合 `comic.onClickTag`，用户可把作者/标签搜索保存为快捷方式。

## 3. 搜索、探索与分类

### 分页契约

下面的参数顺序是 **JavaScript 扩展接口**，不要照抄 Dart 内部类型的参数顺序。

| 回调 | 返回值 |
|---|---|
| `search.load(keyword, options, page)` | `{comics: Comic[], maxPage: number}` |
| `search.loadNext(keyword, options, next)` | `{comics: Comic[], next: string或null}` |
| `explore[i].load(page)`，类型为 `multiPageComicList` | `{comics: Comic[], maxPage: number}` |
| `explore[i].loadNext(next)`，同上 | `{comics: Comic[], next: string或null}` |
| `categoryComics.load(category, param, options, page)` | `{comics: Comic[], maxPage: number}` |
| `categoryComics.ranking.load(option, page)` | `{comics: Comic[], maxPage: number}` |
| `categoryComics.ranking.loadWithNext(option, next)` | `{comics: Comic[], next: string或null}` |

页码从 1 开始；游标首次为 `null`，没有下一页时也返回 `next: null`。不要把游标接口写成返回 `maxPage`。搜索、分页探索与排行同时实现两种方式时，页码回调优先；一般只实现一种。

`search.optionList` 中每项使用 `{label, type, options, default}`，选项文本为 `"值-显示名称"`。类型为 `select`、`multi-select` 或 `dropdown`；多选传入 JSON 数组字符串，未选中的下拉项可为 `null`。可通过 `search.enableTagsSuggestions` 与同步回调 `onTagSuggestionSelected(namespace, tag)` 控制标签建议插入的字符串。

### 探索页

`explore` 是数组，每项的 `title` 应唯一：

- `multiPageComicList`：使用上表的页码或游标接口。
- `multiPartPage`：`load()` 返回 `[{title, comics: Comic[], viewMore}]`；`viewMore` 使用下文的跳转目标。
- `mixed`：`load(index)` 从 0 开始，返回 `{data: [...], maxPage?}`；`data` 中可放漫画数组或 `{title, comics}` 分块。当前混合页不会把 `viewMore` 对象转换为跳转目标，请省略该字段；需要“更多”跳转时使用 `multiPartPage`。
- 旧的 `singlePageWithMultiPart` 仍支持，返回 `{分区名: Comic[]}`；新扩展建议用 `multiPartPage`。

### 分类与跳转

`category` 使用 `title`、`parts` 与可选 `enableRankingPage`。静态分类示例：

```javascript
category = {
    title: "Example categories",
    parts: [{
        name: "Genres",
        type: "fixed",
        categories: [{
            label: "Adventure",
            target: {
                page: "category",
                attributes: { category: "Adventure", param: "adventure" }
            }
        }]
    }],
    enableRankingPage: false
};
```

将这个字段放进源类中。分类分块支持 `fixed`、`random`（带 `randomNumber`）、`dynamic`（用同步 `loader()` 返回 `[{label, target}]`）。旧格式的字符串 `categories` 搭配 `itemType`、`categoryParams` 或 `groupParam` 仍支持。不要给静态分块返回空 `categories` 数组。

`categoryComics.optionList` 提供筛选；也可通过异步 `optionLoader(category, param)` 返回筛选项。每项包含 `label`、`options: ["值-显示名称"]`，可用 `showWhen`/`notShowWhen` 按分类名称控制显示。排行还需配置 `categoryComics.ranking.options`。

推荐跳转格式：

```javascript
({ page: "search", attributes: { text: "author:Example", options: [] } });
({ page: "category", attributes: { category: "Adventure", param: "adventure" } });
```

`comic.onClickTag(namespace, tag)` 必须同步返回目标对象或 `null`。旧的 `{action, keyword, param}` 仍兼容。链接识别使用 `comic.link = {domains: ["example.invalid"], linkToId: url => ...}`，其中 `linkToId` 同步返回 ID 或 `null`；`comic.idMatch` 是可选的正则字符串。

## 4. 图片加载

`loadEp` 的每个字符串可以是图片 URL，也可以是由 `onImageLoad` 解析的稳定 image key。默认按 GET 下载；需额外请求头或签名地址时返回普通配置对象：

```javascript
onImageLoad: (imageKey, comicId, epId) => ({
    url: imageKey,
    headers: { "Referer": "https://example.invalid/" }
})
```

此片段放入 `comic` 对象。配置支持 `url`、`method`、`data`、`headers`、`onResponse`、`modifyImage`、`onLoadFailed`，完整契约见 [JavaScript API](js.zh.md#图片处理)。

- `comic.onImageLoad` 可以异步返回配置；**`comic.onThumbnailLoad` 当前必须同步返回配置**，不能声明为 `async`。
- 封面/缩略图不自动继承正文请求头，需单独实现 `onThumbnailLoad`。
- `onResponse(bytes)` 处理响应字节；`modifyImage` 是另一个引擎中执行的图片处理脚本字符串。
- `onLoadFailed()` 只用于正文图片的有限失败恢复，返回新的加载配置；缩略图不支持它和 `modifyImage`。
- `comic.loadThumbnails(id, next)` 返回 `{thumbnails: string[], next}`，与负责请求配置的 `onThumbnailLoad` 不是同一个接口。裁剪缩略图可使用 `url@x=起点-终点&y=起点-终点`。

扩展只提供图片信息，让应用负责下载、缓存和预加载；不要在详情加载时把整本漫画下载进内存。

## 5. 账号、网络收藏与互动

### 账号

`account` 可按需包含：

| 成员 | 契约 |
|---|---|
| `login(account, password)` | 异步登录；失败必须抛出错误，普通返回值（包括 false）不会自动视为失败 |
| `logout()` | 清理源自己的登录数据和 Cookie |
| `loginWithWebview` | `{url, checkStatus(url, title), onLoginSuccess?}`；状态判断与成功回调为同步函数 |
| `loginWithCookies` | `{fields: string[], validate(values)}`；按字段顺序接收值，校验前由源设置 Cookie，返回布尔值或 Promise |
| `registerWebsite` | 可选注册页 URL |

同时提供 `login` 和 Cookie 登录时，账号密码登录优先。源数据通过 `this.loadData/saveData/deleteData` 保存，设置通过 `this.loadSetting` 读取；不要把真实账号或 Cookie 写进分发脚本。

### 网络收藏

本地收藏、稍后阅读和追更由应用维护。只有站点提供账号收藏时才实现 `favorites`：

| 成员 | 契约 |
|---|---|
| `multiFolder` | 必填布尔值，是否支持多个网络收藏夹 |
| `addOrDelFavorite(comicId, folderId, isAdding)` | 添加/移除收藏；当前桥接只传这三个参数，不传旧文档中的第四个 `favoriteId` |
| `loadComics(page, folder)` | 返回 `{comics, maxPage}`；单收藏夹的 `folder` 可为 null |
| `loadNext(next, folder)` | 游标方式，返回 `{comics, next}`；建议与页码方式二选一 |
| `loadFolders(comicId)` | 多收藏夹时返回 `{folders: {id: name}, favorited: string[]}`；传入漫画 ID 时标出其所在收藏夹 |
| `addFolder(name)`、`deleteFolder(folderId)` | 可选，异步完成操作，失败抛出错误 |
| `isOldToNewSort`、`singleFolderForSingleComic` | 可选布尔值，声明排序方向及单漫画是否限一个收藏夹 |

收藏请求需处于已登录状态。抛出包含 `Login expired` 的错误会触发应用尝试重新登录并重做一次相应操作；其他错误直接显示失败。

### 评论、评分与归档

以下成员均放在 `comic` 中，加载/提交函数可以返回 Promise：

| 回调 | 返回值或含义 |
|---|---|
| `loadComments(comicId, subId, page, replyTo)` | `{comments: Comment[], maxPage?}` |
| `sendComment(comicId, subId, content, replyTo)` | 提交评论或回复，失败抛错 |
| `loadChapterComments(comicId, epId, page, replyTo)` | `{comments: Comment[], maxPage?}`；章节评论用于阅读器 |
| `sendChapterComment(comicId, epId, content, replyTo)` | 提交章节评论或回复 |
| `likeComic(id, isLike)`、`likeComment(comicId, subId, commentId, isLike)` | 点赞/取消点赞 |
| `voteComment(id, subId, commentId, isUp, isCancel)` | 返回新的数值分数 |
| `starRating(id, rating)` | 接收 0～10 的评分；详情展示的 `stars` 为 0～5 |
| `archive.getArchives(comicId)` | `[{id: string, title: string, description: string}]` |
| `archive.getDownloadUrl(comicId, archiveId)` | 返回非空下载 URL 字符串，不是 `{url: ...}` |

`Comment` 提供 `userName`、`content`，可选 `avatar`、`time`、`id`、`replyCount`、`isLiked`、`score`、`voteStatus`（1/0/-1）。章节评论回复按钮需同时有 `id` 和 `replyCount`。评论富文本支持 `a/b/i/u/s/br/span/img`，`span` 只支持有限字体样式，图片集中显示在评论末尾；不是完整 HTML 页面。

## 6. 设置与翻译

```javascript
settings = {
    quality: {
        title: "Image quality",
        type: "select",
        options: [
            { value: "original", text: "Original" },
            { value: "small", text: "Small" }
        ],
        default: "original"
    },
    compact: { title: "Compact list", type: "switch", default: false },
    keyword: { title: "Keyword", type: "input", default: "", validator: null },
    check: {
        title: "Connection",
        type: "callback",
        buttonText: "Check",
        callback: async () => UI.showMessage(this.translate("Done"))
    }
};

translation = {
    zh_CN: { "Image quality": "图片质量", "Done": "完成" },
    zh_TW: { "Image quality": "圖片品質", "Done": "完成" },
    en: {}
};
```

以上字段放在源类中。`input.validator` 为正则字符串或 `null`；`callback` 可异步，等待期间按钮显示加载状态。读取值用 `this.loadSetting("quality")`，不要用 `saveData("setting", ...)` 覆盖设置。

源配置中的标题等由应用翻译；`UI` API 的字符串需自己调用 `this.translate(...)`。词典键使用 `zh_CN`、`zh_TW`、`en`。

`comic.enableTagsTranslate: true` 可启用应用已有的中文标签翻译，适用于使用相应命名空间和标签词汇的源。它与源自己的 `translation` 词典不同；没有匹配词条时保留原标签。

## 7. 发布脚本与源仓库

单个源可以通过原始 JS 链接或文件安装。仓库则提供 UTF-8 JSON **数组**：

```json
[
  {
    "name": "Example Source",
    "key": "example_source",
    "version": "1.0.0",
    "fileName": "scripts/example.js",
    "description": "Example catalog entry"
  }
]
```

- `name`、`key`、`version` 必填。`key` 与脚本一致，`version` 与脚本同时更新，使用三段数字版本，可带点号或连字符后缀。
- 提供非空 `url` 或 `fileName`；两者都有时非空 `url` 优先。`description` 可选。
- 相对路径以**最终成功响应的列表 URL**为基准。例如 `https://example.invalid/repo/index.json` 中的 `scripts/example.js` 指向 `https://example.invalid/repo/scripts/example.js`。
- 粘贴或导入本地 JSON 时，相对路径需要原始列表地址；全绝对 HTTP(S) 地址不需要。为本地列表补地址只用于解析路径，不会自动把它保存为在线仓库。
- 主分支可预览列表、选择条目，并将通过链接加载的列表保存为在线仓库；仓库关联决定之后的版本检查与更新位置。未关联有效仓库时仍可按脚本 `url` 手动更新。
- 同一 `key` 不会安装多份。仓库中存在多个同 key 的变体时可能需要用户选择来源，发布者宜避免无意重复。
- 主分支跳过无效条目并汇总提示；全部条目无效时拒绝保存。更新脚本若返回不同 `key` 会被拒绝，不能用更新把一个源替换成另一个源。
- 版本比较使用项目自身规则，不是完整 npm SemVer 范围解析器。避免只改变预发布后缀却依赖复杂优先级，发布前验证更新检查。

应用不内置或推荐第三方仓库；请在自己的渠道分发合法的扩展和列表。

## 8. 调试、错误与兼容性检查

当前主分支流程：漫画源 → 添加来源 → 选择文件/粘贴 → 预览安装；源菜单 → 编辑脚本 → 保存并重新加载。v1.16.0 使用旧的文件/链接入口。完整步骤和版本限制见[本地调试](../development/source_debugging.zh.md)。

在 JS Evaluator 中检查自己安装的模板：

```javascript
(async () => {
    const source = ComicSource.sources.example_source;
    const result = await source.search.load("demo", [], 1);
    return result;
})()
```

发布前至少核对：

- 搜索首尾页和空结果，详情字段类型，无分章/分组章节，以及跨章的真实顺序。
- 正文和封面各自的请求头，失效图片地址、异常 JSON 和网络失败是否给出可理解的错误。
- 加入本地收藏、稍后阅读、追更、下载后重读，以及退出后恢复阅读位置。
- 源升级仍使用相同 key；仓库版本、脚本版本、最低应用版本和实际下载内容一致。
- 取消、失败重试与重新加载时不写入迟到的业务结果；不在加载接口中执行评论、收藏等远端写操作。

只读加载在部分 JSON/网络瞬时失败时最多额外重试两次；不要叠加无限重试。当前主分支显式安装/重载等待 `init()` 最多 15 秒，调试器等待结果最多 30 秒，追更每本最多 45 秒。超时不等于强制杀死 QuickJS，异步子请求的取消也有边界；详见[追更调度与取消边界](../development/source_debugging.zh.md#追更调度与取消边界)。

常见错误：

| 现象 | 检查点 |
|---|---|
| 导入失败 | 是否原始 JS、入口类与 key 是否有效、版本是否有效、最低应用版本是否满足 |
| 搜索入口出现但打不开 | 是否把可选块留下空函数；JS 参数顺序是否写反 |
| `Invalid data` | 详情标签是否对象、列表是否 `{comics, ...}`、章节是否 `{images: string[]}` |
| 封面失败而正文正常 | `onThumbnailLoad` 是否同步，是否补了封面自己的请求头 |
| 追更一直无变化 | `updateTime` 是否可靠且符合日期格式，是否仅在同一天内更新 |
| 章节乱序或跨章错误 | 整数对象键排序、重复章节 ID、分组顺序及图片数组顺序 |
| 收藏操作缺少第四个参数 | 当前 `addOrDelFavorite` 只接收三个参数 |
