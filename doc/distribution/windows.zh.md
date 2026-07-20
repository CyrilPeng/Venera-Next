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

## 注意事项

- `windows/build.iss` 中的 `AppId` 不要随意改动，它会影响 winget 对已安装应用的识别。
- 安装器文件名必须保持 `VeneraNext-<version>-windows-installer.exe`，manifest 脚本会校验这个命名。
- 如果以后增加 Windows ARM64 正式发布，需要给 winget installer manifest 增加 `arm64` installer 节点。
- 代码签名不是当前脚本的前置条件，但正式进入 winget 后应优先补上，以减少 SmartScreen 和安装信任问题。
