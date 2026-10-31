# Windows 内置网页登录代理（#128）

## 根因与范围

1.18.1 及修复前主线会在手动代理模式下调用
`WebViewFeature.isFeatureSupported(PROXY_OVERRIDE)`，随后才判断 Windows。
这个特性查询及 `ProxyController` 属于 Android API；锁定的 Windows 平台实现
没有对应工厂，因而在创建网页环境、加载漫画源之前就抛出
`createPlatformWebViewFeatureStatic is not implemented on the current platform`。
这是应用的平台分流问题，不是漫画源脚本或站点登录结果。

修复只让 Android 走原 Android 代理路径，Windows 使用
`WebViewEnvironmentSettings.additionalBrowserArguments`。不升级 WebView 插件，
不改漫画源、应用 HTTP 客户端、系统代理、用户脚本或版本号。

## 代理与登录目录

| 设置 | Windows 内置网页行为 |
| --- | --- |
| 系统代理 | 不添加代理参数，继承系统策略 |
| 直连 | 显式设置 `--no-proxy-server` |
| `host:port` | 规范化为 `--proxy-server=http://host:port` |
| `http` / `https` / `socks4` / `socks5` 地址 | 使用指定协议和一个端点；端口必须为 1–65535 |
| 含用户名或密码 | 明确拒绝；改用无需认证的本地代理或配置系统代理 |
| 路径、查询、片段、列表、空白或额外命令行参数 | 校验失败；不启动网页，也不回退到其他代理模式 |

代理参数只由验证后的协议、ASCII 主机名／IPv4／方括号 IPv6 和整数端口生成。
错误文案不回显输入；不把代理凭据放进浏览器进程参数或交给站点认证回调。
WebView2 仍有其原生隐式本机地址绕过和管理员策略；没有增加自定义绕过规则。

始终使用原来的 `${App.dataPath}\webview` 目录。相同配置的同时打开网页共用
环境，不同配置不能并用同一个浏览器进程。关闭所有旧网页后，必须等待
`onBrowserProcessExited`，而不是仅以路由销毁或环境创建成功判断旧选项已经解除。
最多等待 10 秒；仍被占用时显示关闭网页／重启应用的提示，不删除登录目录，
不强杀进程，不静默以旧配置打开新网页。

环境引用绑定到平台控制器，而非全局“最后一次创建”的环境；插件为同一平台
控制器生成的不同 Dart 包装仍使用同一个环境。已开始的 Cookie 读取持有临时
引用，关闭后的新读取被拒绝。异步创建完成时页面已退出则释放其引用，不发布
控制器；晚到的标题、加载和导航回调不再驱动已关闭页面。

## 自动回归

```powershell
$env:PATH = (Join-Path $PWD 'build/windows/x64/runner/Debug') + ';' + $env:PATH
flutter test --no-pub --reporter expanded `
  test/routing/windows_webview_environment_test.dart `
  test/routing/windows_webview_proxy_test.dart `
  test/routing/webview_menu_test.dart `
  test/features/comic_source/source_web_login_test.dart
```

Windows PR 构建后运行这些测试；环境池和输入校验同时进入跨平台全量测试。
Windows 组件测试继承锁定插件的真实 Windows 工厂，只替换环境／网页原生创建
与 Cookie 通道；Android 特性工厂仍是实际会抛错的实现，断言 Windows 不调用它。
覆盖系统／直连／原始和带协议的手动代理、存活网页的配置冲突、浏览器退出等待、
取消初始化、原控制器 Cookie 归属、失败后重试，以及小窗口／放大文字／深色模式。
它们不伪装成站点登录或真实代理服务器的端到端验收。

## 隔离原生验证

2026-10-31 在 Windows 宿主上，使用与锁定插件一致的 WebView2 SDK
`1.0.2849.39`、本机 WebView2 Runtime `154.0.4258.48`、隐藏窗口和独立合成
profile 完成以下原生 API 序列：

1. 两个仅监听 `127.0.0.1` 的 HTTP 测试服务分别返回 `ORIGIN` 和 `PROXY`。
   测试域名 `webview-proxy.test` 只在探针内部映射到回环；没有修改 hosts 或系统代理。
2. 用 `--no-proxy-server` 创建环境及控制器，请求返回 `ORIGIN`，写入合成持久 Cookie。
3. 旧控制器仍打开时，用同 profile 和 `--proxy-server=http://127.0.0.1:<测试端口>`
   创建新环境返回成功，但创建其控制器返回 `0x8007139f`（选项冲突）。
4. 关闭旧控制器并等待浏览器退出，保留环境引用也能收到退出事件。再以手动代理
   创建控制器，请求返回 `PROXY`，合成 Cookie 仍在。
5. 关闭并等待退出，再切回直连，请求重新返回 `ORIGIN`，合成 Cookie 仍在。

原生探针未读取真实应用 profile、漫画、站点或账号；没有清除任何登录数据。
该结果验证 HTTP 手动代理路由、直连重置、原生选项冲突和持久 Cookie 保留，
不宣称已验证所有代理协议、企业策略、Session Cookie 重启语义或报告者的站点账号。
发布包含修复的后续构建后，仍需原设备复测 #128；已发布旧版本不会因此自动修复。
