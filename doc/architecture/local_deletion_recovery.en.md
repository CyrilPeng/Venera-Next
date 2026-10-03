# Local deletion recovery protocol

Date: 2026-10-03. Based on 3a6acef; not proof of all-platform, power-loss or external-writer correctness.

Preflight checks recorded/canonical paths and retained references. Before moving a directory, local.db records original path, sibling quarantine path and uncommitted state in local_deletion_journal. Names include journal id/time, existing destinations are not overwritten, and overlapping parent/child candidates stage only the parent. SAF uses same-directory rename, without relying on unimplemented createTemp/resolveSymbolicLinks.

| State | Recovery at startup or the next exclusive storage operation |
|---|---|
| Uncommitted, quarantine exists, original absent | Rename back, then clear journal |
| Uncommitted, quarantine absent, original exists | Move never started or rollback finished; clear journal |
| Uncommitted, both exist or both missing | Preserve evidence/files and fail; never overwrite or guess |
| Committed, quarantine exists | Delete only quarantine, then clear journal; preserve new files at original path |
| Committed, quarantine absent | Cleanup finished; clear journal |
| Invalid sibling relationship/quarantine name | Reject recursive I/O and retain evidence |

Record deletion and the committed flag share one SQLite transaction. Associated cleanup uses the three-database transaction and history queue; chapter/non-associated deletion uses a local transaction. Record/directory/chapter snapshots are captured before asynchronous preflight and checked inside the transaction; changes during staging reject commit and restore directories. Recovery failures retain both original and recovery errors.

LocalManager recovers after opening the database but before loading library paths/tasks, and again before every exclusive storage operation including migration. Unresolved recovery errors block further operations. Post-commit notification failure cannot restore files for already-deleted records. Cleanup failure leaves durable retry evidence. Old local databases gain only the journal table; comic/chapter formats stay unchanged. Application sync snapshots exclude local.db, so machine-local cleanup intents are not synced to other devices.

Validation: 22 original deletion regressions; seven journal tests; 20 final journal/manager-restart tests; 1330 full Flutter tests; analyzer zero errors/warnings and 65 existing infos; structure/75 business entries, 57 Python tests (three platform-tool skips), Git dependency and formatting checks passed. Logs: output/deletion-journal-{targeted,recovery,final-recovery,full,final-analyze}.log. Reopening a connection/recreating a manager validates recovery states, not actual process termination or power loss.

Open: SAF provider rename/disconnection device matrix; forced termination and durability fault injection; coordination of all direct writers; external link/quarantine replacement; explicit post-commit publication outcomes; user recovery-conflict repair and active-reader staging lifetime. P6.7 remains partial. Do not manually delete uncommitted quarantine directories to bypass recovery errors; they may contain the only copy.

## Forced Windows subprocess termination

Added local_deletion_crash_probe/test using production LocalDeletionJournal, SQLite connection configuration and transaction utility in a separate Dart VM. Two attached fixture databases use minimal records tables to verify the three-database/journal protocol; this is not a process-kill test of the full Flutter app or comic repository schemas.

At each checkpoint the child writes a synchronous ready marker and blocks. The parent checks marker PID against its process handle, force-terminates that VM and waits for nonzero exit, without relying on child finally cleanup. Checkpoints: directories staged; three-database deletes/journal flag written inside an uncommitted transaction; transaction committed before cleanup. The first two retain/roll back records and restore directories; the last retains committed deletion, removes quarantine and protects newly created original-path files. Repeated recovery is harmless.

Initial PID checks rejected the dart.exe launcher's separate VM process. Direct dartvm invocation with explicit package_config then passed all three targeted and 1333 full Flutter tests. Final analyzer: zero errors/warnings, 65 existing infos; structure/75 entries, 57 Python tests (three platform-tool skips) and Git dependency checks passed. Logs: output/deletion-crash-{targeted,full,final-analyze}.log. Fixed a brace lint missed in the previous stage's late-added restart test.

Three deterministic Windows VM termination windows now have evidence. Full-application concurrent I/O, random interruption points, non-Windows platforms, SAF and power-loss/storage durability remain unverified.
