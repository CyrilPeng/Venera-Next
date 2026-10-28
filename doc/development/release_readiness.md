# Patch release readiness

This checklist tracks release preparation following v1.18.0. A release does
not mark unresolved reports as fixed. Dated verification records and the
original device acceptance checklist remain below.

## Second patch candidate preparation (2026-10-28)

The next candidate is v1.18.2-rc.2, build 238. It retains rc.1 and first
delivers the #110 local-All selection restoration and #117 Windows global
hide/restore hotkey. Stable distribution stays at v1.18.1; do not update
AltStore or Winget. The hierarchy, Android TV and HarmonyOS branches are not
merged into this release.

- #110: test local All and a concrete folder after ending the Android process
  and restarting. Deleted folders must still be rejected. This fix does not
  establish that every original missing-favorites report has been resolved.
- #117: test the default-off shortcut from another application and across
  normal, maximized, fullscreen and minimized states. Verify key-repeat,
  conflicts, saving, restart, disable/clear, native dialogs and relaunch recovery.
  The binding is device-local and only hides the main window; it is not a
  privacy feature and does not pause downloads.
- #125: requested the actual version/build and installation origin because the
  report names rc2 before an official rc.2 exists. Image format, device and the
  difference between delayed image arrival and UI stalls remain unconfirmed.
  The new synthetic local-reader decode probe passed all 20 measurements with
  Flutter 3.41.4 on Windows. It is not an Android frame-pacing test, a decoded
  image-cache test, or a runtime fix. See the
  [diagnostic record](../experiments/webdav_reader_performance.zh.md).
- #107/#115 still need original-environment confirmation; do not repeat the
  existing retest notices early. #111 has a reporter response that v1.18.1
  starts normally; keep the agreed observation window without a no-response
  reminder. Already-closed #96/#100/#112/#118/#119 remain closed. The #100
  closure followed the reporter's request to defer unstable-site follow-up,
  not acceptance of an expanded page/body HTTP/3 strategy.

Local preparation passed 168 targeted favorites, hotkey, synchronization,
image-provider, WebDAV and changelog tests, the decode probe's 20 measurements,
strict analysis and architecture/import checks with Flutter 3.41.4. All 139
Python script tests completed with four intentional skips. These are scoped
host checks, not a new full-suite result or Android device acceptance.

The runtime commits already passed full cloud quality and dependency checks
at e634d887e14a7c3daaa5fbb2bc439ce5115d9192. These older results do not replace
the exact release commit's checks. Before tagging, confirm its metadata and
dependency audit. The tag workflow must pass full quality gates and fresh
six-platform builds before publishing all installation assets. Verify the tag,
release notes, prerelease flag, asset inventory and unchanged stable channel
before notifying #110 and #117 once with version-specific retest steps.

Back up before upgrading; no data reset or archive renaming is required. Keep
the original comics and pre-upgrade application-data export for rollback.
The host measurements do not establish #91 energy savings or #125 device
performance, and publishing a candidate does not close these reports.

## Next patch candidate preparation (2026-10-25)

The next candidate is v1.18.2-rc.1, build 237, based on the released
v1.18.1. It delivers the follow-ups previously marked unreleased in #98,
#107, #110, #112 and #115, plus PR #113. The dated v1.18.1 sections below
describe that older release's scope, not this candidate's new functionality.
Stable distribution remains v1.18.1; do not update AltStore or Winget for RC1.

- #98: continuous and waterfall modes resume automatic scrolling after zoom
  gestures end, retain screen-space speed and read the zoomed chapter tail
  before stopping or crossing chapters. Touch holds, menus and background
  pauses remain; zoomed paginated galleries still pause automatic page turns.
- #107: an opt-in task option continues past unavailable network images after
  bounded retries. Missing pages remain visible in the queue, never count as
  a complete download, persist across restarts and are retried on next start.
  Authentication, certificate, cancellation and local-write errors still stop.
  The Honor/MagicOS background-disconnection report needs separate device tests.
- #110/#115: mounted lists refresh when keyword blocks change and preserve card
  identities; hidden counts distinguish filtering from missing data. Original
  favorites/import symptoms still need reporter confirmation. Do not bypass
  filters, rename archives automatically, clear data or request private backups.
- #112: waterfall chapter titles are present on first layout, preventing an
  earlier chapter's prefetch from inserting a title and shifting current images.
  Retest entry at a later chapter, slow loading and exit while loading.
- #113: wheel and trackpad handlers cover the whole viewport, including blank
  side margins, without duplicate handling. Preserve the contributor's original
  commit; the changelog uses the PR number without an extra attribution section.

The actual merged source passed 30 targeted reader regressions and strict
analysis with pinned Flutter 3.41.4. Release preparation also passed 18
changelog/update-channel tests and 139 Python script tests (four skips).
Merged-main commit b73fadf passed [full cloud quality checks](https://github.com/CyrilPeng/Venera-Next/actions/runs/40203793185)
and the [Rust dependency audit](https://github.com/CyrilPeng/Venera-Next/actions/runs/40203793067).
These results do not replace device acceptance or fresh checks on the release
commit. Publish only after the exact release commit passes metadata checks,
full quality gates, dependency audit and fresh six-platform builds. Do not publish an empty
release, relabel older assets or treat an in-progress job as a passing result.

After all assets are public and verified, post one version-specific test notice
to the five related open issues and the merged PR, with their own reproduction
steps. Keep issues open pending verification; do not repeat unrelated stable
release notices. No destructive reset is required. Preserve original comic
files and a pre-upgrade application-data export; use that backup for rollback.
The Android startup, real SAF recovery and mobile energy-use limitations from
v1.18.1 are not claimed newly resolved by this candidate.

## Stable patch release decision (2026-10-25)

The maintainer approved releasing v1.18.1, build 236, with the documented
limitations rather than waiting indefinitely for original-reporter feedback.
There has been no new RC feedback at this decision point. Silence is not
device acceptance, and the original device checklist is not claimed complete.

This promotion changes release metadata and documentation only; runtime code,
dependencies and fixes are unchanged from v1.18.1-rc.1. The stable tag must
pass metadata validation, strict analysis, the full test suite, dependency
audit and fresh builds for all six platforms on its exact commit. Earlier
RC artifacts are not renamed or reused as stable installation packages.

The release notes retain the unresolved Android startup report in #111, the
original missing-import symptom in #115, Android SAF permission/recovery
acceptance in #119, and iPad/Android visual acceptance in #118. Favorites
visibility in #110, OEM background downloads in #107, the original HTTP/3
network in #100 and mobile energy consumption in #91 also remain unconfirmed.
The additional zoom interaction in #98 and title layout in #112 are not
claimed implemented. No destructive data reset is part of acceptance.

After the stable assets are published, notify the relevant reporters with
issue-specific reproduction steps and request feedback within 14 days. Send
one reminder after seven days. Reassess each issue at the deadline rather
than closing all inactive reports automatically: confirmed code fixes can be
closed as released, unresolved startup/data reports remain open or explicitly
awaiting information, and unfinished extra requests must retain their own
tracking. Preserve the existing closed state of #106 and #121.

Stable distribution metadata is updated only after the GitHub Release is
published: verify the generated Winget manifest and review the AltStore source
update against the actual IPA asset, size and release date.

## First patch candidate (2026-10-24)

The requested candidate is v1.18.1-rc.1, build 235. Its release notes retain all
changes since v1.18.0 and explicitly distinguish confirmed code fixes from
unresolved device symptoms. Stable distribution stays at v1.18.0: neither the
AltStore source nor Winget metadata changes for this candidate.

- #111: the Windows legacy-favorites SQLite internal-table failure is fixed.
  A separate reproduced failure now shows diagnostics before pending source
  initialization and rollback finish, without releasing data ownership early.
  The original Android splash hang remains unconfirmed; upgrade and full-data
  restore acceptance is still required.
- #119: migration now accepts the SAF picker's android:// document paths while
  preserving journal, overlap and recovery checks. Native/SAF and SAF/SAF
  regressions pass; real Android provider permissions and recovery need testing.
- #115: all-failed archive batches no longer report success, and named errors
  are visible. The reporter's actual archive imports and reads on this Windows
  host under both reported names. The original missing-list symptom has not
  been reproduced; do not declare filenames invalid or bypass block filters.
- #118: selecting an already loaded gallery page no longer remounts its image.
  Reset retires old animations and gestures in place while actual unmount still
  owns disposal. Local PNG, frame identity, rendered pixels, interrupted turns
  and lifecycle regressions pass. iPad and Android visual acceptance is open.

The four follow-ups passed 131, 86, 235 and 932 related tests respectively with
the pinned Flutter 3.41.4 SDK; these counts overlap and are not a new full-suite
result. Strict Flutter analysis passed. The version-tag workflow must still run
metadata checks, full quality gates and all six platform builds on the exact
release commit before it publishes a prerelease with installation assets. Do
not publish an empty release or reuse earlier build artifacts as this candidate.

Back up before upgrading. Preserve original comics and the pre-upgrade export;
downgrading is not a schema compatibility promise. Restore the pre-upgrade
backup when rolling back instead of deleting user data to mask a failure.

The following sections retain the dated diagnostic and validation history.

## Startup report 111

The report describes an Android startup failure after upgrading from v1.17.0
or importing old settings, and a Windows SQLite read-only error. The attached
log inspected on 2026-10-19 contains cancelled requests and JavaScript bridge
cleanup errors, but not the reported SQLite error or the primary startup stack.
These are insufficient to establish a settings-format incompatibility.

An isolated Windows smoke test using the v1.17.0 default settings structure
successfully starts the real core, preserves the old reader mode and search
history, and closes its native resources. This is a baseline only: it does not
reproduce the reporter's custom settings, existing databases, or Android device.
The missing details were requested in
[issue 111](https://github.com/CyrilPeng/Venera-Next/issues/111#issuecomment-6267054445).

The diagnostic improvements record the startup phase and original error before
rollback closes the log writer. Failures before the normal application is shown
use a standalone, scrollable diagnostic page with redacted clipboard export.
Desktop failure startup explicitly reveals a titled native window with working
system close controls, without reading or writing persisted window placement.
It does not retry partial startup, reset preferences, recreate databases, or
weaken storage ownership and rollback. Headless stdout remains unchanged.

Further acceptance requires the primary Android failure details and the Windows
SQLite stack, including which database and statement failed. Ask whether the
backup was an application-data export or a settings-only export, the exact
versions/builds, and the installation/data-directory location. Prefer redacted
diagnostics and a minimal synthetic settings reproduction over full private
backups. Do not recommend deleting user data or running as administrator as a
substitute for identifying the cause.

## Logging

Default masks cover credentials in request/response headers, common structured
payload fields, URL user information, signed query fields, and known credential
assignments in text. The final Log boundary masks before truncation, console
output, in-memory storage, startup replay, and file append. Custom header/body
masks still apply, and transport objects are not modified.

This is not a general personal-data anonymizer. Arbitrary source-script output,
unknown credential field names, personal paths, and private URLs still need
review before sharing. Existing exported or previously published logs are not
retroactively scrubbed; remove sensitive attachments and revoke exposed sessions
separately.

## Changelog and favorites

- The full CHANGELOG.md remains the release-note source. Its H2 sections become
  version labels in document order. Empty sections are skipped, and documents
  without version headings retain a fallback view.
- Version labels and selected-section lines use lazy lists. Inactive versions
  have no mounted body widgets. Switching versions starts at the top; theme and
  layout changes do not reread the asset.
- Favorites search refreshes only after an accepted folder query. Existing
  ownership/generation guards, read filters, and keyword blocks remain intact.
  The search defect is independently reproduced; issue 110 still needs reporter
  confirmation before treating its original report as resolved.

## Local verification (2026-10-20)

The unreleased changes were verified on Windows x64 with Flutter
3.41.6 and Dart 3.11.4. The repository's CI SDK target remains Flutter 3.41.4;
these local results do not replace final-state CI or device acceptance.

- Release metadata, structure imports, architecture dependencies, and pinned Git
  dependencies passed. All 19 changed/new Dart files passed formatting, strict
  Flutter analysis found no issues, and git diff --check passed.
- Python release-script tests: 127 run, four skips, no failures.
- Final full Flutter suite: 5,305 passed, two platform-conditional skips, zero
  failures, using flutter test --no-pub --concurrency=1 --machine. The earlier
  parallel sync-test timeouts are not counted as passes; this complete serial
  run passed without weakening assertions or increasing test timeouts.
- The additional desktop failure-window regression run passed all 38 tests,
  including native-call ordering, close interception disabled, awaited show
  completion, and native initialization failure propagation.
- Android ARM64 and Windows x64 release builds passed after the final code
  change. The APK is build/app/outputs/flutter-apk/app-release.apk; use the whole
  build/windows/x64/runner/Release directory for Windows, not the EXE alone.
- The independent code-audit package passed locked offline dependency resolution,
  its AST self-check, and its own strict analysis.

Local diagnostic evidence is retained in ignored build/release-final-quality.log,
build/release-final-flutter-tests.log, build/release-final-test-summary.json,
build/release-final-windows-build.log, build/release-final-android-build.log,
build/release-final-code-audit.log, and build/release-final-artifacts.json.
The window-control regressions use mocked platform channels, not a real native
failure-window launch. The full Windows startup smoke script requires a fresh
disposable CI runner; it was not run against a daily-use user profile.

No Android device was connected for this verification. Real upgrade/import,
screen-off download, reconnect, and notification-pause acceptance remains open.
Issues 110 and 111 have no additional reporter feedback as of this check. No
version/build increment, release tag, or issue closure was made during local
verification.

## Original stable release acceptance checklist

This checklist records the original full-device acceptance target. The scoped
release decision above permits publishing with explicit remaining limitations;
it does not turn missing device evidence into a passing result.

1. Establish the root cause or an actionable environmental diagnosis for the
   original Android failure in #111, and finish the candidate's device checks
   for #115, #119 and #118. Keep unresolved reports explicit.
2. Run formatter, structure/dependency checks, Python release tests, strict Flutter
   analysis, and the full Flutter suite on the final source state.
3. Build Android and Windows release artifacts locally where supported. Run the
   repository quality and complete-build workflows on the final committed state
   for the remaining platforms; an older green run is not final-state evidence.
4. Perform upgrade/data-import smoke tests with preserved test data, plus reader,
   changelog, and favorites smoke tests. Verify the diagnostic window's native
   visibility and close controls on a clean desktop profile. Follow
   android_downloads.md for Android device acceptance, especially screen-off,
   reconnect, and notification pause.
5. Only after acceptance, update version/build metadata and versioned release
   notes, then validate with .github/scripts/validate_release.py for the intended
   tag. Keep unresolved OEM-specific limitations explicit in the release notes.

## Reader issue fixes (2026-10-22)

- #98 is reproduced with the real gallery and production PhotoView. The
  contained scale changes on rotation while the old cached initial scale does
  not. Deriving the baseline from current layout boundaries restores automatic
  page turns without treating a user's zoom as the unzoomed baseline. Tests use
  physical view metrics, not only a changed test render surface, and cover all
  gallery directions, paired pages and rotation during animation.
- #112 has a reproduced cancellation path: Network.get throws the HTTP bridge's
  stringified Dio cancellation, which previously entered the session's failure
  drain as an ordinary source error. Only exact aliases recorded by a cancelled
  request and its ancestry are restored to the original cancellation reason.
  Accepted Promises still drain before exit; unrelated source rejections and
  persistence/native cleanup errors are not suppressed. Chapter loads and
  retained image callbacks both have native QuickJS regressions.
- #111 is not reproduced by the synthetic legacy-settings startup test. That
  test preserves reader mode, search history and an existing database while a
  source's initialization Promise remains pending. It does not establish that
  the reporter's import, settings, filesystem permissions or Android device are
  compatible. Keep the primary diagnostic/device acceptance gate open.

These changes are unreleased. Original Android rotation/loading-exit steps and
upgrade/import still require device acceptance; do not close the issues solely
because the host regressions pass. The additional title-layout feedback in #112
is not claimed as resolved by the cancellation patch.

Verification completed on 2026-10-23:

- Full Windows-host Flutter suite: 5,333 passed, two conditional skips, zero
  failures using Flutter 3.41.6 / Dart 3.11.4 with serial execution. The log
  wrapper's initial parse error is not counted as a test result; its fresh,
  complete rerun passed. No assertions or timeouts were weakened.
- An isolated checkout of the repository's Flutter 3.41.4 / Dart 3.11.1 passed
  enforced offline lockfile resolution, strict analysis, changed-file formatting,
  53 targeted regressions and all 12 actual-reader rotation cases. The original
  PhotoView baseline fails the actual-reader rotation regression.
- Structure imports, architecture dependencies, release metadata, pinned Git
  dependencies and git diff --check passed. Python tests ran 127 cases with four
  skips and no failures; the isolated code-audit self-check and analysis passed.
- Windows x64 Release built with Flutter 3.41.4. Android ARM64 Release compiled,
  packaged and passed APK signature verification. Maven TLS download failures
  were resolved with a build-only init script and local proxy; repository Gradle
  files and dependency versions remain unchanged. The universal-named local APK
  has ARM64 AOT only; it is a test artifact, not a multi-ABI release candidate.

Evidence is in ignored build/issue-fixes-20261022 logs and artifact hashes. No
Android device was connected; iOS, macOS and Linux builds were not run locally.
Verification leaves version/build metadata at 1.18.0+234 and does not publish a
release tag or close an issue. Use the complete Windows Release directory, not
only its EXE.

## CI follow-up (2026-10-23)

The first CI runs for reader-fix commit 3b53f5e exposed two independent issues:

- Dependency audit run 39874391057 reported RUSTSEC-2026-0382 in
  rustls-webpki 0.103.15 and RUSTSEC-2026-0381 in webpki-roots 1.0.4.
  The lockfile now selects the fixed 0.103.16 and 1.0.10 releases. Other
  dependencies, including rustls, Flutter Rust Bridge and the iOS libc pin,
  remain unchanged; no advisory exclusions or audit relaxations are added.
- Complete-build run 39874394216 was manually dispatched on main, but the
  metadata job treated main as a release tag and failed before quality/build
  jobs could run. Branch dispatch now explicitly validates the configured
  release version with --build-only, retaining version/changelog, bridge-lock
  and installer checks. Tag builds still validate the actual ref, and the
  release job remains limited to version-tag pushes. Build-only mode cannot
  write release notes or bypass tag validation for a tag build.

Local follow-up verification: 139 Python tests ran with four conditional skips
and no failures, including 12 new release-validation regressions. All four
locked Rust library/callback-drain tests passed. Both branch-build and explicit
v1.18.0 metadata validation, structure/dependency checks, actionlint and
git diff --check passed. Cargo-audit 0.22.2 scanned all 243 locked crates against
1,349 current advisories with --deny unsound and no findings. Fresh cloud audit,
quality and six-platform complete
build results must be checked against the amended commit, not the superseded
run or the separate successful build-only run 39874710216. No release tag or
version/build increment is introduced by this CI repair.
