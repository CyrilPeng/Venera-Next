# Retirement review for unused comic batch archive executors

Date: 2026-10-03. Baseline: 9d02d33. Only unused execution code is retired; historical metadata definitions remain. This does not claim current importers support .venera-comics.

| Format/flow | Current entry and structure | Decision |
|---|---|---|
| CBZ/ZIP, 7Z/CB7 import | ImportComic.cbz/multipleCbz → CBZ.import; ComicMetaData describes one comic | Retain; compatibility regressions pass |
| PDF/EPUB import | ImportComic.pdf/epub → PdfComicImporter/EpubComicImporter | Retain; full regression suite passes |
| CBZ/PDF/EPUB export | LocalComicsPage.exportActions → exportLocalComics → format exporters; batches become comics_export.zip | Retain; the outer ZIP is not the historical batch format |
| App-data archive | AppDataArchive creates app configuration/database snapshots and handles corresponding .venera/.picadata containers | Retain; this is a different protocol |
| Historical .venera-comics | Root metadata.json contains version/exportTime/totalCount/comics; each entry includes sourceDirectory, source identity and chapters | Retain pure ComicExportInfo/ComicExportMetadata codecs in legacy_comic_metadata.dart |
| ComicExporter.exportComics | No production/test/script/JS/API caller; only potentially reachable through a barrel export | Delete unused temporary copying, ZIP writing and progress/cancellation execution |
| ComicImporter.importComics / ImportResult | No caller; the ComicImporter string is an internal log label | Delete unused extraction, source/duplicate checks and local-write execution |

Exact-name repository searches confirm the candidate evidence. Other exportComics methods in favorite storage and the page have real callers and remain. A barrel export is not evidence that these residual executors implement an active feature; the current single-comic CBZ parser is not a replacement for the historical batch container.

legacy_comic_metadata.dart imports no LocalManager, widgets, filesystem or archive library. The fromLocalComic factory used only by the retired exporter is removed. Model fields, flat/grouped chapters, validation and version envelopes retain their existing behavior. Existing tests are renamed to legacy_comic_metadata_test.dart and import the codec directly; no test cases are deleted. The production import_export.dart barrel exports neither the retired executors nor this compatibility codec.

Retired paths are enforced, and obsolete barrel-import mappings are removed. The codec is enrolled in the business boundary gate. The current graph contains 377 lib files, 376 reachable from main.dart; the only exception is this explicitly retained historical codec.

Validation: 38 targeted metadata/current-export/CBZ compatibility tests pass; full Flutter suite: 1306 passing; analyzer: zero errors/warnings, 65 existing infos. Structure/73 business entries, Python 57 tests (three platform-tool skips) and Git dependency checks pass. Logs: output/legacy-codec-{targeted,full,analyze}.log.

ComicExporter, ComicImporter and importComics are resolved in the candidate inventory; 33 investigation items remain. The JSON retains historical locations with a resolution entry rather than pretending to be a fresh scan. P6 data atomicity, complete P7 format/error matrices and platform acceptance remain incomplete.
