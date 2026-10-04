# Initialization waits and failure-resource ownership

2026-10-03, current working tree. Scope: every ensureInit call and Init consumer under lib, plus the direct createCoreBootstrap steps. This is not acceptance of all application lifecycles.

## Wait boundaries

| Waiter | Startup owner | Failure and remaining boundary |
|---|---|---|
| SourceRepositories.migrate → appdata.ensureInit | CoreBootstrap.settings first awaits appdata.init | Migration now shares an in-flight Future. Failed persistence restores its flag/generated list while preserving a replacement list edited during the write; later calls may retry. |
| ComicSourceManager.doInit → JsEngine.ensureInit | bootstrap_core.sources first awaits JsEngine.init | Engine failure prevents source/store startup. Direct manager callers must still start the engine explicitly; ensureInit never implicitly starts it. |
| LocalManager._initialize → ComicSourceManager.ensureInit | CoreBootstrap.sources completes before stores | Production ordering is explicit; independent composition can inject initializeSources. Disposal is checked after waits and initialization failure releases its database. |
| LocalFavoritesManager._initialize → appdata.ensureInit | settings precedes stores; wait only when App.isInitialized | Connection generations prevent publication during closure; failed unpublished/published connections are released. In-memory defaults versus failed settings persistence still need a focused audit. |

Only Appdata, JsEngine and ComicSourceManager mix in Init. ensureInit waits, init shares an attempt, failure stays failed, and retryInit explicitly starts another attempt. CoreBootstrap caching a failed start does not provide rollback or service retry.

## Resource ownership and next work

| Owner/step | Existing mechanism | Outstanding work |
|---|---|---|
| CoreBootstrap | Ordered environment/settings/infrastructure/sources/stores/finish; source failure prevents waiting stores | initializeCoreStores joins every attempt and reverses local/favorites/history cleanup on failure, including partially initialized stores. Cleanup errors retain the original cause. CoreBootstrap now reverses successful stores and the acquired finish cache on subsequent startup failure. Infrastructure/source cleanup and normal shutdown are not yet unified. Legacy auto-sync migration now awaits writeImplicitData, restores its marker on save failure and triggers startup rollback. Other non-awaiting consumers still need migration. |
| Appdata | Write queue, file replacement and Init state | Full retry matrix for settings loading/device-ID persistence; absence of permanent handles is not atomic memory state. |
| JsEngine | Shared failure/disposal cleanup closes QJS/port, owned Dio and temporary clients; resetDio gracefully closes the old client; script loading checks disposal; old disposal preserves new singleton; disposed instances reject init/retry | Graceful closure allows accepted requests to finish. Full JS Promise/callback cancellation, native-platform behavior and unified core shutdown remain to verify. |
| ComicSourceManager | Per-source errors stay isolated; batch enumeration/runtime-provider failure removes this attempt’s Dart registrations and retained parser rollback restores JS slots/frees callbacks; handles commit before background init starts | Full reload now retains old Dart objects/JS registry, restores them after batch failure or an invalid existing file, and disposes old callbacks only on success; new bad files remain skipped and deleted files are removed. Listener/background init shutdown remains pending. Loading still uses the staged global registry without concurrent-reader snapshot isolation; provider external side effects are outside rollback. |
| CookieJarSql/SingleInstanceCookieJar | Constructor owns the connection and releases schema failures; repeated-opening init removed; idempotent dispose clears only its own singleton slot; concurrent explicit-directory creation shares a jar and corrupt-file failure can retry after repair | Cancellation during platform-directory resolution and cross-directory changes still need core lifecycle acceptance. Existing first-path singleton semantics remain; a directory argument is not a database-switch request. |
| HistoryManager | Shared initialization Future; history/image-favorite schemas use its own connection; ready follows retention and accepted writes; failure releases its connection; idempotent close and generation guards reject stale results | Store-group failure now drains accepted writes before close. Cross-phase/normal shutdown still need unified ownership. close does not cancel accepted independent-connection writes; complete shutdown must first waitForAsyncWrites. |
| LocalFavoritesManager | Shared initialization/generation/closeAndWait; closes failed connection | Store-group failure now calls closeAndWait; cross-phase failure and normal shutdown still need unified ownership. |
| LocalManager | Failed initialization releases database; disposed checks after source wait | Download restoration, storage reservations and complete background shutdown remain to verify. |
| CacheManager | Owns the connection returned by its constructor factory and releases schema failures; shared dispose drains accepted work before closing and clears only its own singleton; new work is rejected during closing | finish registers cache cleanup after acquisition; later startup failure drains it before stores. Normal shutdown still needs unified ownership. Scan failure remains logged while later queued work is allowed. |
| OpenCC | Shared initialization Future; failed attempt permits retry; complete decode/parse publishes an immutable table; successful repeated calls reuse it; CRLF and Unicode code points supported | Retains character-level, last-duplicate-wins mapping rather than phrase conversion. Device-level table performance remains part of overall performance acceptance. |
| translations / SAF / Rhttp | Required and optional startup steps are explicit | Verify actual plugin worker/runtime shutdown contracts rather than inferring them from API names. |
| headless | finally disposes sync, clears source save handler and awaits flushPersistence; failure emits an error and exits 1 | Other core resources still rely on process exit; this does not prove repeatable complete composition/shutdown, and native CLI results remain pending. |

Evidence scope: core_bootstrap_test covers ordering, shared startup and source failure preventing stores. This stage adds real migration write-failure/concurrency/retry/replacement tests. Outstanding items remain under P4.2/P4.4 and P8 overall acceptance; test counts do not replace them.

Store rollback evidence: core_store_startup_test covers real SQLite late-success reverse cleanup, synchronous initialization failure, cleanup-error aggregation and resource retention on success. This protocol only covers the startup stores group. Local downloads restore a paused snapshot; this cleanup must not be reused for normal shutdown with active downloads.

Later-phase rollback evidence: core_bootstrap_failure_test covers real SQLite/cache queue draining, reverse finish-failure cleanup, no duplicate failed-group cleanup, original causes retained after cleanup errors and resource retention on success. The shared exception is CoreStartupRollbackFailure. Failed startup stays cached; cross-instance automatic retry is not provided.

Implicit persistence boundary: Appdata.writeImplicitData now returns the actual queued save Future. Startup awaits migrateLegacyAutoSync, preserves unknown fields and restores absent/null markers after failure without overwriting a preference changed to a different value meanwhile. The sync controller persistence port now supports FutureOr; configure commit/rollback joins implicit and ordinary settings attempts. Ordinary upload/download now await initial/final state persistence and restore a cleared pending flag on final-save failure. onDataChanged background save errors are logged/published; complete background persistence draining/shutdown remains pending. Concurrent independent bootstrap migration isolation is not guaranteed.

Sync task persistence: initial-save failure prevents transfer; final persistence keeps the task in its queue, returning errors and restoring previous pending state on failure. Combined network/final-save failures retain both messages. Disposal does not cancel accepted file writes; flushPersistence now refreshes latest state and drains accepted writes; window close and headless command exit call it. flushPersistence itself does not stop scheduling. Windows now uses prepareForExit to freeze transfer/configuration admissions, await accepted configuration/upload/download work and flush; cancellation releases the generation-scoped barrier. Cross-source background work and full application exit ordering remain pending.

Exit persistence refresh: the controller tracks asynchronous save Futures; flushPersistence writes latest state then drains saves accepted meanwhile, allowing use after dispose and retry after prior failure. Window close awaits this even without uploads; failure releases import/download preparation and prevents normal exit. Headless commands await it in finally after successful core startup, returning an error exit on persistence failure.

Sync exit preparation: prepareForExit shares an attempt, pauses automatic scheduling, rejects new public transfers/configuration, joins accepted configuration (including its internal initial transfer) and active/queued tasks, then flushes. Failure releases automatically; success returns an idempotent generation-guarded release callback held by the window until cancellation/detachment. Other domains’ background tasks remain outside this scope.


## P4: Release cookies after infrastructure startup failure (2026-10-04)

- initializeCoreInfrastructure owns cookies newly opened by this phase. It materializes service attempts and wraps each in Future.sync, joining synchronous failures and late completions before rollback. Borrowed instances remain open; successful startup retains resources for the application.
- Three real SQLite regressions cover synchronous failure with a late service, persisted cookies after reopen, borrowed-instance retention on failure, and successful retention. Focused coverage including actual widget-free core startup and cookie lifecycle: 8 tests passed.
- This cleanup covers failure within infrastructure only. Cookie/JS/native cleanup after later sources/stores/finish failures and normal shutdown remain pending. Existing user edits are preserved.


## Source queue and plugin release protocol review (2026-10-04)

- Initial source loading now uses _mutationTail. The real QuickJS source_initialization_queue_test verifies that reload cannot replace the registry while startup awaits dependencies.
- Locked flutter_saf fe182cdf: SAFTaskWorker.dispose closes its response port and immediately kills the isolate. It neither drains _completerMap/completes pending Futures nor clears instance. init uses late isolate/sendPort fields, so this method cannot be indiscriminately used for partial initialization or active-task shutdown.
- Locked flutter_qjs 8feae95d: wrapper.dart converts Promises to Dart Completers completed only by resolve/reject callbacks. engine.close frees context/runtime without explicitly settling these Completers. Project runCode returns evaluate directly; the 15-second _initializeSource timeout stops waiting without cancelling the original Promise. The project engine boundary needs an observable disposal outcome; timeout is not background-work draining.
- rhttp 0.15.1 Rhttp.init delegates to RustLib.init. Its generated bridge exposes RustLib.dispose, documented as automatically handled when the app stops. This does not establish graceful per-client shutdown; actual call sites and active requests need verification.
- These findings come from locally resolved locked dependency source, not Android SAF or five-platform runtime acceptance. Dependency caches were not modified.


## P4/P7: Observable disposal outcomes for JS Promises (2026-10-04)

- runCode and JsCallbackScope.retain track asynchronous results. Engine resource release and scope closure settle outstanding waits with StateError, including child scopes. Synchronous results and settled Futures retain their behavior; ignored Promise errors follow the native bridge convention while explicit await still observes failures.
- Late resolution/rejection cannot settle a result twice. Native references in discarded results are recursively released only while the original runtime remains alive, with engine identity checked. Scope closure preserves sibling work and does not claim to cancel underlying JS/network side effects.
- Three real QuickJS tests cover never-settling evaluations/child callbacks, late function results/rejections after scope closure, successful sibling work, and ordinary sync/async values and original failures. Source transaction and engine lifecycle focused coverage: 20 tests passed.
- This establishes observable outcomes for waiting callers. Unretained direct JSInvokable use, source-manager background init shutdown composition, SAF worker and complete application resource release remain pending. Existing user edits are excluded.


## P4/P8: JS pool dependency injection and close ownership (2026-10-04)

- JSPool.create injects script loading and engine creation; the production default remains shared. Removed debugLoadJsInit, debugCreateEngine, resetForTesting and debugInstanceCount. Tests own and close independent instances.
- close shares one Future and immediately rejects init/execute while joining initialization and every engine close. A generation check prevents pre-close waiting tasks from entering a reopened pool. Synchronous close failures do not skip other engines; errors are reported after all attempts finish. Successful close allows explicit or on-demand reopening.
- Engines are staged until construction succeeds. Partial creation failure cleans acquired engines and retains initialization plus cleanup errors. Failed cleanup handles stay owned and block init/execute until close retry succeeds; already closed engines are not closed again. An initial focused regression caught early publication of failed handles breaking shared init; failed resources now publish after the entire rollback finishes.
- Six focused tests passed, including three shutdown/rollback regressions and actual Windows QuickJS execution across close/reopen. The initial full run overlapped implementation changes and is not final-state evidence; retry-targeted records the pre-fix failure and verified-targeted records final focused success.
- Core shutdown integration, infinite computation, unexpected isolate exit and all native platform termination behaviors remain unverified, alongside source background init and SAF. Existing user edits were not committed.


## P4/P7: Async JS worker results and task release (2026-10-04)

- Workers await JS function results before sending data. Synchronous throws, asynchronous rejections and send failures return task errors, with function/result references released in finally. Native JS references are recursively checked in lists/maps at argument and result boundaries; direct/nested callback results cannot cross isolates. Ordinary data and ArrayBuffer bytes remain supported.
- Argument send failure removes its task and updates idle, preventing close from waiting on unsent work. close shares a Future and releases ports/isolate after accepted tasks finish. It retains and awaits spawn so a late handle is released by the same close path, rather than being killed while accepted work drains.
- Five new native Windows regressions bring focused coverage to 11: delayed async results with close draining; continued work after sync/async/invalid-function/native-reference errors; argument native ownership; unsendable argument cleanup; and close before spawn completes. An initial native-function result case terminated the test early; transfer validation resolved it. The byte test was then corrected to use the supported ArrayBuffer input, retaining existing Uint8Array map conversion.
- js-worker-targeted/native-transfer/final-targeted logs retain intermediate outcomes; verified-targeted is final focused evidence. Unexpected isolate exit, infinite computation and full application shutdown remain pending. Waiting for the spawn handle does not prove observation of an OS thread termination event. User edits were not committed.


## P4: JS worker failure and observed exit confirmation (2026-10-04)

- IsolateJsEngine registers onError/onExit at spawn with errorsAreFatal explicitly enabled. Uncaught errors preserve RemoteError messages and remote stacks; unexpected exit settles pending startup/task waits. Normal close keeps the response port alive, waits for the actual exit event after kill, then releases the port. A late spawn handle cannot republish an exited worker.
- Worker startup uses a named record and permits an injected entry point following the SendPort/Task/TaskResult protocol. Four real Dart isolate regressions cover exit before handshake, uncaught startup error, and explicit exit/uncaught error while close drains tasks. Combined pool and native QuickJS focused coverage: 15 passed.
- Close still joins accepted work before kill; infinite computation is not automatically interrupted. This confirms Dart isolate exit events, but a graceful worker stop message that explicitly releases all native runtime resources and full application shutdown composition remain pending under P4/P8. Existing user edits were not committed.


## P4: Graceful JS worker stop and native resource release (2026-10-04)

- Normal close drains accepted tasks, waits for the transport handshake and sends JsWorkerStop. The worker finally disposes JsEngine, closes its acquired child JSPool, closes its task port, sends JsWorkerStopped with cleanup status and exits. Close waits for both cleanup acknowledgment and actual exit; missing acknowledgment or failed cleanup cannot report success.
- Transport readiness is separate from task admission, so close during startup rejects tasks while still obtaining the control port. Uncaught errors/failed workers retain forced termination. Automatic-close errors are logged while explicit close retains its failure. Failed cleanup stays failed; cleanup is not claimed to be rerunnable in an exited worker.
- Three real Dart isolate protocol regressions independently hold cleanup and exit, covering success, cleanup failure and missing acknowledgment. Combined abnormal-exit, pool and native Windows QuickJS focused tests: 18 passed. Initial compilation lacked the StreamIterator import; after correction tests passed. That full run was explicitly stopped; verified-targeted/final logs identify final evidence.
- No automatic timeout/forced cancellation is introduced for infinite computation or unresponsive workers. Core shutdown, source background work and SAF remain unintegrated. The default worker now explicitly releases resources on normal exit; cross-platform device and overall performance acceptance remain required. User changes were not committed.


## P4: JS release failure isolation and startup cleanup ordering (2026-10-04)

- Engine release snapshots and attempts every scope, runtime, port, current and temporary HTTP client. Scopes similarly release every child and callback. A failed release cannot skip later resources; JsResourceReleaseFailure retains resource labels, errors and stacks. Ownership references are cleared before attempts and repeated dispose does not re-release attempted handles; failed native cleanup is not claimed successful or retryable.
- If initialization and cleanup both fail, JsEngineInitializationFailure retains the initial cause and cleanup error with the original stack. Workers retain caught startup/runtime failures until finally cleanup and its acknowledgment finish, then notify the parent, preventing a controlled error from triggering kill before cleanup. Truly uncaught errors retain forced termination.
- Four regressions cover multiple scope failures with later callback release, later scope release after an earlier failure, real QuickJS initialization plus HTTP client cleanup failure, and default native worker startup failure followed by cleanup/exit. Related lifecycle focused tests: 25 passed.
- Full application startup/shutdown composition, source background work and SAF remain incomplete. Observable release errors do not prove the absence of every native resource leak. User edits were excluded.


## P4: Source manager close and cross-phase startup rollback (2026-10-04)

- ComicSourceManager.dispose immediately detaches repository listeners and disposes its notifier; closeAndWait shares resource completion. New init/ensureInit/mutations and direct add/remove are rejected while accepted queued work finishes. Original initialization Promises are tracked to settlement: the 15-second wait timeout is not draining, and unresolved Promises continue to block close without assumed cancellation of side effects.
- After draining, owned JS registrations and callbacks are released with failures collected. Query/category/favorite/image bindings and the singleton are cleared; replacement instances can bind afresh and stale close calls cannot clear them. The manager does not own its JS engine; the host must close sources before releasing that engine.
- Core startup registers source bindings, JS engine/pool and source-manager cleanup for later sources/stores/finish failures. Cookies newly acquired by successful infrastructure startup also register cross-phase rollback; borrowed existing cookies remain externally owned. Composition retains the single application-startup-owner model and does not promise independent concurrent bootstraps sharing a runtime.
- Four new native Windows regressions cover background-init draining/listener detachment/replacement; actual timeout followed by original Promise completion; accepted install completion before close; and corrupted local.db causing later failure with source/engine/cookie release. Combined source transactions, dependency waits, cookie infrastructure and core startup focused tests: 21 passed. The initial run exposed ready init bypassing closure; both init and ensureInit now reject closed instances.
- Normal GUI/headless full shutdown composition, independent timers or unreturned source tasks, SAF/Rhttp infrastructure lifetime and cross-platform acceptance remain pending. User edits were not committed.

## Headless shutdown and persistence ownership (2026-10-04)

CoreBootstrap adds awaitable closure with cached outcomes and aggregated errors; failed startup is not cleaned twice. The source manager joins real init, source writes and asynchronous notifications, including removed/replaced sources. WebDAV transport/cache disposal is registered. Cookie cleanup covers imported replacements at this application's data path while preserving different-path instances.

Headless finalization unbinds and flushes sync after core closure; failed settings loading cannot write defaults. Desktop follow-update, WebDAV, reader and native-infrastructure draining remain pending; close API availability is not complete platform shutdown acceptance.

Follow-update exit update (2026-10-04): task execution completion is separate from progress streams. The global gate owns job/direct-update admission; the background service owns scheduling, checks and observation. Window close joins this preparation before storage/sync, and release does not restart disposed runtimes. RequestScope cancellation isolates follow-update database effects; it is not full source/native-request termination proof.

WebDAV exit update (2026-10-04): the source owns its injected cache, transport, synchronizer and snapshots. dispose freezes synchronously; closeAndWait joins business work and original metadata Rhttp requests before closing storage. Synchronizer/snapshot closure does not release caller-owned SQLite or transport. Core uses awaitable closure; window preparation holds WebDAV after follow updates and defers follow-update release until pending WebDAV preparation settles. BufferedRHttpAdapter only serves directory/metadata requests; image bytes belong to image/reader owners. Global Rhttp/SAF, remounted ownership and irreversible desktop shutdown remain under audit.

Window input update (2026-10-04): WindowFrame owns content/shutdown focus, active pointers and scoped navigation admission. It freezes only after close guards allow exit, drains late writes on failure, restores focus and asks business bindings to release preparation. SyncWindowBinding no longer owns a sync dialog; the window presents unified wait/force-quit feedback. Main still does not retain and close CoreBootstrap. Input blocking alone does not justify core closure before all reader/other write owners have drained.

Platform event update (2026-10-04): EventSubscription owns an explicit serial queue and handler completion signal, separately joining cancellation and real work while reporting late errors to its original sink. Reversible preparation clears queued work, invalidates the active generation, and keeps listening to discard events rather than replaying them after recovery. InteractiveBindings owns link/share subscriptions, the timer and every heartbeat completion; final disposal joins all calls and retains each cancellation error. Window preparation freezes platform events before other services; detachment joins the current preparation before releasing earlier holds.

The native Windows monitorUIThread exits the process when heartBeat is absent for more than five seconds, so reversible preparation keeps sending heartbeats. This change does not stop that native thread or connect irreversible core shutdown. Final host/remount ownership still requires a native monitor protocol; draining Dart calls does not prove native-thread release. Injected streams cover Android link/share behavior, with real EventChannel cancellation and other platform acceptance still outstanding.

Windows monitor follow-up (2026-10-04): FlutterWindow-owned HeartbeatMonitor replaces global monitorUIThread. startHeartbeat returns a generation id, checked by heartBeat/stopHeartbeat. Stop wakes and joins the actual worker; OnDestroy closes before engine release and destruction can repeat cleanup. WindowsHeartbeat owns each mount registration and its calls; final binding disposal drains then explicitly stops, including late registration, with stale stop isolated from a replacement. Native CTest passes 2/2 and Windows release builds. Irreversible desktop core shutdown remains disconnected; overall host and non-Windows native lifetimes still require work.

Shared image source update (2026-10-04): SharedRequestStream.isClosed means closed admission; done means source-stream cancellation/natural completion. The final subscriber joins source finally; other owners remain independent. ImageDownloader still removes its mapping at admission closure without globally retaining retired requests. RequestScope.run can end source-configuration waiting early, so stream.done does not prove the original Promise or native transport has drained.

Image configuration follow-up (2026-10-04): _resolveComicImageConfig retains and joins the original resolver Future after cancellation, then releases undelivered results; source finally now includes this wait. discardImageLoadingConfig traverses references by identity, handles aliases/cycles and collects all free failures. This covers the returned resolver Future and undelivered configurations only; normal configurations, rejected parsed values, unreturned work, native transport and global retired requests remain separately owned audit work.
