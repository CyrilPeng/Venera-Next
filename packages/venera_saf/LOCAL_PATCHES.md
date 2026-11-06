# venera_saf 1.0.0 maintenance

This package is project-authored code under GPL-3.0-or-later, fixed by the
application commit and the complete `SOURCE_MANIFEST.json`. It replaces the
former fixed `venera-app/flutter_saf` wrapper, whose license was a placeholder;
none of that wrapper's Dart, Kotlin, JNI or build source is retained. Matching
class names preserve the application interface, not third-party provenance.
No third-party source is vendored in this package.

## Persisted paths and permissions

Existing `android://<treeDocumentId>/<display names>` paths remain intact. Tree
IDs can contain `/` and are resolved by the longest complete known tree ID,
never as URI authorities. Android's persisted URI grants remain the authority
for access. The first attachment remembers their IDs in application-local
preferences; later discoveries add IDs. A revoked longer grant must fail
instead of redirecting a stored path through a shorter overlapping grant.
Existing grants, saved comic references and data are not cleared.

Different active provider authorities sharing one stored tree ID fail with
an explicit ambiguity error. Metadata uses UTF-8 JSON, including display names
containing Chinese, emoji, colons and pipes. Unknown providers, revoked access
and missing children have separate errors; path recognition does not fall
back to a normal file when an Android path is unavailable. Names containing
path separators, NUL, `.` or `..` cannot be represented by this historic scheme
and fail explicitly. Exact and duplicate display names are checked.

Creation preserves existing file contents; opening in a truncating mode performs
truncation. Copy rejects normalized self-paths and matching provider document
identities across grants before opening the destination for writing. A provider's
unexpected created name/type is rejected, and only the
newly returned URI absent before that create call is eligible for cleanup.
Authorized roots cannot be deleted or renamed. Directory deletion without
`recursive` rejects nonempty directories. Provider rename supports the same
parent only and rejects observed collisions; provider APIs do not promise
atomic exclusive creation or collision-free renames across independent apps.
File locking, watching, atomic createTemp/exclusive creation and setting file
timestamps are explicitly unsupported. Unsupported provider seek, length,
truncate or flush operations retain their native IO error.

## Descriptor ownership and workers

The original Java `ParcelFileDescriptor` stays alive through file close, so a
cloud provider's commit/close lifecycle is not shortened by FD duplication.
Native `read`/`write`/64-bit seek/length/truncate/flush use the descriptor directly;
file bytes do not cross JNI. JNI paths and errors use UTF-8 byte arrays, avoiding
modified UTF-8 for user text. `checkError` and `close` run at the final explicit
close, and close failures are propagated even though ownership is released.
Finalizers supply best-effort cleanup for abandoned leases.

Generation tokens are independent of OS descriptor numbers. Native operations
borrow reference-counted resources so a cancelled generation cannot close a
later reused FD. Cross-isolate open uses a two-stage handoff: retain/acknowledge,
then sender release/adopted; a caller receives the file only after the worker's
lease has been released. Async data/metadata work runs in a per-isolate worker.
Each file rejects simultaneous pending operations; explicit close finalizes
the Java owner in the calling isolate. Provider close can itself take time.
Initialization is idempotent, errors retain stacks, unexpected worker exits
fail pending tasks, and disposal drains existing operations before shutdown.

Streams close on success, failure and cancellation. Cleanup preserves the
primary read/write error, including errors from cancelling a failed copy's
input stream. Empty write sinks still create a file. The app's PDF
worker returns decode errors and fatal/exit events to its parent, closes output
on failure, and disposes its SAF worker before reporting completion.

## Verification and updates

Host adapter/worker and existing directory-copy regressions cover Unicode,
typed views, creation, append, copying through grant aliases, errors, stream cancellation, cycles,
idempotent initialization, draining, fatal exit and retry. The C++ regression
runs 200 retain/release, IO, error and FD reuse cycles, including >2 GiB sparse
seek/length/read/truncate and provider close errors. It runs with Linux
ASan/UBSan in CI. Release-mode Windows C++ checks have passed locally.

`tool/saf_provider_probe/prepare_probe.py` builds two isolated test APKs and a
minified consumer Release. It exercises real Android DocumentsProvider grants,
longest IDs, authority ambiguity, restart, Unicode, modes, 64-bit operations,
stream cancellation, remote errors and the original PFD's close callback.
Its provider data is confined to the test package. These checks do not establish
every external cloud vendor's behavior; retain representative device/provider
evidence when changing storage semantics. Full Android/TV app builds also check
the native ABI and retained notice.

Before a source change, update the changelog and maintenance record, run the
appropriate host, sanitizer, provider and app checks, then refresh every
project-file hash in the manifest and verify the dependency inventory.
