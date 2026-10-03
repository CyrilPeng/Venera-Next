# Repeated workflows and shared mechanisms

Date: 2026-10-03. Code baseline: 8f77c1c, with existing user workspace changes. This delivers P7.3's comparison, not completion of P7 protocol, error or lifecycle acceptance. Paths are relative to the repository root.

## Five workflows

| Workflow and evidence | Scheduling/deduplication | Progress, cancellation and ownership | Commit boundary and reuse decision |
|---|---|---|---|
| Source updates: `lib/features/comic_source/source_update_service.dart` | Reject concurrent updates of one source; share update checks through `_checking`; tokens keyed by source | Each update owns Dio; cancellation releases the key immediately; finally checks token identity so old cleanup cannot remove a retry | replaceScript validation checks source/repository identity. UI cancellation ends at commit. Keep the update protocol separate from subscriber-based cancellation |
| Images: `lib/network/shared_request_stream.dart`, `lib/features/reader/image_precache.dart` | First subscription starts shared work; prefetch deduplicates by provider | Last subscriber cancels the request. Prefetch releases its own listener and pending cache listener, retaining live consumers and one frame after decoding | Downloaded bytes and Flutter decoded-image/cache lifetime are separate boundaries; a view must not cancel another consumer's image |
| Archive download/export: `lib/features/local_comics/archive_download_task.dart`, `lib/features/local_comics/import_export/comic_export_service.dart` | Generation invalidates old runs; resume drains previous work/cleanup; export processes comics sequentially | Downloads report bytes/speed and preserve owned workspace for resume; exports report comic count and retain staging through save | Native extraction must drain before cleanup. Registered comics own output. Cancellation cannot undo a completed save. Keep download/conversion/save adapters; do not clean files early through Future.any |
| Application sync: `lib/features/sync/data_sync_controller.dart`, `lib/features/sync/data_sync_transfer.dart` | Controller owns active/pending tasks and automatic scheduling; transfer owns its remote | RequestScope cancellation closes remote but operation still awaits cleanup; transfer owns download workspace | Upload acknowledgement precedes old recovery-point deletion; download compares versions and distinguishes no-op/applied. Participant completes commit/rollback after replacement starts; applied imports still notify. Lost response does not prove remote write failed; no unconditional write retry |
| Document import: `lib/features/local_comics/import_export/document_import.dart`, `pdf_import_batch.dart` in that directory, `lib/features/local_comics/local_storage_guard.dart` | PDF batch is sequential, distinguishes duplicate files/titles; guard coordinates imports and migration/recovery | File/page progress; cooperative DocumentImportCancellation; selections disposed in finally; exit rejects new work and drains accepted storage operations | Successful importFile includes registration; late cancellation cannot relabel it. Session.finish only creates a model. Keep batch outcomes and storage admission separate from network scheduling |

## Existing reuse and its limits

| Mechanism | Real consumers | Limits |
|---|---|---|
| `lib/foundation/throttled_task_runner.dart` | History refresh and WebDAV library directory refresh (four workers, no batch delay) | Bounded concurrency/batch throttling only. Cancellation stops scheduling, not active work. Callers own per-item error handling |
| `lib/network/request_scope.dart` | Chapter loading, reader controller, sync transfer, JS engine, follow updates | Parent cancellation, timeout, HTTP token and interruptible waiting. run can finish before underlying work stops; dispose releases timer/parent linkage and is not cancel |
| `lib/foundation/sqlite_transaction.dart` | Local/history/favorites repositories and favorite import | Synchronous SQL/savepoints only, no asynchronous or filesystem transaction; preserve operation and rollback failures |
| `lib/foundation/directory_replacement.dart` | Application-data import recovery | Caller stops users first. Backup/restore and path/type checks do not establish full symlink-chain or crash recovery correctness |
| DocumentImportSession | PDF and EPUB page paths, covers, model creation and abort cleanup | Preserve decoder differences; not an atomic filesystem/database transaction |

`lib/features/follow_updates/follow_update_queue.dart` is intentionally separate: global concurrency, per-source concurrency and per-source spacing allow unrelated sources to advance. Replacing it with batch throttling changes behavior. Bytes, comics, pages and applied versions likewise do not share one meaningful percentage.

## Follow-up and acceptance

1. Keep the existing used primitives; this comparison adds no execution framework or forwarding wrappers. Future extraction must identify at least two semantically identical consumers, deleted duplication and reentry/failure/cancellation tests.
2. P7.4 continues retry/progress review. Read retries require explicit attempt limits, timeout, cancellation and original-error retention. Writes require idempotency/commit evidence before retry reuse.
3. P6 still needs deletion atomicity, symlink policy and coverage of all storage writers; a guard alone does not prove every writer participates. P4 needs shutdown/failure ownership coverage; P7.5 needs remaining structured errors and boundary translation.
4. Existing regression entry points: `test/network/{request_scope,shared_request_stream}_test.dart`, `test/foundation/{throttled_task_runner,sqlite_transaction,directory_replacement}_test.dart`, `test/features/follow_updates/follow_update_queue_test.dart`, `test/features/local_comics/local_storage_guard_test.dart`, `test/features/local_comics/import_export/{pdf_import_batch,comic_export_service}_test.dart`, `test/features/sync/data_sync_transfer_test.dart`. Braces abbreviate separate filenames.

Documentation-only stage: implementations and test entry points inspected; full tests not repeated. Previous code-stage logs: output/legacy-codec-full.log (1306 passed), output/legacy-codec-analyze.log (zero errors/warnings, 65 infos). These results do not close the outstanding acceptance items above.
