# HarmonyOS Experimental Sideload Checks

中文：[HarmonyOS 实验签装与升级验证](harmonyos.zh.md)

> For diagnostic probes on the `HarmonyOS` branch only, not a Venera-Next reader release. Installation through the helper, device execution, in-place upgrades and certificate renewal are not yet verified. CI success does not establish these results. Mainline and Android TV remain unchanged; #77 is not delivered.

## Approach And Scope

Following the [Kazumi guide](https://kazumi.app/docs/misc/how-to-install-in-ohos), the project builds unsigned HAPs. Users authorize, sign and install them through [Xiaobai / Auto-Installer](https://github.com/likuai2010/auto-installer) using their own accounts. Users do not build source or install DevEco, but developer accounts, debugging authorization and signing expiry still apply. Maintainers do not sign packages for individual users.

- First validate an ARM64 HarmonyOS phone with a Windows computer. macOS is a later validation path; README platform claims do not ensure every release has corresponding binaries.
- On 2026-10-28, the latest public helper release was [3.1.0](https://github.com/likuai2010/auto-installer/releases/tag/3.1.0), with Windows, macOS and HarmonyOS assets. This project has not installed or fully audited that third-party tool.
- **The current lab minimum SDK is `26.0.0`; the HAP encodes minimum/target API as `260000026`.** This is this experiment's restriction, not a universal Flutter OHOS limit. Do not copy Kazumi's compatibility claims or infer compatibility from a marketing OS name. Report incompatible devices before evaluating a lower baseline; do not edit metadata to force installation.
- Continue reusing Flutter/Dart on `HarmonyOS`. The helper does not port plugins, background tasks, files or the reader. DroiTong remains an alternative for running the Android app, a different test route.

## Obtain The Test Kit

Maintainers run `HarmonyOS Experimental HAP` on `HarmonyOS`. Only a completely successful run uploads `harmonyos-unsigned-lab-haps-<run_id>` in Actions, retained for 14 days. GitHub login may be needed to download Actions artifacts. No public Release is created and probes are not added to a mainline release.

Extract one run's kit:

| File | Purpose |
|---|---|
| `harmonyos-blank-arm64-unsigned.hap` | Blank app for initial signing/install diagnostics |
| `harmonyos-probe-baseline-arm64-unsigned.hap` | Baseline `0.2.0+2`, creates synthetic data |
| `harmonyos-probe-upgrade-arm64-unsigned.hap` | Upgrade `0.2.1+3`, checks existing baseline data only |
| `sideload-manifest.json` | Identity, versions, source commit, pair ID, minimum SDK and hashes |
| `SHA256SUMS` | Original baseline/upgrade HAP SHA-256 hashes |
| `install.zh.md` / `install.en.md` | Offline copies of these instructions |

Both original probes use `com.github.cyrilpeng.harmonyos_probe`, separate from Android production and the future HarmonyOS reader. The blank app is not the baseline. Do not mix pairs. CI reads actual `module.json` and embedded build identity, checks the bundle, increasing versions and minimum/target API, and audits native libraries and exported bytes, not just filenames.

Verify original HAPs with PowerShell and compare against the same kit's `SHA256SUMS`:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\harmonyos-probe-baseline-arm64-unsigned.hap
Get-FileHash -Algorithm SHA256 -LiteralPath .\harmonyos-probe-upgrade-arm64-unsigned.hap
```

Hashes check original bytes, not independently authenticate the source. Obtain files from this project's run. Re-signing changes the package; do not compare re-signed HAPs to original hashes.

## Prepare And Install The Blank App

1. Download the Windows helper from its official repository and prepare Java as instructed. Avoid unofficial modified builds.
2. Enable developer options and wireless debugging on the phone. Connect and authorize on a trusted network, following current device/tool instructions.
3. Prepare your own Huawei developer account as instructed by Kazumi/the helper. Personally log in and authorize on a verified Huawei page. Do not send maintainers passwords, codes, tokens, private keys, certificate passwords or UDIDs.
4. Select the blank unsigned HAP, check the displayed package/device requirements, and let the helper sign/install it. Confirm it starts before testing probes.
5. On failure, report the stage, sanitized error code and device/OS/helper versions. Do not disable signature checks, rename bundles or clear production data. Close debugging connections when finished.

Initial preparation requires another device. The helper's HarmonyOS client must itself first be installed through another platform. Do not promise a fresh phone can bootstrap everything alone. This project neither bundles the helper nor takes over its login flow.

## Baseline, Restart And In-Place Upgrade

Use only the isolated probe. **Do not import real sources, accounts, favorites or downloads.**

1. **Baseline:** sign/install the baseline HAP. Check `baseline / 0.2.0+2` and the pair ID. Run core checks. Sideload data must be `baseline_ready`; all three core checks must pass. Copy the full report to `baseline.json`.
2. **Restart:** force-stop the probe without clearing data, relaunch and run checks. Expect `baseline_ready`, a passing `process_restart`, and `core_checks_pass`. Save `restart.json`. Backgrounding, repeating in one process or reopening a database does not establish a process restart.
3. **Upgrade:** do not uninstall or clear data. Preserve the signing identity/key and sign/install the matching upgrade HAP. Check `upgrade / 0.2.1+3`. Run checks; expect `upgrade_data_present`, passing core/restart checks. Save `upgrade.json`.
4. Record device, full OS/helper versions, date, install/upgrade method, any bundle changes and signature/uninstall prompts. The same account/helper does not guarantee the same signing key. Do not upload personal signed packages or signing materials.

Only baseline creates the synthetic marker. Upgrade returns `missing_baseline` instead of recreating data. `pair_mismatch` and `invalid_state` preserve existing data. Core success cannot override these failures.

Keep reports from three distinct launches of the same pair, with the same marker and first-launch ID. If the initial report was lost, checks failed, or another pair exists, record why; never edit markers or fabricate reports. Restarting the entire experiment may require explicitly resetting **only the diagnostic app's synthetic data**. This is not a production-reader recovery procedure.

## Maintainer Review

After the user voluntarily provides minimal, manually sanitized reports, maintainers run:

```powershell
python tool/harmonyos/review_sideload.py --manifest <sideload-manifest.json> --baseline <baseline.json> --restart <restart.json> --upgrade <upgrade.json>
```

The tool treats JSON as data; it does not download attachments or execute content. Incomplete inputs, host-platform reports, core failures, repeated launch IDs, mixed builds/pairs and missing/recreated markers cannot pass. `reported_checks_pass` means only consistent reported core, restart and synthetic upgrade-data checks. It is not hardware attestation, signature/key validation, certificate renewal, full-reader validation or real-data migration.

Require independent device reproduction before full-reader integration. Record sanitized conclusions, tested devices and failures, not raw user reports or identifiers in Git. Users must review screenshots/logs before sharing.

## Renewal And Later Releases

- Do not promise a universal 14/180-day or one-year lifetime. Certificates, profiles and other testing rules differ; inspect actual validity and current policies.
- Preserve signing materials locally using supported helper features. Certificate renewal is not the same as changing keys; an in-place upgrade does not prove expired-certificate renewal works.
- Preserve data before diagnosing renewal/signature mismatches. Do not default to uninstalling; the full reader needs tested backup/restore and migration first.
- Start with manual HAP download and helper installation. Later validate app-to-helper file handoff without inventing URI schemes, handling Huawei login in-app or promising silent updates.
- Public reader Alpha requires the source-to-offline loop, WebView/files/backup and upgrade checks. Use separate `harmonyos-*` prerelease tags, not Latest, and validate isolation from `v*` publishing and mainline update selection. This stage creates neither such tags nor release jobs.
- Update CHANGELOG before Chinese conventional commits. CI success, publication or silence does not automatically close #77.
