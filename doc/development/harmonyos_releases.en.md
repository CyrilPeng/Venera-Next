# HarmonyOS Mainline Builds and Releases

The reader and HarmonyOS adapters are maintained on `main`. Standard platforms use the root pubspec/lock with official Flutter. HarmonyOS uses the pinned Flutter OH SDK, CPF overlays, independent lock template, ArkTS bridge and native build configuration under `tool/harmonyos/`. The generated project lives in `build/harmonyos/full-app`; application runtime source matches the caller's canonical Git blobs.

## One Exact Source Commit

Mainline builds of at least 245 use schema 3 in `.github/harmonyos-next.json`, with `source_mode: release_commit`. The configuration neither embeds its own commit SHA nor resolves a floating branch. The selector obtains the caller checkout's full HEAD SHA and requires the build checkout to match exactly. The context records equal source/release commits, version, build number, Actions run ID and changelog digest.

PR checks use the exact Actions merge-candidate SHA; pushes and dispatches use the exact mainline SHA, matching the standard Flutter workflows. Both checkouts reject staged, unstaged and untracked inputs. Shared fixes require no second development branch or baseline/pin edits.

The mainline candidate workflow listens to relevant source, dependency, tool and release-configuration changes and reuses `harmonyos-release.yml`. Separate SDK directories, the controlled OH lock, native cross-compilation, strict analysis, host regressions, a real API 26 HAP, asset checks and native export audits remain mandatory. Only generated projects and downloaded overlays are patched; official Flutter, shared Pub caches and the root lock are unchanged.

## Independent Beta and Historical Bundled Distribution

Build 244 retains the schema 1 `.github/harmonyos-release.json`, immutable Git inputs and historical assets. The `harmonyos-frozen-244` archive tag keeps its source reachable; `harmonyos-branch-final-245` preserves the final two-branch candidate. Development continues only on `main`. Legacy schema 2 parsing remains available for historical verification; current mainline uses schema 3.

Starting with `v1.18.4+253`, the maintainer uses independent Beta distribution. Schema 3 explicitly sets `distribution: independent_beta` and retains `release_enabled: true`. Standard stable releases contain the other platforms; `harmonyos-release.yml` builds the unsigned ARM64 HAP and verification files from the exact mainline commit. This does not constitute a stable HarmonyOS release or accepted device testing.

Current mainline explicitly sets `runtime_acceptance: optional`. This policy is separate from distribution: if `distribution: bundled` is selected in the future, both stable and prerelease versions may publish without a device report, and a missing report no longer retains the entire Release as a draft. HarmonyOS remains an unsigned Beta, with mandatory source, version, native-library and package-digest checks. Current distribution remains `independent_beta`.

Historical configurations without `distribution` default to `bundled`, retaining their HAP, companion files and original `runtime_acceptance` rules. Explicit `bundled` uses the same report policies. Recovery reads the original commit's policy; historical `required` and `stable_required` are unaffected by mainline's `optional`. Unknown values, legacy schemas claiming independent distribution and mismatched sources are rejected. Manifests retain `signed: false` and `runtime_verified: false`. Previews remain Actions Beta artifacts; archive tags do not match the `v*` release trigger.

Canonical committed Git blobs identify runtime source and all eight project packages. The seven managed native libraries, PNG/7z exports, third-party NOTICE and all application assets remain audited. Applicable QuickJS fixes are pinned to `f5a1f20`; see the [current dependency decisions](dependency_audit.en.md) for sources and replacement conditions.

## Versions and Assets

The current `v1.18.4` uses build **253**, incorporating the three RCs and subsequent feedback fixes, with schema-3 reader diagnostics. Standard packages are rebuilt from the exact tag; the same-source HarmonyOS Beta is built independently with the existing bundle, launcher name and unverified markers. The original reporters accepted #178 and #188; #129 and #152 were accepted under the 72-hour feedback rule. See [current versions and acceptance](release_readiness.md#当前公开版本) for scope and known limitations.

The caller's Git commit, version, build number, run ID and changelog digest are validated. Only the owned generated project receives the caller's version and changelog; the source checkout is unchanged. Native versions have three numeric components, while Dart versions retain RC suffixes. Build numbers follow mainline monotonically. The first public mainline release with a HAP is `v1.18.3-rc.3`, build **248**; RC1/RC2 retain their built tags and Actions records and have no public Release. Schema 3 permits builds from 245 onward; build 244 retains its historical source for verification only. Existing releases such as `v1.18.2` are not backfilled.

Stable `v1.18.3` uses build **249** and rebuilds alongside the other platforms from the same stable release commit; accepted candidate artifacts are not renamed into stable packages. The stable release still includes the unsigned Beta HAP and four companions. HarmonyOS device signing, reading, real-data upgrades and signing renewal remain explicit follow-up acceptance.

The mainline schema-3 configuration uses `guide_delivery: repository`. The independent Beta's `harmonyos-release` artifact requires three files; historical bundled policies put these files in the Release:

- `VeneraNext-VERSION-harmonyos-arm64-unsigned.hap`
- `harmonyos-manifest.json`
- `harmonyos-SHA256SUMS`

The Chinese and English installation guides live at `doc/distribution/harmonyos-reader.*.md`. README links are relative, and independent-distribution release notes link to the Beta workflow. Both guides must exist and be nonempty in the exact HAP source. Checksums are generated for each HAP, so `harmonyos-SHA256SUMS` remains in the same artifact.

Historical configurations without `guide_delivery` still require those three files plus `harmonyos-install.zh.md` and `harmonyos-install.en.md`, with guide contents checked against the original commit. Published versions such as `v1.18.3` retain their five assets and tags; the new policy does not rewrite historical assets. Unknown policy values are rejected.

The bundle is `com.github.cyrilpeng.veneranext.harmony`, with launcher name `VeneraNext` in every language and minimum/target API 26. Checks inspect the actual `module.json`, AArch64 ELF libraries and exact hashes, complete Dart/asset source inventory, and embedded versions. Guides come from the exact build commit. Keep unsigned/beta labeling explicit; successful compilation is not device upgrade or certificate-renewal acceptance.

## Publication Gates and Build-Only Verification

GitHub's release-by-tag endpoint returns published releases only. Draft verification searches the authenticated, fully paginated release list for exactly one matching tag and fetches its current assets by numeric release ID. Missing or ambiguous drafts, changed IDs/tags and unexpected states stop publication. Published verification uses the public tag endpoint, and creation explicitly targets the caller's source SHA. RC2 uploaded all 26 assets as a draft, but the old lookup received HTTP 404; RC3 reruns the complete release path with the corrected lookup.

The full workflow's `Release` requires successful metadata, Quality and every standard-platform Build. Independent Beta policy permits only an explicitly skipped bundled HarmonyOS job; bundled policy still requires it to succeed. All standard draft/public package names, sizes, upload states and SHA-256 digests are checked. Independent mode rejects HAPs, HarmonyOS companions and device reports in the standard Release. The independent Beta itself still audits the actual HAP strictly: missing libraries, damaged contents, stale source or wrong digests fail verification.

The publishing job checks out the two source trees into sibling `release-source/` and `harmonyos-source/` directories. Generated notes and packages live alongside them in `release_notes.md` and `outputs/`. Scripts run from `release-source/`; generated inputs remain outside both source directories, which still reject untracked and uncommitted inputs.

Branch dispatches and mainline PR runs of `HarmonyOS Release HAP` create next-candidate Actions artifacts only, never tags or releases. Relevant mainline PRs/pushes use the candidate workflow with the same exact source SHA as standard-platform checks:

```bash
python3 -m unittest discover -s .github/scripts/tests -p test_harmonyos_release.py -v
python3 .github/scripts/harmonyos_release.py config
python3 .github/scripts/harmonyos_release.py config --preview-next
gh workflow run harmonyos-release.yml --ref main
```

Platform scripts and SDK baselines live in `tool/harmonyos/README.md` on mainline. The commercial API 26 SDK uses a checksum-pinned community CI mirror, not claimed official checksums. No signing secrets are read. See the [user guide](../distribution/harmonyos-reader.en.md) for installation and limitations. This workflow does not comment on, close, reopen or track issues.

## Device Acceptance for the Exact HAP

Current `optional` treats a device report as an optional acceptance record. Bundled stable and prerelease versions may publish without it; production delivery and draft recovery share this rule and explicitly state that device acceptance remains pending. Any attached report still undergoes strict checks of uploader, exact HAP, version, source, digest and every test result. Invalid or failed reports stop publication. Only the report's status as a publication prerequisite is optional; its contents cannot fabricate passing acceptance.

Independent Beta device acceptance proceeds separately. Standard releases contain neither a HAP nor a device report and make no HarmonyOS acceptance claim. The following report format remains applicable to testing the exact Beta and to bundled versions. Historical `stable_required` policies starting at `v1.18.4-rc.1+250` allow prereleases without a report for testing, while stable releases containing a HAP require acceptance. Historical `required` applies to both channels, and tags without the field keep their original behavior; published packages are not rewritten.

Build manifests retain `runtime_verified: false`; a separate `harmonyos-runtime-acceptance.json` records device acceptance rather than changing packaging or prerelease publication into a runtime claim.

After package verification, the HAP workflow produces a separate `harmonyos-runtime-acceptance-template` artifact bound to the exact source commit, version, build and original unsigned HAP SHA-256. Device, OS and test time are empty and every check is `not_run`. It is outside the three build assets and is never automatically uploaded as a passing report.

| Check | Device completion condition |
| --- | --- |
| `startup` | Sign/install the native HAP and cold-start the complete app |
| `source_and_reading` | Add a working source, search, open details and read multiple chapters; record the scope |
| `archive_import` | Import/read multiple archives and a collection ZIP; cancellation and failures report correct results |
| `directory_import` | Copy-import/read a folder when supported; only an absent system picker may be `unsupported`, with tested limit messaging and archive fallback |
| `download` | Download chapters to the app library and read offline; failure/cancellation never reports success |
| `backup_export_import` | Save an independent full backup, import into recoverable test data and check favorites, history and settings |
| `same_key_upgrade` | Upgrade the installed app with its original signing identity/key and retain comics/data; no uninstall or data clearing |
| `cold_restart_reading` | Fully exit/restart, then read old comics and restore progress/data |
| `ui_and_capabilities` | Test narrow, landscape and large-text layouts; disabled relocation/lock enablement, imported-lock disablement, link copying and image saving behave correctly |

Every check except the specified missing folder capability requires `pass` and an actual operation/result in `detail`. Supply the actual `device_model`, `os_version` and timezone-qualified `tested_at`. Exclude credentials, device identifiers, private comic names and signing material. Acceptance covers only the recorded device/OS; expand phone/tablet/system coverage separately.

For an independent Beta, a maintainer may download that run's `harmonyos-runtime-acceptance-template`, perform the checks and retain the reviewed report with the original HAP/manifest. Do not upload it to the standard stable Release. For bundled versions, a maintainer may upload the reviewed report to the exact draft or published version; historical mandatory policies still require it according to the original commit (replace example values). A stable report must identify that version's original HAP build; an RC report cannot be reused:

```bash
gh release upload vX.Y.Z /path/to/harmonyos-runtime-acceptance.json --repo CyrilPeng/Venera-Next
gh run rerun RUN_ID --job RELEASE_JOB_ID --repo CyrilPeng/Venera-Next
```

For historical mandatory policies, add the missing draft report and rerun only the original run's Release job. An `optional` draft can recover without waiting for a report. Reruns reuse the original build artifacts and verify names, sizes and SHA-256 for **all platform** packages. Replacement builds are rejected. The report is the sole permitted extra asset; any uploaded report must come from a human maintainer with write/maintain/admin permission. Validation checks uploader, original bytes/digest, exact source/HAP, all results and test time; invalid or failed reports stop publication even under optional or pending-acceptance policies. After adding a report to a published version, run `verify-published` against its original packages rather than attempting draft publication again.

Historical bundled `stable_required` allows prereleases without a report for testing and retains stable HAP releases as drafts until acceptance. Historical `required` retains both channels as drafts. Accepted reports permit publication and are checked afterward; original packages cannot be replaced. In independent mode, standard releases may publish after source and all standard-package verification, with an explicit independent-Beta/no-device-claim message. Actions artifacts expire after 14 days; retain the exact original packages and reports before expiry. No HarmonyOS device was connected for this change, so device acceptance remains incomplete.

## Long-Term External Comic Directories

Directory selection currently supports copy-import. [Persistent external libraries #159](https://github.com/CyrilPeng/Venera-Next/issues/159) require the storage bridge and device acceptance. System API availability is distinct from an actual app grant, unsigned packaging or host tests.

1. **Capability and grants:** query FolderSelection/FolderAuthorization on API 26 phones/tablets. Obtain a real Picker URI and mode, declare `ohos.permission.FILE_ACCESS_PERSIST`, and preserve recovery state for denial, failure, unsupported systems or revocation.
2. **Persistence and activation:** use `fileShare.persistPermission` and cold-start `activatePermission`. Persist only granted modes; remote URIs are unsupported and uninstall clears grants. Store URI/mode separately from public diagnostics.
3. **Storage bridge:** a URI is not an ordinary Dart path. Bridge enumeration, creation, read/write/seek, rename, delete and cross-isolate access for libraries, downloads, backup/export. Keep real handles through I/O cleanup and reject source/target aliases, identical objects or overlapping trees.
4. **Migration/recovery:** use LocalStorageMigration/LocalStorageRelocation staging, copying and transactions. Verify read-only, space exhaustion, revoked grants, cancellation, interruption, Unicode and large files. Reselection can restore authorization. Keep the old library until the new one survives exit, cold restart and same-key upgrade.
5. **Admission:** enable `DirectoryPicker.supportsPersistentDirectories` only after authorization, bridge, recovery and device requirements pass. `DirectorySelection.ownedCopy` and temporary sandbox copies prove only copy-import.

References: [persistent permission guide](https://developer.huawei.com/consumer/en/doc/doccenter-capabilities/file-persistpermission) and [fileShare API](https://developer.huawei.com/consumer/en/doc/doccenter-references/api/js-apis-fileshare).

## Historical Sources and Recovery

The separate HarmonyOS branch entered main; subsequent platforms use one release commit. `harmonyos-frozen-244` retains source `3e1be1391ba784bb228803525696d38c208f471f` for frozen `1.18.3+244`. `harmonyos-branch-final-245` retains the last separate candidate `ca5f7ef98ec03872d087f0b691e40f0de0080939`. Restore original schemas, locks and assets for historical validation.

The October 2026 tablet reports matched the `ef2904f` core probe, process restart and synthetic upgrade data (`reported_checks_pass`); they do not certify the complete reader, real storage recovery or renewal. Legacy upgrade tooling still reads the [Chinese](../distribution/harmonyos.zh.md) and [English probe guides](../distribution/harmonyos.en.md). Reader users follow the [current installation guide](../distribution/harmonyos-reader.en.md).

Process records, device summaries, tree comparisons and bundle recovery evidence remain in the [RC3 documentation tree](https://github.com/CyrilPeng/Venera-Next/tree/v1.18.4-rc.3/doc). Mainline guides maintain current rules.
