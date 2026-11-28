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
