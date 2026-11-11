# HarmonyOS Mainline Builds and Releases

The reader and HarmonyOS adapters are maintained on `main`. Standard platforms use the root pubspec/lock with official Flutter. HarmonyOS uses the pinned Flutter OH SDK, CPF overlays, independent lock template, ArkTS bridge and native build configuration under `tool/harmonyos/`. The generated project lives in `build/harmonyos/full-app`; application runtime source matches the caller's canonical Git blobs.

## One Exact Source Commit

Mainline builds of at least 245 use schema 3 in `.github/harmonyos-next.json`, with `source_mode: release_commit`. The configuration neither embeds its own commit SHA nor resolves a floating branch. The selector obtains the caller checkout's full HEAD SHA and requires the build checkout to match exactly. The context records equal source/release commits, version, build number, Actions run ID and changelog digest.

PR checks use the exact Actions merge-candidate SHA; pushes and dispatches use the exact mainline SHA, matching the standard Flutter workflows. Both checkouts reject staged, unstaged and untracked inputs. Shared fixes require no second development branch or baseline/pin edits.

The mainline candidate workflow listens to relevant source, dependency, tool and release-configuration changes and reuses `harmonyos-release.yml`. Separate SDK directories, the controlled OH lock, native cross-compilation, strict analysis, host regressions, a real API 26 HAP, asset checks and native export audits remain mandatory. Only generated projects and downloaded overlays are patched; official Flutter, shared Pub caches and the root lock are unchanged.

## Frozen Build 244 and Required Distribution

Build 244 retains the schema 1 `.github/harmonyos-release.json`, immutable Git inputs and historical assets. The `harmonyos-frozen-244` archive tag keeps its source reachable; `harmonyos-branch-final-245` preserves the final two-branch candidate. Development continues only on `main`. Legacy schema 2 parsing remains available for historical verification; current mainline uses schema 3.

On 2026-11-07 the maintainer explicitly required HarmonyOS in every subsequent release. Mainline now sets `release_enabled: true`. Every prerelease and stable release must rebuild the unsigned ARM64 beta HAP from the same commit and include every HarmonyOS asset required by that commit's configuration. Disabling the switch fails the tag metadata gate before the full builds; publishing only the other platforms is not allowed.

The switch authorizes unsigned beta distribution after source, build and asset review. It does not claim device signing, upgrade or feature acceptance. The manifest retains `signed: false` and `runtime_verified: false`, and the installation guides describe the actual verification limits. Release verification rejects schema 2/3 previews and assets without a verified tag context. Archive tags do not match the `v*` release trigger.

Canonical committed Git blobs identify runtime source and all eight project packages. The seven managed native libraries, PNG/7z exports, third-party NOTICE and all application assets remain audited. Applicable QuickJS fixes are pinned to `f5a1f20`; see the historical [dependency implementation](official_dependency_implementation_20261107.zh.md).

## Versions and Assets

The caller's Git commit, version, build number, run ID and changelog digest are validated. Only the owned generated project receives the caller's version and changelog; the source checkout is unchanged. Native versions have three numeric components, while Dart versions retain RC suffixes. Build numbers follow mainline monotonically. The first public mainline release with a HAP is `v1.18.3-rc.3`, build **248**; RC1/RC2 retain their built tags and Actions records and have no public Release. Schema 3 permits builds from 245 onward; build 244 retains its historical source for verification only. Existing releases such as `v1.18.2` are not backfilled.

Stable `v1.18.3` uses build **249** and rebuilds alongside the other platforms from the same stable release commit; accepted candidate artifacts are not renamed into stable packages. The stable release still includes the unsigned Beta HAP and four companions. HarmonyOS device signing, reading, real-data upgrades and signing renewal remain explicit follow-up acceptance.

Starting with the next release, the mainline schema-3 configuration uses `guide_delivery: repository` and requires three HarmonyOS release assets:

- `VeneraNext-VERSION-harmonyos-arm64-unsigned.hap`
- `harmonyos-manifest.json`
- `harmonyos-SHA256SUMS`

The Chinese and English installation guides live at `doc/distribution/harmonyos-reader.*.md`. README links are relative, and generated release notes link to the guides at the exact release tag. Both guides must exist and be nonempty in the source commit. Checksums are generated for each HAP, so `harmonyos-SHA256SUMS` remains a release asset.

Historical configurations without `guide_delivery` still require those three files plus `harmonyos-install.zh.md` and `harmonyos-install.en.md`, with guide contents checked against the original commit. Published versions such as `v1.18.3` retain their five assets and tags; the new policy does not rewrite historical assets. Unknown policy values are rejected.

The bundle is `com.github.cyrilpeng.veneranext.harmony`, with label `VeneraNext (HarmonyOS Beta)` and minimum/target API 26. Checks inspect the actual `module.json`, AArch64 ELF libraries and exact hashes, complete Dart/asset source inventory, and embedded versions. Guides come from the exact build commit. Keep unsigned/beta labeling explicit; successful compilation is not device upgrade or certificate-renewal acceptance.

## Publication Gates and Build-Only Verification

GitHub's release-by-tag endpoint returns published releases only. Draft verification searches the authenticated, fully paginated release list for exactly one matching tag and fetches its current assets by numeric release ID. Missing or ambiguous drafts, changed IDs/tags and unexpected states stop publication. Published verification uses the public tag endpoint, and creation explicitly targets the caller's source SHA. RC2 uploaded all 26 assets as a draft, but the old lookup received HTTP 404; RC3 reruns the complete release path with the corrected lookup.

The full workflow's `Release` requires Quality, the existing platform Build and HarmonyOS. Missing, damaged, stale or mismatched HAP assets must never use `continue-on-error`. Create or reuse a draft, then verify every required HarmonyOS asset through the GitHub API: names, sizes, upload state and SHA-256. The version's device-acceptance policy below must also pass before publication. Recheck assets and any acceptance report afterward. Investigate failures rather than silently omitting HarmonyOS.

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

Starting with `v1.18.4-rc.1+250`, the schema-3 configuration uses `runtime_acceptance: stable_required`. Prereleases may be published for device testing after all source, build and asset checks pass. Without a report, device acceptance remains pending. Stable releases require an accepted report before publication. Any report attached to a prerelease is also validated strictly; invalid or failed reports cannot be ignored. Historical `required` policies still require reports for both channels, and historical tags without the field keep their original behavior. Unknown values are rejected and published packages are not rewritten.

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

After testing and reviewing, a maintainer uploads the report to the exact version draft or public prerelease (replace example values). A stable report must identify the freshly rebuilt stable HAP; an RC report cannot be reused:

```bash
gh release upload vX.Y.Z /path/to/harmonyos-runtime-acceptance.json --repo CyrilPeng/Venera-Next
gh run rerun RUN_ID --job RELEASE_JOB_ID --repo CyrilPeng/Venera-Next
```

After adding a missing draft report, rerun only the original run's Release job. Reruns reuse the original build artifacts and verify names, sizes and SHA-256 for **all platform** packages. Replacement builds are rejected. The report is the sole permitted extra asset and must be uploaded by a human maintainer with write/maintain/admin permission. Validation checks uploader, original bytes/digest, exact source/HAP, all results and test time; invalid or failed reports stop publication even when pending acceptance is allowed. After adding a report to a public prerelease, run `verify-published` against its original packages rather than attempting draft publication again.

Under `stable_required`, a prerelease without a report produces `ready=true` with an explicit pending-device-acceptance message. A stable release without a report produces `ready=false`, retains every draft package and skips publication/CDN steps. Historical `required` policies retain drafts for both channels when reports are missing. Accepted reports produce `ready=true`; any public report is checked again. Successful builds alone establish neither publication nor device acceptance. Complete draft acceptance and rerun within the Actions artifact retention period (currently 14 days). Keep original packages if artifacts expire; do not replace tested packages. No HarmonyOS device was connected for this change, so device acceptance remains incomplete.
