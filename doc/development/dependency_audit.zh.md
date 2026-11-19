# 当前依赖来源与替换条件

[English](dependency_audit.en.md) · [治理规则](dependencies.zh.md) · [机器可读清单](git_dependencies.json)

当前依赖为 2 个 Git 来源、7 个 Git 包和 8 个本地包。准确版本、完整 commit、发布归档摘要、许可证、补丁与退出条件以 `git_dependencies.json`、`pubspec.lock` 和各包的来源清单为准。本页汇总当前决策；已完成的逐批审计、文件比对和工具输出保存在 [v1.18.4-rc.3 的历史文档](https://github.com/CyrilPeng/Venera-Next/tree/v1.18.4-rc.3/doc/development)。

## 当前例外及退出条件

| 依赖 | 保留原因 | 回归官方来源的条件 |
| --- | --- | --- |
| QuickJS | 固定 `CyrilPeng/flutter_qjs@f5a1f20d08c33b0a6b3e38eda2a7b27705420620`，保留 Map／TypedData、整数／NaN、Promise、dispatch／port 与对象所有权契约。官方未发布 0.4.0 的实际依赖解析和原生 Map 探针失败 | 官方候选同时通过 SDK 解析、Map／TypedData、Promise／取消、引用释放、安全核心及平台验收 |
| InAppWebView | 六包固定到同一官方 `0aaf7a0bfc01d61a4d1453cefb57fb6783b6e676`；稳定版 6.1.5 缺浏览器退出事件，Windows 实例所有权修复仅保留在本地子包 | 稳定版提供退出 API，Windows 修复进入上游，并协调验证全部平台包 |
| PhotoView | 本地 0.14.0 保留尺寸／缩放／重置接口、手势与 ImageInfo 所有权。官方 0.15.0 替换产生 15 项应用 API 错误，所有权缺陷也需单独处理 | 应用公开适配层和上游修复通过缩放、触控板、双页、自动阅读及退出生命周期回归 |
| SharePlus | 本地 12.0.2 保留原生共享载荷、临时文件保留与回调所有权修复 | 同步验证应用、Android primitive、Windows COM 及其他平台共享与取消 |
| Desktop WebView | 本地 0.2.4 保留 proxy API、Linux／ARM64 及进程退出契约；官方 0.4.2 要求 Flutter >=3.44，并改变应用所需配置接口 | SDK 与公开 API 适配完成，Cookie、代理、退出／重建与目标平台通过 |
| Rhttp | 本地 0.15.1 保留流取消、真实原生排空、超时与连接所有权；Rust 安全修复由锁文件及补丁记录约束 | 上游覆盖应用契约和全部安全修复，完成流与各平台原生验证 |
| WebDAV Client | 本地 1.2.2 保留自定义 HTTP adapter、认证、重定向及上传行为 | 官方 adapter 或应用适配层通过认证、301、目录、大文件上传与资源释放 |
| Venera Native | 项目自编 PNG／7z 包装层，使用明确许可的官方 LodePNG 与 7z C 解码子集，来源与项目代码分别登记 | 按独立核心升级审查；同名旧包装层不能作为等价替代 |
| Venera SAF | 项目自编持久目录／URI／随机访问／跨 isolate 句柄桥，不复制旧占位许可证包装层 | 按系统 Provider、原始 PFD 生命周期与重启授权契约维护，不以同名包替换 |

滚动列表已经使用官方 pub.dev 0.3.8，由应用适配公开滚动接口。Debian 打包由 `debian/build.py` 和系统 `dpkg-deb` 承担；旧 `flutter_to_debian`、`flutter_saf`、`flutter_7zip`、`lodepng_flutter` 仅保留在历史构建中。

## 安全与来源证据

QuickJS 核心匹配到 QuickJS-NG `d07f6b5`。适用的公开公告、补丁边界和安全回归以固定来源的 [CORE_PATCHES.json](https://github.com/CyrilPeng/flutter_qjs/blob/f5a1f20d08c33b0a6b3e38eda2a7b27705420620/CORE_PATCHES.json) 为准。保留 Dart API 的理由不能代替原生核心修复；后续候选须保留 GC、分配失败、buffer transfer、Linux 64／32 位 ASan／UBSan 和 Windows 64／32 位 ASan 的相关保障。

各本地包的 `LOCAL_PATCHES.md`、`UPSTREAM_MANIFEST.json`／`SOURCE_MANIFEST.json`、许可证和第三方声明继续随源码维护。PNG 使用官方 LodePNG 20241015；7z 使用 24.09 的 public-domain C 子集。XZ、其他 handler 和 C++ 链接提取公告须按实际编译范围匹配，不能据未收纳的实现推断安全性。桥接拒绝链接、缺失名称、越界路径与损坏输入，真实 ABI 和 sanitizer 回归继续执行。

来源检查同时核对声明、锁文件、真实 Git HEAD、包子目录与源码状态。Windows 长路径失败可能留下名称与实际 HEAD 不一致的缓存；使用启用 longpaths 的独立缓存重新检出并验证，保留原共享缓存供排查。

## 尚未采用的稳定候选

这些是已验证的兼容性边界，未来更新需重新评估候选及固定 SDK，不能把历史失败当成永久结论。

| 候选 | 已知边界 | 当前处理 |
| --- | --- | --- |
| `dynamic_color 1.9.0` | 发布的 Android Gradle Kotlin 脚本未应用 Kotlin Android plugin，导致 Android／TV 编译失败 | 固定官方 1.8.1 |
| `flutter_reorderable_grid_view 5.10.0` | 自适应网格鼠标／触摸拖动出现负 BoxConstraints | 固定通过现有拖动回归的 5.7.0 |
| `pdfrx 2.4.8` | 其 engine 要求 meta ^1.18，当前 Flutter 固定 meta 1.17 | 保留可解析版本，由根锁文件确定准确内容 |

## 更新、验证与恢复

先比较官方稳定归档、官方完整 commit 与当前定制来源，区分 SDK 等价调用、应用适配和仍需维护的补丁。格式化后的文件相同只证明源码比较，不能替代行为、平台或安全验证。

更新时同步依赖声明、锁文件、统一清单、来源／补丁摘要与 CHANGELOG，运行 `dart tool/check_git_dependencies.dart`、严格分析、受影响行为、原生 ABI／sanitizers 和目标平台构建。回滚恢复同一组输入和相关应用适配，不丢弃独立安全修复。鸿蒙独立工具链与冻结构建恢复见[鸿蒙发布指南](harmonyos_releases.zh.md)。
