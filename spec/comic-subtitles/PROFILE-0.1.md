# Comic Subtitles 0.1 · 章节交换候选

一份修订由 UTF-8 ACBF 1.1 正文 `book.acbf` 和 UTF-8 JSON 清单 `book.pages.json` 组成。单发时两个文件放在同一目录，嵌入 CBZ 时放在归档根目录。媒体类型沿用 `application/xml` 和 `application/json`。完整向量见 [fixtures](fixtures)。

| 字段 | 约定 |
| --- | --- |
| `profile`, `requires` | 版本标识为 `comic-subtitles/0.1`。必需能力列表当前接受 `editorial-1`。读到未知版本或必需能力时提示更换读取器并保留当前挂载。可单独打开 ACBF 阅读基础文本。 |
| `workId`, `acbfSha256` | 前者为发布工程的稳定标识，本版每工程交换一章。后者为最终 XML 原始字节的小写十六进制 SHA-256。改名重写图像引用后须重算。 |
| `pages` | 顺序与 ACBF `body/page` 逐一对应。每页含唯一 `id`、原图文件字节 `sha256`、EXIF 正向 `[width,height]`、`sourceLanguage` 和 `layers`。作品或章节名称用作提示。 |
| `layers` | 每个键对应一个 ACBF `text-layer@lang`，值按该层 `text-area` 的顺序逐项引用对白 ID。源层每句恰好出现一次。译层可缺句或重复同一 ID 以表达拆框。多段文本按出现顺序直接拼接，段间空白由文本显式提供。同语译本用 BCP 47 私用后缀区分，例如 `en-x-poetic`。 |
| `editorial` | `editorial-1` 的每页数据包含 `observations`、`dialogues` 和 `lineage` 三个有序数组。`dialogues` 顺序等于源层读序。修订中对白 ID 跨页唯一。 |
| `observations` | `id`、`text`、`quad` 四个正向原图像素顶点、`confidence`（0 至 1）、`direction`。方向取 `horizontal-tb`、`vertical-rl` 或 `vertical-lr`。 |
| `dialogues` | 每句含 `id`、校对 `text`、`revision` 正整数、`reviewed` 布尔、`direction`、`area` 和对应的观察 `observations` ID 数组。矩形为 `[左,上,右,下]`，右下边界排除。`sourceHistory` 可列出历史修订的 `revision`、`text` 和 `reviewed`。 |
| `translations` | 可选字典。每种语言或译本对应已确认的修订数组，记录 `batch` 身份、`sourceRevision`、`text`、`approved:true`。最后一条与当前原文修订相符的记录提供该层文本。每个 ACBF 段的几何和分段从 XML 取得。 |
| `lineage` | 每次真实拆并追加 `{operation,old,new}`。`operation` 为 `split` 或 `merge`，`old` 存替换前的对白记录，`new` 存按读序产生的新 ID。下一次拆并可继续引用其中的 ID。普通改字或移动区域沿用原 ID。 |

基础样书支持内嵌 PNG。候选作者交换使用本地相对图名，拒绝绝对路径、目录跳转、远程资源和 XML 外部声明。每章两个字幕文件合计上限 16 MiB，2048 页、50000 个文本区域，每页至多 6400 万像素。普通 CBZ 逐页直接复制原始字节。带字幕 CBZ 同时重写封面和正文相对图名，再发布配套清单。首版发布矩形对白区域，其他 ACBF 多边形仍可按其外接矩形阅读。

## 兼容与维护

基础 ACBF 保留语言、区域、读序和文本。早期 `venera-subtitles-experiment-1` 清单额外保留原图绑定和对白身份。0.1 为两者补上校对、历史和拆并映射。旧应用可单独读取 ACBF，旧清单缺失的编辑历史只能由原作者工程提供。未知可选字段宜原样携带，不能保真的编辑器应只读打开。

该目录是规范、版本历史、原创样例和离线验证命令的迁仓单位。贡献者提交格式变更时须提供稳定样例、旧读取器行为和迁移说明。拆仓前由权利人确认规范、程序和素材许可，迁移时保留目录历史及署名。应用固定到通过互通的版本，旧路径保留索引。0.1 处于试用期。
