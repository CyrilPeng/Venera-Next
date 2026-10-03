# 旧漫画批量归档执行器退役核对

日期：2026-10-03。基线：9d02d33。此处只退役无调用的执行代码，保留旧格式元数据定义；不宣称当前导入器支持 .venera-comics。

| 格式/流程 | 当前入口与结构 | 处置 |
|---|---|---|
| CBZ/ZIP、7Z/CB7 导入 | ImportComic.cbz/multipleCbz → CBZ.import；ComicMetaData 是单本元数据 | 保留，兼容回归通过 |
| PDF/EPUB 导入 | ImportComic.pdf/epub → PdfComicImporter/EpubComicImporter | 保留，全量回归通过 |
| CBZ/PDF/EPUB 导出 | LocalComicsPage.exportActions → exportLocalComics → 各格式导出；多本压成 comics_export.zip | 保留，不把外层 ZIP 当作旧批量格式 |
| 应用数据归档 | AppDataArchive，应用配置/数据库快照；支持相应 .venera/.picadata 容器 | 保留，与 .venera-comics 不是同一协议 |
| 旧 .venera-comics 批量格式 | 根 metadata.json 包含 version/exportTime/totalCount/comics；每本含 sourceDirectory、源标识与章节数据 | 保留 ComicExportInfo/ComicExportMetadata 的纯格式编解码，迁到 legacy_comic_metadata.dart |
| ComicExporter.exportComics | 无生产、测试、脚本、JS/API 调用；仅经 import_export.dart 的 export 潜在可达 | 删除未使用的临时复制、ZIP 写入和进度/取消执行代码 |
| ComicImporter.importComics / ImportResult | 无调用；ComicImporter 字符串只是内部日志标签 | 删除未使用的解压、源检查、重复检查和本地写入执行代码 |

全仓库精确类名检索与候选清单相互印证；同名 exportComics 在收藏仓储和页面仍有真实用途，不作误删。旧执行器是没有调用入口的残留实现，不能因为路径被 barrel 导出就当作使用中的功能，也不能说当前单本 CBZ 解析器承接了旧批量容器。

legacy_comic_metadata.dart 不导入 LocalManager、Widget、文件系统或压缩包；删除仅服务旧导出器的 fromLocalComic 工厂。保留模型字段、平铺/分组章节、格式校验与版本封装原逻辑。既有测试迁为 legacy_comic_metadata_test.dart，直接引用该模型，测试用例未删除。生产 import_export.dart 不再导出旧执行器或该兼容模型。

旧文件路径加入退休入口检查，移除其过期“必须通过聚合入口导入”映射；独立模型加入业务边界门禁。当前图含 377 个 lib 文件，其中 376 个从 main.dart 可达，唯一例外为明确保留的兼容格式模型。

验证：旧元数据、当前导出服务和 CBZ 兼容专项 38 项通过；全量 Flutter 1306 项通过；分析零 error/warning、65 个既有 info；结构/73 个业务入口、Python 57 项（3 项平台工具跳过）和 Git 依赖检查通过。日志 output/legacy-codec-{targeted,full,analyze}.log。

公开符号清单中的 ComicExporter、ComicImporter、importComics 三项已处理；其他 33 项待调查。原 JSON 保留历史定位并增加本次 resolution，未将旧快照伪装成重新扫描结果。P6 数据原子性、P7 完整格式/错误矩阵及平台验收仍未完成。
