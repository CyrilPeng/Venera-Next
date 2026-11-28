# 交换约定版本

| 版本 | 兼容行为与向量 |
| --- | --- |
| 0.1 候选 | ACBF 加摘要绑定的清单。`fixtures/editorial.*` 涵盖两种英文译本、译文拆框、校对修订、识别四边形和一次合并。单发时两份文件随修订一起传输。 |
| experiment-1 | `check_examples.py --export-dir 新目录` 导出三页早期样书和页清单。该清单用于找回稳定页和对白 ID。 |
| 普通 ACBF 1.1 | `fixtures/three-pages.acbf` 内嵌三页原创 PNG，可独立打开，按层显示正文。 |
