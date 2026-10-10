# Local storage writer audit

2026-10-09 R2 update: synchronous `write` also uses AppDataOperations.accessSync. Core owns a separate application-directory lease from startup recovery through final persistence and store closure, excluding other interactive/headless cores in that directory. Download commits retain queue ownership and are outside the application sync snapshot. The [R2 audit](storage_configuration_completion_2026_10_09.md) and [batch report](completion_batches_2026_10_09.md) list writers, external-path boundaries and evidence. The 2026-10-03 results below retain their original commit ownership.

Date: 2026-10-03. Baseline: 8c238c6. Scope: LocalManager repository mutations and their production callers; not proof that every filesystem or external writer is controlled.

| Entry | Production caller/owner | Decision |
|---|---|---|
| add / remove | Directory-import registration/rollback, CBZ restore callback; local scanning registers inside exclusive recovery | Route synchronous mutation through LocalComicStorageGuard.write; unrelated callers cannot write during exclusive work, accepted import/exclusive owners can |
| migrateLegacyPageOrder | Reader loading enumerates images then persists migration/history | Hold an import reservation for the entire conversion; wait for exclusivity, drain accepted work on exit; non-local histories remain no-op |
| isDownloaded | Favorites download selection, detail actions/error page; no production fourth chapter argument | Remove unused chapter-update branch/argument; predicate no longer implicitly calls add |
| removeComic | One test, no production caller | Remove forwarder, test guarded remove directly; mark historical test-evidence candidate resolved |
| DownloadQueue.commitComic / directory allocation | Queue owns task, stop/cleanup and commit lifetimes | Keep existing queue coordination: exclusive storage refuses active/suspended queues and drains pending work; do not add nested import ownership |
| Deletion, initialization, migration/recovery | Coordinated SQL and quarantine journal; startup | Deletion/migration hold exclusivity; initialization precedes readiness. External SQL still requires separate constraints |

Each guard uses instance-specific Zone keys and live owner tokens. write is synchronous and cannot wait on its own exclusive operation. Accepted import/exclusive owners can finish during exit draining, new writers cannot, and bound callbacks from expired owners are rejected. Async child work must still be awaited by its owner; inheritance is not a permanent lifetime grant.

Production CBZ/PDF/EPUB registration runs inside runImport; directory recovery inside runExclusive; production backup restore uses CBZ.import. Injected backup-test import/register callbacks are not real file conversion. Download queues have separate explicit ownership rather than contributing to the import count.

Six new regressions cover unrelated writes, accepted import exit draining, two expired-owner types, actual manager writes and page conversion waiting. Full Flutter: 1338 passed before the last page-wait test; final targeted: 20 passed. Analyzer zero errors/warnings, 65 existing infos; structure/75 entries, 57 Python tests (three platform-tool skips), Git dependency/format gates passed. Logs: output/local-write-owner-{targeted,final-targeted,full,final-analyze}.log.

Open: retained public repositories/external SQL, cross-process changes, SAF providers, staging while reading, full download-shutdown matrix and post-commit publication outcomes. This audit does not replace overall P4/P6/P8 acceptance.
