# HarmonyOS Release Builds

The complete reader uses an independent `HarmonyOS` branch, Flutter OH SDK and dependency lock. Mainline keeps its existing toolchain. The unsigned ARM64 phone/tablet HAP remains a beta, not a claim of complete platform support. Signing, device authorization and private keys remain on the user's machine.

## Immutable Source

`.github/harmonyos-release.json` records full `source_commit` and shared `main_baseline` SHAs, plus `first_release_build`. Both checkouts must contain that baseline, and the HarmonyOS checkout must exactly match the pin. Branch names, short SHAs and dirty source inputs are rejected.

After the baseline, mainline may change documentation, workflows, release metadata and only the version line in `pubspec.yaml`. Runtime code, assets, tests, dependency locks or native toolchain changes stop the build until HarmonyOS is synchronized and reviewed again. Do not bypass synchronization by merely changing the baseline, or rename an old HAP for a new release.

1. Integrate common fixes into mainline and HarmonyOS while preserving shared ancestry. Do not squash/rebase away a baseline after pinning it.
2. Verify the independent OH lock, platform host regressions and a real HAP build; review any changed platform limitations.
3. Update the full source SHA and common baseline, changelog and installation guides where needed.
4. Pin/release-workflow PRs run `HarmonyOS Release HAP`. Merge only after quality and HAP checks pass for the candidate code.

## Versions and Assets

The caller's Git commit, version, build number, run ID and changelog digest are validated. Only the owned generated project receives the caller's version and changelog; the pinned checkout is unchanged. Native versions have three numeric components, while Dart versions retain RC suffixes. Build numbers follow mainline monotonically. The first tagged HAP release must have build **244** or later; existing releases such as `v1.18.2` are not backfilled.

Every release requires:

- `VeneraNext-VERSION-harmonyos-arm64-unsigned.hap`
- `harmonyos-manifest.json`
- `harmonyos-SHA256SUMS`
- `harmonyos-install.zh.md`
- `harmonyos-install.en.md`

The bundle is `com.github.cyrilpeng.veneranext.harmony`, with label `VeneraNext (HarmonyOS Beta)` and minimum/target API 26. Checks inspect the actual `module.json`, AArch64 ELF libraries and exact hashes, complete Dart/asset source inventory, and embedded versions. Guides come from the pinned HarmonyOS commit. Keep unsigned/beta labeling explicit; successful compilation is not device upgrade or certificate-renewal acceptance.

## Publication Gates and Build-Only Verification

The full workflow's `Release` requires Quality, the existing platform Build and HarmonyOS. Missing, damaged, stale or mismatched HAP assets must never use `continue-on-error`. Upload to a draft first, then verify all five HarmonyOS assets through the GitHub API: names, sizes, upload state and SHA-256. Publish only after verification, then check the public assets again. Investigate failures rather than silently omitting HarmonyOS.

Branch dispatches and PR runs of `HarmonyOS Release HAP` create Actions artifacts only, never tags or releases. They exercise current-version wiring without claiming a HAP was publicly released for that version:

```bash
python3 -m unittest discover -s .github/scripts/tests -p test_harmonyos_release.py -v
python3 .github/scripts/harmonyos_release.py config
gh workflow run harmonyos-release.yml --ref main
```

Platform scripts and SDK baselines live in `tool/harmonyos/README.md` on the HarmonyOS branch. The commercial API 26 SDK uses a checksum-pinned community CI mirror, not claimed official checksums. No signing secrets are read. See the [user guide](../distribution/harmonyos-reader.en.md) for installation and limitations. This workflow does not comment on, close, reopen or track issues.
