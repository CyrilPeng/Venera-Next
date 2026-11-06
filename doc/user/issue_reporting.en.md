# Issue reporting and diagnostics

中文：[Issue 分类与诊断采集](issue_reporting.zh.md)

Choose the failed feature from [New Issue](https://github.com/CyrilPeng/Venera-Next/issues/new/choose). Report one independent problem per Issue; describe platform differences together for the same problem. Include a trigger and symptom in the title, for example “Some files fail to upload when batch archiving to WebDAV.”

This repository maintains the app, including local reading, extension runtime, downloads, web login and WebDAV. Source-site content, title availability and third-party source scripts belong with their maintainers. Mentioning a source does not automatically exclude an app defect; explain the app-side evidence. Report vulnerabilities privately using the [security policy](../../SECURITY.md).

## Categories and evidence

| Form | Appropriate cases | Required evidence |
| --- | --- | --- |
| Crash, startup or freeze | Process exits, launch fails, whole UI remains unresponsive | App logs around the failure, system crash information or native startup logs |
| Reader performance | Slow image display, first-view/revisit stalls, stutter or memory issues | A captured Reading diagnostics report or summary; ordinary logs or video alone do not replace it |
| Local import and data | Import/export, successful import missing from lists, favorites/history persistence, backup restoration | App logs; operation route, anonymized file layout and actual results |
| Network and WebDAV | Downloads, CBZ archive upload/download, app-data sync, online library or web login | App logs; operation, error/HTTP status and per-item failure stage when available |
| UI and other bugs | Layout, navigation, focus, reader controls, extension runtime or uncategorized defects | UI reports need steps and optional screenshots; runtime and other defects require logs |
| Feature request | New capabilities and improvements | Use case, proposal, primary feature/platform and observable acceptance criteria; no logs |

All diagnostic categories accept unavailable diagnostics with a concrete reason and alternative evidence. Archive/import failures belong to those features; a crash involves process exit or sustained unresponsiveness. Do not select UI to bypass diagnostics.

Bug reports require specific version/build and variant, platform, device/OS, steps, expected and actual behavior. Custom builds can provide `commit <revision>`. “Latest,” “there is a bug” and “will add later” are insufficient. Intermittent reports may describe the last occurrence and time; repeatedly causing a crash is unnecessary.

## App logs

1. Reproduce once in the existing environment and note the time and action. Do not repeat supplied comparisons, clear caches/data or reimport a library for collection.
2. Promptly open **Settings → Logs → More → Export** to save `log.txt`. The level filter only changes the page; exports contain the current run's retained memory records.
3. Review and redact the text, then paste relevant entries/stack traces or attach `.txt`, `.log` or `.json`. Larger files may be zipped. Confirm uploading completed.
4. Preserve timestamps, error types, status codes and stages. Remove accounts, cookies, tokens, signed URL parameters, private titles and full personal paths. Third-party extension output still needs review.

The page retains 500 entries at most; restarting does not reload the previous session. If existing permissions permit, use `logs.txt` and `logs.previous.txt` in the app-data directory for earlier records. The usual Windows directory is `%APPDATA%\com.github.cyrilpeng\VeneraNext\`; customized/migrated paths may differ. Mobile users do not need root or changed permissions. See [Disk logs](../development/logging.en.md).

The default per-entry length limit normally suffices. Temporarily disable it only when a complete error response is specifically needed and can be redacted. Do not substitute complete backups, databases or private comics for logs.

## Reading performance capture

Released `v1.18.2` and later versions provide this entry. The first candidate containing it was `v1.18.2-rc.6+242`; older versions may lack it.

1. Keep existing modes/settings and use a few already-downloaded local images. Explain if only the WebDAV/extension route is affected; do not download a whole comic for collection.
2. Reader menu → **Reading diagnostics → Start a new 45-second capture**, close the dialog and reproduce the shortest sequence. Describe known first-view/revisit differences without repeating completed comparisons.
3. Reopen diagnostics to stop, review and **Copy report** before exiting the reader. Reports live only in that reader's memory, are cleared on exit and are not uploaded automatically.
4. Paste JSON or attach `.json`/`.txt`. The summary before `imageEvents` suffices, including `configuration`, `durationUs`, `retainedFrameSamples` and `retainedStageSamples`. Truncated event details do not require resubmission.
5. Include mode, content route, image format/dimension range, refresh rate, processing state and whether images appear slowly or the entire UI stalls. Do not include titles, URLs or script bodies.

Elapsed waits are not CPU time; frame samples are not measured FPS. An unstarted preview is not a captured report. Use the unavailable path if the version lacks the entry or capture cannot finish. See the [detailed reader diagnostics guide](../development/reader_diagnostics.md).

## Unavailable diagnostics and startup failure

Select unavailable, explain that in the diagnostic field, and complete both:

- **Why diagnostics are unavailable**: attempted collection method and concrete obstacle, such as immediate exit before Settings and no startup log in the documented location. “I do not know how,” “no logs” and “later” are insufficient.
- **Alternative evidence**: redacted errors/screenshots, system/installation diagnostics, or detailed circumstances with time, failure stage and frequency.

Windows records native startup before Dart in `%LOCALAPPDATA%\com.github.cyrilpeng\VeneraNext\logs\windows-startup.log`, with a possible `windows-startup.previous.log`. This is separate from app logs. Missing-DLL loader errors may precede log creation; retain the system error instead. See [Windows startup diagnostics](../distribution/windows.en.md#startup-validation-and-diagnostics).

Android, iOS and HarmonyOS can use existing crash notifications, installation errors or app-specific diagnostics. Complete device logs, root/jailbreak, reduced security settings and signing keys are unnecessary. Detailed circumstances are accepted when system logs are not readily available.

## Checks after submission

Forms enforce nonempty fields; deterministic rules check categories, placeholders and diagnostic references without an AI API or Secrets. Opening/editing/reopening an Issue and creating/editing/deleting comments trigger rechecks.

Missing information adds `needs: information` and a single bot comment listing omissions. Supplying it updates that comment and removes the label. Reporter comments may supply logs/reports; maintainer evidence also counts. Unrelated commenters and bots are not treated as evidence providers.

Automation manages `bug`/`enhancement`, the primary `area: …` and `needs: information` labels, preserving human investigation/planning/post-release-feedback statuses. It never closes or reopens Issues and does not impose new forms on historical reports. Existing follow-up and acceptance arrangements continue.

Forms cannot conditionally require another field based on a dropdown. Four diagnostic forms require evidence directly; runtime/other choices in the UI form and both unavailable-evidence fields are enforced after submission. Text or attachment references do not establish valid contents. Automation does not download attachments or replace maintainer diagnosis, and cannot reliably detect intentionally misclassified reports.
