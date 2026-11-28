# Windows 桌面字幕作者工具

Python 3.11、Pillow 和 RapidOCR 在本机处理一章图片或 CBZ。使用带 Tk 的 Python 可打开校对窗口。PP-OCRv4 中文模型随 `rapidocr-onnxruntime` 的 Python 包安装，下载依赖后可断网使用。`--language` 标记原文语言，模型支持的字种由实际权重决定。

```powershell
py -3.11 -m venv .venv
.venv\Scripts\python -m pip install -r tool/comic_subtitles/requirements.txt
.venv\Scripts\python tool/comic_subtitles/author.py my-chapter.json init chapter.cbz --language ja
.venv\Scripts\python tool/comic_subtitles/author.py my-chapter.json ocr
.venv\Scripts\python tool/comic_subtitles/author.py my-chapter.json editor
.venv\Scripts\python tool/comic_subtitles/author.py my-chapter.json export revision-1
```

`init` 记录自然排序、页 ID、原始字节摘要及应用 EXIF 后的尺寸。`ocr` 每处理一页便保存工程，重新运行会继续待处理和失败页。用 `ocr --page 2` 重试第二页。`show 2` 显示耗时、状态、方向、置信度和逐框原始文字。无字页也可手工加句。OCR 的输入至多为 2048 × 2048，原始四边形已换算回正向原图。主方向是根据识别框宽高给出的初值。

校对窗口以橙框显示识别结果、蓝框标出对白和读序。拖框可加句、调整区域或指定拆分边界。按 Ctrl 选择多句后可合并，修改文字会沿用对白 ID。每次保存同步保留原始框、源码修订以及拆并前的对白。

也可以用 `edit 1 operations.json` 一次应用一页的操作，文件内容为 JSON 数组。`show 1` 可查实际 ID。

```json
[
  {"op":"edit","id":"原对白ID","text":"山の","direction":"vertical-rl"},
  {"op":"merge","ids":["原对白ID","下一句ID"],"text":"山の下"}
]
```

`order` 的 `ids` 列出全页读序。`split` 的 `id` 为原对白，`parts` 逐项提供 `text` 与 `[左,上,右,下]` 的 `area`。`add` 同样接受文字和区域。混合语言章可用 `{"op":"language","language":"zh"}` 调整单页原文语言。

每次 `export` 使用新目录，发布完整的 `book.acbf` 和 `book.pages.json` 后再切换手机上的挂载。修订目录可独立发送，作者继续在本机工程中校对。

## 翻译与审校

以下命令均接在 `python tool/comic_subtitles/author.py my-chapter.json` 后。

1. `prepare en requests.json` 按页和读序准备英文稿，每批最多 24 句。`--page 2` 指定单页，`--glossary terms.json` 附加作品术语表，内容如 `{"山道":"mountain path"}`。
2. 可将 JSON 交给译者。每份回包为一个对象，含原 `batch`、`target`、`items`，每项保留原 `id` 和整数 `revision`，将 `text` 改为译文。用 `receive reply.json` 收回一个批次。也可以运行 `send 批次ID --endpoint 服务URL --model 模型名` 查看接收方与请求全文。再次运行并加 `--allow-endpoint 服务URL` 即发送这一批。接口采用 Chat Completions，可选密钥来自本机 `SUBTITLE_TRANSLATION_KEY`。
3. 打开 `editor`，选中对白并点「审校选中对白的译文」，或用 `approve 页码 对白ID 批次ID --text "审校后的译文"`。只有当前原文修订的已确认译文进入阅读层。
4. 缺句、重复、未知和过期 ID 会列在回包报告中。再次 `prepare en 新文件.json` 仅准备待补译内容，`--redo` 生成新候选。`show 页码` 可查看此前各次确认。增加其他目标语言后用 `export 新修订目录` 发布。

## 重新编辑与 CBZ

`pack chapter.cbz` 逐页复制原图并将 0.1 字幕放进归档。`pack clean.cbz --plain` 导出纯图片。建立新工程时使用 `python tool/comic_subtitles/author.py restored.json import chapter.cbz`。只有外挂文件时，把原图目录或 CBZ 作为输入并加 `--revision 字幕目录`。同语的不同译本可用 `en`、`en-x-poetic` 区分。发布清单包含原始识别框、校对文本、已确认的翻译修订和拆并记录，发送前可直接查看 JSON。

在应用内导入此单章 CBZ 后，从「本章字幕」点「载入归档内的字幕」并保存。在同一面板可将已核验的整章导出为带字幕 CBZ。书库的普通 CBZ 导出入口用于分享原图。

双向验证命令为 `python tool/comic_subtitles/interop.py`，运行前需安装 Pillow 并在项目根目录运行 `flutter pub get`。单独维护的格式正文与离线样例见[规范目录](../../spec/comic-subtitles/README.md)。
