# HarmonyOS Release Builds

The complete reader uses an independent `HarmonyOS` branch, Flutter OH SDK and dependency lock. Mainline keeps its existing toolchain. The unsigned ARM64 phone/tablet HAP remains a beta, not a claim of complete platform support. Signing, device authorization and private keys remain on the user's machine.

## Immutable Source

`.github/harmonyos-release.json` records full `source_commit` and shared `main_baseline` SHAs, plus `first_release_build`. Both checkouts must contain that baseline, and the HarmonyOS checkout must exactly match the pin. Branch names, short SHAs and dirty source inputs are rejected.

After the baseline, mainline may change documentation, workflows, release metadata and only the version line in `pubspec.yaml`. Runtime code, assets, tests, dependency locks or native toolchain changes stop the build until HarmonyOS is synchronized and reviewed again. Do not bypass synchronization by merely changing the baseline, or rename an old HAP for a new release.

1. Integrate common fixes into mainline and HarmonyOS while preserving shared ancestry. Do not squash/rebase away a baseline after pinning it.
2. Verify the independent OH lock, platform host regressions and a real HAP build; review any changed platform limitations.
3. Update the full source SHA and common baseline, changelog and installation guides where needed.
4. Pin/release-workflow PRs run `HarmonyOS Release HAP`. Merge only after quality and HAP checks pass for the candidate code.

## Frozen Build 244 and the Next Candidate

`1.18.3+244` continues to use the schema 1 `.github/harmonyos-release.json`; its source, independent lockfile and historical Release assets remain frozen. Builds of at least 245 use the schema 2 `.github/harmonyos-next.json` without falling back to the old pin. Both pins must be part of the caller's committed Git inputs.

Mainline PRs and branch dispatches use `--preview-next`. While main remains at 244, the preview uses the candidate's own `1.18.3+245` version, build number and changelog, recording the actual caller commit, version, build and Actions run ID separately. The complete HAP audit covers Git-file digests for all eight project packages, seven managed native libraries, PNG/7z exports and the generated third-party NOTICE. The existing HarmonyOS Rhttp explicit-loading interface is verified against its actual platform variant.

Source and project-package fingerprints use committed canonical Git blobs, retaining original binary bytes independently of checkout CRLF rules for PowerShell and similar files. Manifest preparation rejects both working-tree and staged source drift so committed fingerprints cannot conceal changed build inputs.

The next pin remains `release_enabled: false`. Applicable QuickJS core fixes are pinned at `f5a1f20`; Linux and Windows 32/64-bit memory checks passed and the necessary patch PR was merged. The [implementation record](official_dependency_implementation_20261107.zh.md) distinguishes core, application and platform validation. The next candidate pins HarmonyOS `d842be19c826d43cf64f3c4a131fd5742466c37f` and shared baseline `5f7c572e1f1d048e4fe773a06ce3000dcd0b6cdd`, which contains all shared runtime code, dependencies, tools and tests. Platform review and device signing remain separate acceptance steps; passing a preview never enables tag distribution. Release verification rejects preview assets and schema 2 assets without a verified tag context.

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

Branch dispatches and mainline PR runs of `HarmonyOS Release HAP` create next-candidate Actions artifacts only, never tags or releases. HarmonyOS-targeted PRs use the independent candidate workflow to verify their exact head:

```bash
python3 -m unittest discover -s .github/scripts/tests -p test_harmonyos_release.py -v
python3 .github/scripts/harmonyos_release.py config
python3 .github/scripts/harmonyos_release.py config --preview-next
gh workflow run harmonyos-release.yml --ref main
```

Platform scripts and SDK baselines live in `tool/harmonyos/README.md` on the HarmonyOS branch. The commercial API 26 SDK uses a checksum-pinned community CI mirror, not claimed official checksums. No signing secrets are read. See the [user guide](../distribution/harmonyos-reader.en.md) for installation and limitations. This workflow does not comment on, close, reopen or track issues.
