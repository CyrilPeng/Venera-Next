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

## Startup Validation And Diagnostics

Silent installation and upgrades do not launch the app automatically. Interactive setup still offers the option to run the app after installation. Launching the app again restores the existing window and exits the new process with code `0`. Real window or Flutter initialization failures still return a nonzero exit code.

Native startup logging begins before Dart initialization:

```text
%LOCALAPPDATA%\com.github.cyrilpeng\VeneraNext\logs\windows-startup.log
```

The log records UTC timestamps, process IDs, startup stages, and applicable Windows error codes. It does not record comic content, accounts, or command-line arguments. Each log is limited to 128 KiB, with at most one rotated `windows-startup.previous.log`. An unwritable directory or a locked log does not prevent startup. Loader failures before the application entry point, such as missing DLLs, may occur before a log can be created; also inspect the Windows error message in those cases.

`Validation-Executable-Error` means that the post-installation execution check needs investigation, not necessarily that installation failed. Check the installation result, exit code, and startup diagnostics first. Do not add real failure codes to `InstallerSuccessCodes` to bypass validation.

Windows PR CI runs native regression tests and checks first-frame rendering, continued execution for more than 10 seconds, repeated launches and minimized-window restoration, and failure diagnostics when Flutter resources are missing. Release builds also install silently into a temporary directory, verify that setup does not launch the app, and run the same execution checks. Logs are retained as short-lived Actions artifacts.

Run the native regression tests locally without loading Dart or everyday comic data:

```powershell
flutter build windows --debug
cmake -S windows/tests -B build/windows/startup_tests -A x64
cmake --build build/windows/startup_tests --config Debug
ctest --test-dir build/windows/startup_tests -C Debug --output-on-failure
```

`.github/scripts/test_windows_startup.ps1` installs or runs the real app. It only permits disposable GitHub Actions Windows runners and refuses to continue when an existing installation, process, or app data is detected. Do not bypass this restriction in your everyday account. Do not replace published installers when investigating older versions; ship the fix in a new patch release.

## Notes

- Do not casually change the `AppId` in `windows/build.iss`; it affects how winget identifies installed apps.
- The installer filename must remain `VeneraNext-<version>-windows-installer.exe`; the manifest script validates this naming.
- If Windows ARM64 stable releases are added later, the winget installer manifest needs an `arm64` installer entry.
- Code signing is not currently required by the scripts, but should be prioritized for winget distribution to reduce SmartScreen and installation trust issues.
