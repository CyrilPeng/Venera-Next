# HarmonyOS Experimental Sideload Checks

中文：[HarmonyOS 实验签装与升级验证](harmonyos.zh.md)

> For diagnostic probes on the `HarmonyOS` branch only, not a Venera-Next reader release. One volunteer tablet's feedback and three reports pass review for this pair's core, process restart and synthetic upgrade-data checks only. Signing identity, certificate renewal, real data migration and the full reader remain unverified. See the [scoped review reply on #77 (Chinese)](https://github.com/CyrilPeng/Venera-Next/issues/77#issuecomment-6486795892) for the device scope and evidence; neither CI nor one device's reports establish general support. Mainline and Android TV remain unchanged; #77 is not delivered.

## Approach And Scope

Following the [Kazumi guide](https://kazumi.app/docs/misc/how-to-install-in-ohos), the project builds unsigned HAPs. Users authorize, sign and install them through [Xiaobai / Auto-Installer](https://github.com/likuai2010/auto-installer) using their own accounts. Users do not build source or install DevEco, but developer accounts, debugging authorization and signing expiry still apply. Maintainers do not sign packages for individual users.

- Blank and probe HAPs explicitly declare ARM64 `phone` and `tablet` lab targets, not PC/TV. Declarations and host layout tests do not establish device support. Existing HarmonyOS-helper users may keep their installed helper; a Windows computer is an alternative for initial setup.
- On 2026-10-28, the latest public helper release was [3.1.0](https://github.com/likuai2010/auto-installer/releases/tag/3.1.0), with Windows, macOS and HarmonyOS assets. This project has not installed or fully audited that third-party tool.
- **The current lab minimum SDK is `26.0.0`; the HAP encodes minimum/target API as `260000026`.** This is this experiment's restriction, not a universal Flutter OHOS limit. Do not copy Kazumi's compatibility claims or infer compatibility from a marketing OS name. Report incompatible devices before evaluating a lower baseline; do not edit metadata to force installation.
- Continue reusing Flutter/Dart on `HarmonyOS`. The helper does not port plugins, background tasks, files or the reader. DroiTong remains an alternative for running the Android app, a different test route.

[Huawei's upgrade guide](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/upgrade-adaptation) maps HarmonyOS 7.0 to API `26.0.0`. The [suite overview](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/overview-2600) explains checking the API in Settings / About device. Existing feedback covers only the recorded device/patch and probe pair; other devices and patches need their own execution checks. Stop on compatibility errors; do not upgrade or flash the OS for this test.

## Obtain The Test Kit

Maintainers run `HarmonyOS Experimental HAP` on `HarmonyOS`. Only a completely successful run uploads `harmonyos-unsigned-lab-haps-<run_id>` in Actions, retained for 14 days. GitHub login may be needed to download Actions artifacts. No public Release is created and probes are not added to a mainline release.

Extract one run's kit:

| File | Purpose |
|---|---|
| `harmonyos-blank-arm64-unsigned.hap` | Blank app for initial signing/install diagnostics |
| `harmonyos-probe-baseline-arm64-unsigned.hap` | Baseline `0.3.0+4`, creates synthetic data |
| `harmonyos-probe-upgrade-arm64-unsigned.hap` | Upgrade `0.3.1+5`, checks existing baseline data only |
| `sideload-manifest.json` | Identity, versions, source commit, pair ID, minimum SDK and hashes |
| `SHA256SUMS` | Original baseline/upgrade HAP SHA-256 hashes |
| `install.zh.md` / `install.en.md` | Offline copies of these instructions |

Both original probes use `com.github.cyrilpeng.harmonyos_probe`, separate from Android production and the future HarmonyOS reader. The blank app is not the baseline. Do not mix runs/pairs or earlier `0.2.x` phone experiments with this `0.3.x` kit. CI reads actual `module.json` and embedded identity, checks the bundle, increasing versions, `phone`/`tablet` targets and minimum/target API, and audits native libraries and exported bytes, not just filenames.

Verify original HAPs with PowerShell and compare against the same kit's `SHA256SUMS`:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\harmonyos-probe-baseline-arm64-unsigned.hap
Get-FileHash -Algorithm SHA256 -LiteralPath .\harmonyos-probe-upgrade-arm64-unsigned.hap
```

Hashes check original bytes, not independently authenticate the source. Obtain files from this project's run. Re-signing changes the package; do not compare re-signed HAPs to original hashes.

## Prepare And Install The Blank App

### Existing HarmonyOS Helper Users

Keep the installed helper; this test does not require reinstalling it or adding Windows, Java or DevEco. Sign in to GitHub, download the kit ZIP from the single run specified by the maintainer and extract it to a files directory. **Do not extract or rename the HAPs themselves.** Select a local HAP in the installed HarmonyOS helper and follow that version's actual connection/authorization/signing UI. No unverified share action or URI is assumed. Initial helper setup and developer authorization still apply; personally handle login and signing materials.

Start with the blank HAP and confirm it installs and opens. Report the stage and sanitized error code if file selection, connection, authorization or installation fails; do not remove the helper, certificates or production app data. Then follow baseline, force-stop/restart and upgrade below, saving each report with `Copy report`. Preserve the bundle and signing identity/key. Stop on signature mismatch or uninstall prompts; uninstall/reinstall is not an upgrade test.

### Users Without A Prepared Helper

1. Download the Windows helper from its official repository and prepare Java as instructed. Avoid unofficial modified builds.
2. Enable developer options and wireless debugging on the phone/tablet. Connect and authorize on a trusted network, following current device/tool instructions.
3. Prepare your own Huawei developer account as instructed by Kazumi/the helper. Personally log in and authorize on a verified Huawei page. Do not send maintainers passwords, codes, tokens, private keys, certificate passwords or UDIDs.
4. Select the blank unsigned HAP, check the displayed package/device requirements, and let the helper sign/install it. Confirm it starts before testing probes.
5. On failure, report the stage, sanitized error code and device/OS/helper versions. Do not disable signature checks, rename bundles or clear production data. Close debugging connections when finished.

Initial setup from scratch requires another device: the HarmonyOS helper must first be installed through another platform. Do not promise a fresh device can bootstrap everything alone; this does not require existing HarmonyOS-helper users to repeat setup. This project neither bundles the helper nor takes over its login flow.

## Baseline, Restart And In-Place Upgrade

Use only the isolated probe. **Do not import real sources, accounts, favorites or downloads.**

1. **Baseline:** sign/install the baseline HAP. Check `baseline / 0.3.0+4` and the pair ID. Run core checks. Sideload data must be `baseline_ready`; all three core checks must pass. Copy the full report to `baseline.json`.
2. **Restart:** force-stop the probe without clearing data, relaunch and run checks. Expect `baseline_ready`, a passing `process_restart`, and `core_checks_pass`. Save `restart.json`. Backgrounding, repeating in one process or reopening a database does not establish a process restart.
3. **Upgrade:** do not uninstall or clear data. Preserve the signing identity/key and sign/install the matching upgrade HAP. Check `upgrade / 0.3.1+5`. Run checks; expect `upgrade_data_present`, passing core/restart checks. Save `upgrade.json`.
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
