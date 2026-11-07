# HarmonyOS Mainline Builds and Releases

The reader and HarmonyOS adapters are maintained on `main`. Standard platforms use the root pubspec/lock with official Flutter. HarmonyOS uses the pinned Flutter OH SDK, CPF overlays, independent lock template, ArkTS bridge and native build configuration under `tool/harmonyos/`. The generated project lives in `build/harmonyos/full-app`; application runtime source matches the caller's canonical Git blobs.

## One Exact Source Commit

Mainline builds of at least 245 use schema 3 in `.github/harmonyos-next.json`, with `source_mode: release_commit`. The configuration neither embeds its own commit SHA nor resolves a floating branch. The selector obtains the caller checkout's full HEAD SHA and requires the build checkout to match exactly. The context records equal source/release commits, version, build number, Actions run ID and changelog digest.

PR checks use the exact Actions merge-candidate SHA; pushes and dispatches use the exact mainline SHA, matching the standard Flutter workflows. Both checkouts reject staged, unstaged and untracked inputs. Shared fixes require no second development branch or baseline/pin edits.

The mainline candidate workflow listens to relevant source, dependency, tool and release-configuration changes and reuses `harmonyos-release.yml`. Separate SDK directories, the controlled OH lock, native cross-compilation, strict analysis, host regressions, a real API 26 HAP, asset checks and native export audits remain mandatory. Only generated projects and downloaded overlays are patched; official Flutter, shared Pub caches and the root lock are unchanged.

## Frozen Build 244 and Required Distribution

Build 244 retains the schema 1 `.github/harmonyos-release.json`, immutable Git inputs and historical assets. The `harmonyos-frozen-244` archive tag keeps its source reachable; `harmonyos-branch-final-245` preserves the final two-branch candidate. Development continues only on `main`. Legacy schema 2 parsing remains available for historical verification; current mainline uses schema 3.

On 2026-11-07 the maintainer explicitly required HarmonyOS in every subsequent release. Mainline now sets `release_enabled: true`. Every prerelease and stable release must rebuild the unsigned ARM64 beta HAP from the same commit and include all five HarmonyOS assets. Disabling the switch fails the tag metadata gate before the full builds; publishing only the other platforms is not allowed.

The switch authorizes unsigned beta distribution after source, build and asset review. It does not claim device signing, upgrade or feature acceptance. The manifest retains `signed: false` and `runtime_verified: false`, and the installation guides describe the actual verification limits. Release verification rejects schema 2/3 previews and assets without a verified tag context. Archive tags do not match the `v*` release trigger.

Canonical committed Git blobs identify runtime source and all eight project packages. The seven managed native libraries, PNG/7z exports, third-party NOTICE and all application assets remain audited. Applicable QuickJS fixes are pinned to `f5a1f20`; see the historical [dependency implementation](official_dependency_implementation_20261107.zh.md).

## Versions and Assets

The caller's Git commit, version, build number, run ID and changelog digest are validated. Only the owned generated project receives the caller's version and changelog; the source checkout is unchanged. Native versions have three numeric components, while Dart versions retain RC suffixes. Build numbers follow mainline monotonically. The first public mainline release with a HAP is `v1.18.3-rc.3`, build **248**; RC1/RC2 retain their built tags and Actions records and have no public Release. Schema 3 permits builds from 245 onward; build 244 retains its historical source for verification only. Existing releases such as `v1.18.2` are not backfilled.

Stable `v1.18.3` uses build **249** and rebuilds alongside the other platforms from the same stable release commit; accepted candidate artifacts are not renamed into stable packages. The stable release still includes the unsigned Beta HAP and four companions. HarmonyOS device signing, reading, real-data upgrades and signing renewal remain explicit follow-up acceptance.

Every release requires:

- `VeneraNext-VERSION-harmonyos-arm64-unsigned.hap`
- `harmonyos-manifest.json`
- `harmonyos-SHA256SUMS`
- `harmonyos-install.zh.md`
- `harmonyos-install.en.md`

The bundle is `com.github.cyrilpeng.veneranext.harmony`, with label `VeneraNext (HarmonyOS Beta)` and minimum/target API 26. Checks inspect the actual `module.json`, AArch64 ELF libraries and exact hashes, complete Dart/asset source inventory, and embedded versions. Guides come from the exact build commit. Keep unsigned/beta labeling explicit; successful compilation is not device upgrade or certificate-renewal acceptance.

## Publication Gates and Build-Only Verification

GitHub's release-by-tag endpoint returns published releases only. Draft verification searches the authenticated, fully paginated release list for exactly one matching tag and fetches its current assets by numeric release ID. Missing or ambiguous drafts, changed IDs/tags and unexpected states stop publication. Published verification uses the public tag endpoint, and creation explicitly targets the caller's source SHA. RC2 uploaded all 26 assets as a draft, but the old lookup received HTTP 404; RC3 reruns the complete release path with the corrected lookup.

The full workflow's `Release` requires Quality, the existing platform Build and HarmonyOS. Missing, damaged, stale or mismatched HAP assets must never use `continue-on-error`. Upload to a draft first, then verify all five HarmonyOS assets through the GitHub API: names, sizes, upload state and SHA-256. Publish only after verification, then check the public assets again. Investigate failures rather than silently omitting HarmonyOS.

The publishing job checks out the two source trees into sibling `release-source/` and `harmonyos-source/` directories. Generated notes and packages live alongside them in `release_notes.md` and `outputs/`. Scripts run from `release-source/`; generated inputs remain outside both source directories, which still reject untracked and uncommitted inputs.

Branch dispatches and mainline PR runs of `HarmonyOS Release HAP` create next-candidate Actions artifacts only, never tags or releases. Relevant mainline PRs/pushes use the candidate workflow with the same exact source SHA as standard-platform checks:

```bash
python3 -m unittest discover -s .github/scripts/tests -p test_harmonyos_release.py -v
python3 .github/scripts/harmonyos_release.py config
python3 .github/scripts/harmonyos_release.py config --preview-next
gh workflow run harmonyos-release.yml --ref main
```

Platform scripts and SDK baselines live in `tool/harmonyos/README.md` on mainline. The commercial API 26 SDK uses a checksum-pinned community CI mirror, not claimed official checksums. No signing secrets are read. See the [user guide](../distribution/harmonyos-reader.en.md) for installation and limitations. This workflow does not comment on, close, reopen or track issues.
