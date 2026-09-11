# Windows 分发

## 发布产物

Windows 正式发布由 `.github/workflows/main.yml`（`完整构建` 工作流）构建：

- `VeneraNext-<version>-windows-installer.exe`：Inno Setup 安装器，适合 winget。
- `VeneraNext-<version>-windows.zip`：便携包，适合手动下载解压。

VeneraNext 已正式收录到 winget，包 ID 为 `CyrilPeng.VeneraNext`。winget 默认使用安装器，不管理 zip 便携包。

## 使用 winget 安装和更新

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
winget show --id CyrilPeng.VeneraNext --exact
```

GitHub Release 发布后，新的 winget manifest 仍需经过 `microsoft/winget-pkgs` 审核和发布流水线，因此 winget 中显示的版本可能暂时落后。审核完成后可以执行 `winget source update` 刷新本地索引，再运行升级命令。

通过 zip 便携包运行的版本不会注册为 winget 管理的软件，需要继续手动覆盖更新。安装器版会注册固定的 `AppId`，这是 winget 识别安装和升级关系的依据。

## 生成 winget manifest

正式版 tag 发布时，主发布工作流会生成 `winget_manifest` 工件。也可以手动运行 `准备 Winget Manifest` 工作流，输入已存在的稳定版 tag。

手动工作流默认只生成 manifest 工件。如果需要同时向 `microsoft/winget-pkgs` 创建 PR：

1. 在仓库 secrets 中配置 `WINGET_PKGS_TOKEN`，令牌需要能够 fork 仓库并向 `microsoft/winget-pkgs` 创建 PR。
2. 运行 `准备 Winget Manifest` 工作流时启用 `submit_pr`。

该工作流会使用 `.github/scripts/submit_winget_manifest_pr.py` 直接通过 GitHub API 更新 `CyrilPeng/winget-pkgs` fork 中的 manifest 分支并创建 PR，避免 clone 完整的 `winget-pkgs` 大仓库。

本地生成命令：

```powershell
$version = "1.13.0"
python .github\scripts\generate_winget_manifest.py `
  --version $version `
  --installer "build\windows\VeneraNext-$version-windows-installer.exe" `
  --output build\winget `
  --print-path
```

生成目录遵循 winget-pkgs 结构：

```text
build/winget/manifests/c/CyrilPeng/VeneraNext/<version>/
```

## 提交到 winget-pkgs

包已经完成首次接入。后续正式版更新应为新版本目录创建 PR；已配置 `WINGET_PKGS_TOKEN` 时，可以直接用 `准备 Winget Manifest` 工作流的 `submit_pr` 选项完成。

后续已有包条目后，可以使用 WingetCreate 更新：

```powershell
$version = "1.13.0"
wingetcreate update CyrilPeng.VeneraNext `
  -u "https://github.com/CyrilPeng/Venera-Next/releases/download/v$version/VeneraNext-$version-windows-installer.exe" `
  -v $version `
  -t <GitHub PAT> `
  --submit
```

不要为 `-rc` 预发布版本提交 winget manifest。winget 应只跟随正式稳定版。

PR 合并不代表客户端会立即看到新版本；还需要等待 winget 发布流水线完成。维护者应在 PR 出现 `Publish-Pipeline-Succeeded` 后，再通过 `winget search --id CyrilPeng.VeneraNext --exact` 核对公共源版本。

## 启动验证与诊断

Windows 安装器在静默安装或升级时不会自动启动应用，交互安装仍可勾选安装后运行。重复启动时，新的进程会恢复已有窗口并以 `0` 退出，不再将单实例交接误报为启动失败；真正的窗口或 Flutter 初始化失败仍返回非零退出码。

原生启动日志在 Dart 初始化之前开始记录，位置为：

```text
%LOCALAPPDATA%\com.github.cyrilpeng\VeneraNext\logs\windows-startup.log
```

日志记录 UTC 时间、进程 ID、启动阶段和适用的 Windows 错误码，不记录漫画内容、账号或命令行参数。单个日志上限为 128 KiB，轮转后最多保留一份 `windows-startup.previous.log`。日志目录不可写或文件被占用时，不会阻止应用启动。加载程序在进入应用入口前因缺少 DLL 等原因失败时，可能还来不及生成该日志，需要结合 Windows 错误提示检查。

`Validation-Executable-Error` 表示安装后的运行检查需要进一步核实，不等同于安装失败。应先检查 Winget 验证日志中的安装结果、退出码和启动日志，不要将真实失败码加入 `InstallerSuccessCodes` 来绕过验证。

PR 的 Windows CI 会运行原生回归测试，并检查首次渲染、持续运行超过 10 秒、重复启动与最小化恢复、缺少 Flutter 资源时的失败诊断。发布构建还会在临时目录静默安装，确认没有自动启动，并执行相同的运行检查。日志以短期 Actions 工件保留。

不加载 Dart 或日常漫画数据的原生回归测试可在本地运行：

```powershell
flutter build windows --debug
cmake -S windows/tests -B build/windows/startup_tests -A x64
cmake --build build/windows/startup_tests --config Debug
ctest --test-dir build/windows/startup_tests -C Debug --output-on-failure
```

`.github/scripts/test_windows_startup.ps1` 会真实安装或运行应用，只允许在一次性的 GitHub Actions Windows 运行器中执行，并在检测到已有安装、进程或应用数据时拒绝继续。不要在日常使用的账户中绕过这个限制。排查旧版本时，不覆盖已发布安装包；修复应随新的补丁版本发布。

## 注意事项

- `windows/build.iss` 中的 `AppId` 不要随意改动，它会影响 winget 对已安装应用的识别。
- 安装器文件名必须保持 `VeneraNext-<version>-windows-installer.exe`，manifest 脚本会校验这个命名。
- 如果以后增加 Windows ARM64 正式发布，需要给 winget installer manifest 增加 `arm64` installer 节点。
- 代码签名不是当前脚本的前置条件，但正式进入 winget 后应优先补上，以减少 SmartScreen 和安装信任问题。
