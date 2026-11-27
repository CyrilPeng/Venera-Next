# 漫画外挂字幕互通样例 · Comic subtitle interoperability examples

本目录可单独复制给字幕工具或阅读器作者，所有路径均相对于本目录。`fixtures/dialogues.json` 是手工校对的参考输入与预期结果，`fixtures/three-pages.acbf` 是可独立打开的 ACBF 1.1 对照文件。交换格式仍处于选型阶段。PNG、笔画、对白和标注均为本实验原创，现阶段沿用宿主仓库的 GPL-3.0 许可。

## 离线复现

在本目录使用 Python 3.10 或更高版本，检查器只需标准库。默认只读。第二条命令将独立字幕、三张图片与 CBZ 写入指定的新目录，二者使用相同的 `book.acbf` 字节。这样可以单独传 `book.acbf` 到一台已有对应图片的设备上，也可以打开整个归档。

```shell
python check_examples.py
python check_examples.py --export-dir mountain-path-example
```

| 正文页 | 已知输入 | 其他实现应得到的结果 |
| --- | --- | --- |
| 1 · 山脚，192 × 256 | 日文右列“山の”、左列“下”合成对白 `ridge-foot`，人工确认中文“山脚下” | 搜“山の下”或“脚下”均命中同一处 `[52,32,139,119]`。更改中文时需保留该对白身份。 |
| 2 · 入口，384 × 192 | `gate-entry` 跨过中线，原文和译文都含“入口” | 搜“入口”得到一个结果。在右半先读、两半上下叠放的 192 × 384 画布上，高亮 `[0,46,56,108]` 和 `[136,238,192,300]`。交换切片顺序时，两个高亮跟随原图移动。 |
| 3 · 日出，192 × 768 | 只有中文原文；上方是“山口”，下方是“日出” | 搜“日出”命中 `dawn-sunrise` 和 `[50,642,150,706]`。阅读器的验收要求该区域进入视口。 |

坐标对应正向完整原图，矩形按左、上、右、下排列，右、下边界排除。页码从 1 开始，`dialogues` 的顺序是阅读顺序。`sourceLanguage` 标明哪一层是原文，`observations` 保留分组前的文字与框，`texts` 保存可显示的各语文本，`reviewed` 记录已由人工确认的语言。搜索用例中的 ID 来自校对稿；ACBF 读回的独立比对项是正文页、区域、语言和文本。

## 哪些信息能往返

| 信息 | 本样例的 ACBF 1.1 基础映射 | 后续互通评审 |
| --- | --- | --- |
| 顺序、语言、文本、区域 | 每页按文档顺序写入 `text-layer` 和 `text-area`。矩形用四个顶点表示。三页、四句、六处语言区域可读回。 | 用两种语言的分段数、布局区域各不相同的样本验证跨语言关联。 |
| 正文图像 | 独立示例通过 `#id` 引用内嵌 PNG，导出包改用相对文件名 `001.png` 至 `003.png`。 | 对照稿中的 SHA-256 能定位改名原图。重复内容得多个候选，同名同尺寸替换得零个候选，需提示复核。 |
| 对白身份与校对记录 | 对白 ID、识别小框、人工校对状态和原文书写方向在此基础映射中都会丢失。 | 分别评估兼容约定、外置清单或独立表示。每一种候选均需提供相同的往返结果和损失清单。 |

检查器用六项离线检查覆盖 PNG 尺寸与指纹、基础表示往返、四类字段丢失、子串搜索定位、CBZ 重打包与版本歧义、切片高亮。它只处理仓内已知样本。真实 OCR 质量、其他阅读器的绘制、长条滚动和设备功耗在应用原型阶段验证。

**校验来源**　自制 ACBF 使用上游提交 `e033e004e2897fe20ad09cbd649a8ba1d6b38d09` 的 `acbf-1.1.xsd` 核验，XSD 的 SHA-256 为 `154e997a600143adf205bfcad427ef6e6fa4a6fcfce10cece4d58a0b64c2ac32`。需要复核结构的维护者可用本地 XML Schema 校验器加载此固定版本。常规样例检查可完全离线运行。[上游 XSD](https://github.com/ACBF-Advanced-Comic-Book-Format/ACBF/blob/e033e004e2897fe20ad09cbd649a8ba1d6b38d09/XML%20Schema/acbf-1.1.xsd)

## English quick start

Copy this directory and run `python check_examples.py` using Python 3.10+ and its standard library. Use `--export-dir mountain-path-example` to create a new directory with the three PNGs, a detached ACBF document and a CBZ containing the same document. All images and dialogue were created for this experiment. The host repository's GPL-3.0 license applies at this stage.

The editorial fixture and expected search targets are in [dialogues.json](fixtures/dialogues.json). The independent ACBF 1.1 example includes the original images. [Open the ACBF sample](fixtures/three-pages.acbf)

Pages are one-based. Rectangles use upright, full-image pixel coordinates with exclusive right and bottom edges. List order is reading order. Search `山の下` or `脚下` to find the first page's merged vertical lines, `入口` to find one dialogue across both halves of the second page, or `日出` to find the lower region on the untranslated third page. A reader should scroll that region into view.

The basic ACBF mapping preserves language, text, region and order. Stable dialogue IDs, OCR fragments, review state and source writing direction need an additional convention. Exact PNG digests survive a rename and repack. Duplicate matches and changed bytes require review. These examples are for evaluating candidate formats and future independent readers and writers.
