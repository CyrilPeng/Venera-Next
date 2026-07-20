# Windows Distribution

Chinese version: [windows.zh.md](windows.zh.md)

## Release Artifacts

Windows stable releases are built by `.github/workflows/main.yml` through the `完整构建` workflow:

- `VeneraNext-<version>-windows-installer.exe`: Inno Setup installer, suitable for winget.
- `VeneraNext-<version>-windows.zip`: portable package, suitable for manual download and extraction.

VeneraNext is officially available through winget with package ID `CyrilPeng.VeneraNext`. winget uses the installer and does not manage the portable zip package.

## Install And Upgrade With Winget

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
winget show --id CyrilPeng.VeneraNext --exact
```

After a GitHub Release is published, its new winget manifest still needs to pass review and the publishing pipeline in `microsoft/winget-pkgs`, so the version shown by winget may temporarily lag behind. Once publishing finishes, run `winget source update` before trying the upgrade again.

Portable zip installations are not registered as winget-managed applications and must still be updated manually. Installer builds use a stable `AppId`, which lets winget identify the installed application and its upgrade relationship.

## Generate Winget Manifest

When a stable release tag is published, the main release workflow generates the `winget_manifest` artifact. You can also manually run the `准备 Winget Manifest` workflow and input an existing stable tag.

The manual workflow only generates the manifest artifact by default. To also create a PR to `microsoft/winget-pkgs`:

1. Configure `WINGET_PKGS_TOKEN` in repository secrets. The token needs enough permission to fork the repository and create a PR to `microsoft/winget-pkgs`.
2. Enable `submit_pr` when running the `准备 Winget Manifest` workflow.

The workflow uses `.github/scripts/submit_winget_manifest_pr.py` to update the manifest branch in the `CyrilPeng/winget-pkgs` fork through the GitHub API and create a PR, avoiding a full clone of the large `winget-pkgs` repository.

Local generation command:

```powershell
$version = "1.13.0"
python .github\scripts\generate_winget_manifest.py `
  --version $version `
  --installer "build\windows\VeneraNext-$version-windows-installer.exe" `
  --output build\winget `
  --print-path
```

The generated directory follows the winget-pkgs layout:

```text
build/winget/manifests/c/CyrilPeng/VeneraNext/<version>/
```

## Submit To winget-pkgs

The initial package submission has already been accepted. Each later stable release should create a PR with a new version directory. If `WINGET_PKGS_TOKEN` is configured, the `submit_pr` option of the `准备 Winget Manifest` workflow can do this directly.

After the package is already accepted, WingetCreate can be used for updates:

```powershell
$version = "1.13.0"
wingetcreate update CyrilPeng.VeneraNext `
  -u "https://github.com/CyrilPeng/Venera-Next/releases/download/v$version/VeneraNext-$version-windows-installer.exe" `
  -v $version `
  -t <GitHub PAT> `
  --submit
```

Do not submit winget manifests for `-rc` prerelease versions. winget should follow stable releases only.

A merged PR is not immediately visible to clients; the winget publishing pipeline must also finish. After the PR reports `Publish-Pipeline-Succeeded`, maintainers should verify the public source with `winget search --id CyrilPeng.VeneraNext --exact`.

## Notes

- Do not casually change the `AppId` in `windows/build.iss`; it affects how winget identifies installed apps.
- The installer filename must remain `VeneraNext-<version>-windows-installer.exe`; the manifest script validates this naming.
- If Windows ARM64 stable releases are added later, the winget installer manifest needs an `arm64` installer entry.
- Code signing is not currently required by the scripts, but should be prioritized for winget distribution to reduce SmartScreen and installation trust issues.
