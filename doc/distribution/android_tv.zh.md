# Android TV 安装与分发

English version: [android_tv.en.md](android_tv.en.md)

Android TV 已完成维护者确认的小范围测试，功能从独立 `android-tv` 测试分支进入 `main`。后续 Android 构建同时生成手机版和 TV 版；新版本发布时两者进入同一个 GitHub Release。本次集成本身不提高版本号、不创建标签，也不向已发布的 `v1.18.1` 或 `v1.18.2-rc.6` 回填 TV 安装包。

## 安装与更新

在 [Releases](https://github.com/CyrilPeng/venera-next/releases) 中选择含 TV 资产的版本，文件名为：

- 通用版：`VeneraNext-<版本>-android-tv.apk`
- ARM64：`VeneraNext-<版本>-android-tv-arm64-v8a.apk`
- ARM32：`VeneraNext-<版本>-android-tv-armeabi-v7a.apk`
- x86_64：`VeneraNext-<版本>-android-tv-x86_64.apk`

不知道系统 ABI 时选择通用版；64 位硬件不一定运行支持 ARM64 应用的系统。将 APK 传到电视／盒子后侧载，按系统提示授予可信安装来源所需的安装权限。TV 不内置或推荐漫画源，与其他平台一样由用户合法配置内容。

| 项目 | 手机版 | TV 版 |
|---|---|---|
| Flavor | `mobile` | `tv` |
| 包名 | `com.github.cyrilpeng.veneranext` | `com.github.cyrilpeng.veneranext.tv` |
| 启动名称 | VeneraNext | VeneraNext TV，带电视入口和横幅 |
| 方向 | 沿用应用设置 | 固定横屏 |
| 数据 | 原沙盒 | 独立沙盒，不自动迁移或删除手机版数据 |
| 应用更新 | 保持原稳定／预发布渠道 | 相同版本渠道，只提示包含已上传 TV 通用包的发布 |

更新检查只提示并打开对应 Release 页面，不自动下载安装 APK；TV 提示明确要求选择 `android-tv` 包。漫画源更新保持原有行为。早期 TV Alpha 禁用了应用更新检查，需要先手动安装第一个主线 TV 包，之后即可使用新的检查入口。

两种包可共存。升级前导出并另存应用数据备份；官方 TV Alpha 可用相同签名的主线 TV 包覆盖升级，无需卸载或清空数据。不要让两套应用同时写入同一个漫画／WebDAV 备份目录。降级可能被 Android 版本码规则阻止，不应通过卸载来绕过而丢失 TV 数据。

## 遥控器与阅读策略

- 主界面方向键移动焦点，确定／手柄 A 激活，返回／手柄 B 返回；支持菜单键的遥控器可打开部分控件上下文菜单。
- 阅读画面方向键翻页／滚动，确定打开菜单；菜单内方向键只移动控件焦点，返回先收菜单，再保存进度并退出。
- 失焦、打开菜单或切后台会取消持续按键，恢复后不继续翻页。TV 隐藏阅读器旋转按钮。
- TV 默认开启「设置 → 阅读器 → TV 低内存模式」：单页画廊、1 页预加载、64 MiB 解码图片缓存、最多 `1920 × 1080` 像素与 8192 像素最长边的阅读图解码。
- 关闭低内存模式恢复原全局／本机／漫画阅读配置，可使用连续和瀑布流。该开关只在本机保存，不导出、不上传 WebDAV、不被导入覆盖；原图片文件和尺寸元数据不变。

这是对现有界面的遥控器适配，不是全界面的十英尺重设计。源的网页登录、验证码、系统文件选择器和第三方页面仍可能需要输入法或配套输入设备。长条图和放大细节在低内存模式下可能变糊；解码临时缓冲、动画、原生插件等不全部计入图片缓存，64 MiB 不是总内存上限或不会 OOM 的保证。小范围测试不代表所有型号与所有内容均已验证。

## 版本码与签名连续性

手机版保留 `基础构建号 × 10 + ABI 标识`。TV 使用 `(200000 + 基础构建号) × 10 + ABI 标识`，ABI 标识为通用版 `0`、ARM32 `1`、ARM64 `2`、x86_64 `3`。Gradle 自动添加偏移，本地和 CI 使用同一规则，**不要再传入 Alpha 的大构建号**。

最后一轮已交付 Alpha 构建 `alpha.19.2`（提交 `a4ba52463380`）的最高版本码为 `1000193`。主线基础构建号 `242` 对应 TV 版本码 `2002420`–`2002423`，均高于旧测试包。今后提升 `release.json` 的构建号即可使各 ABI 递增；重跑同一版本构建不增加版本码，同版本切换到较低 ABI 标识的包可能被拒绝，建议沿用原 ABI。

`pubspec.yaml` 与漫画源读取的基础版本不变；About 另显示 TV 构建标识和提交号。两种 APK 使用原发布签名，校验脚本固定检查既有公开证书 SHA-256：

```text
3d990535d15d2ecb8f65f599db7725e1d83e10a5e801ddcdae262cc78983dc10
```

签名密钥不随代码分发。若将来轮换证书，必须另行设计升级兼容流程，不可只放宽这个校验。

## 构建与发布门禁

在 GitHub Actions 手动运行「构建」，选择 `main` 并开启 Android，即构建两种 APK；不再选择 `android_flavor`。只构建 Android 的示例：

```powershell
gh workflow run build.yml --ref main `
  -f build_android=true `
  -f build_windows=false -f build_macos=false -f build_ios=false `
  -f build_linux_x64=false -f build_linux_arm64=false
```

手动 Android 构建先运行质量检查。完整构建／标签发布在上层复用相同质量检查，Android 矩阵包含 `mobile` 和 `tv`；开启其他平台时仍照常构建。PR 平台冒烟构建验证两种 Android Debug APK 和 Windows Debug，质量流程在普通全量测试外运行真实 TV flavor 的导航、输入、低内存及更新回归。

每种 flavor 都检查全部 4 个签名 release APK：包名、基础版本、版本码、原命名空间下的 MainActivity、电视入口／横幅／横屏／非触屏要求、原生 ABI、内嵌版本和签名。该 flavor 任一 APK 失败就不上传其安装包。

Actions 产物为 `apk-<ABI>`、`tv-apk-<ABI>`、`android-mobile-manifest` 和 `android-tv-manifest`，保留 7 天，需要登录 GitHub 下载。两个 manifest 记录完整提交、包名、版本码、签名指纹、大小和文件 SHA-256。标签发布同时下载两套 APK 和清单，核对 **8 个 APK 完整集合、当前发布来源、签名及摘要** 后才创建 Release；两个清单也作为 Release 资产保留。手动构建不会创建 Release。

本地构建沿用[构建指南](../development/build.zh.md)的 Flutter 版本与签名配置：

```powershell
flutter pub get --enforce-lockfile
flutter build apk --release --flavor mobile
flutter build apk --release --flavor tv `
  --dart-define=TV_BUILD=local --dart-define=TV_REVISION=local
```

产物分别位于 `build/app/outputs/apk/mobile/release/` 和 `build/app/outputs/apk/tv/release/`。Android 构建必须显式指定 flavor；不使用全局 `default-flavor`，避免破坏 iOS/macOS 的原有 Xcode scheme。本地示例不代替 CI 完整签名与来源验证。

## 后续设备回归

升级和后续修改重点复查：与手机版共存；720p／1080p／4K、大字号、明暗主题及减少动画；搜索、列表、章节、设置和弹窗的焦点返回；菜单内不翻页；后台恢复不连发；退出保存失败保护；导入／同步不传递低内存开关；长条图、动画、大图和连续阅读的实际内存。反馈附版本／提交、设备与 Android 版本、系统 ABI、遥控器类型及复现步骤即可，不要求私人漫画、凭据或完整备份。

早期分支隔离规则与实验验收表保留在[历史实验记录](../experiments/android_tv.zh.md)，不再作为当前构建指引。
