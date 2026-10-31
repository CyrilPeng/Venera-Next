# 阅读器短时诊断（#125）

## 交付状态与范围

本功能的首次交付版本为 **v1.18.2-rc.6（1.18.2-rc.6+242）**；原 rc.5 标签构建失败未发布，**v1.18.2-rc.4 及更早安装包没有此入口**。
它用于在原设备区分图片出现慢与界面掉帧，不代表已定位或修复 #125 的全部症状。
保留已有缓存键修复，不改变图片画质、缓存上限、解码并发、滚动延迟加载或退出收尾策略。
不将 Windows 合成图片探针、widget 回归或 APK 编译当作 Android FPS／功耗验收。

## 用户采集步骤

1. 从 [v1.18.2-rc.6 Release](https://github.com/CyrilPeng/Venera-Next/releases/tag/v1.18.2-rc.6) 手动安装对应测试包，升级前另存应用数据备份；失败的 rc.5 标签不是已发布安装包，无需为采集重复安装没有此入口的 rc.4。
2. 使用已经下载的少量图片，从原本的本地入口离线阅读，保留原图片和现有设置，不清缓存或清库。
3. 点开阅读器菜单中的“阅读诊断”，阅读说明后手动选择“开始新的 45 秒采集”。关闭说明窗口并等待短暂过渡后才开始采样；仅打开窗口不会采集。
4. 在同一阅读模式先浏览几页，再快速往返刚看过的页面。采集最长 45 秒；也可再次点击“阅读诊断”提前停止并查看。切换阅读设置、应用退后台、会话中断或退出会停止采集，不会自动恢复。
5. 在阅读器关闭前预览报告，确认后主动点“复制报告”并粘贴到 issue。报告只在当前阅读器内存中保留，可主动清除；不会自动写盘、上传或附带完整应用日志。
6. 若要比较分页、连续、瀑布流，分开采集，保持原来的缩放、刷新率、预加载和图片处理设置，不在同一轮中同时改变多个变量。

荣耀 winRT、Android 16、JPG／PNG、200 KB 至 2 MB、离线本地入口和快速回看的已有信息不需重复索取。
只需补充报告与“图片出现慢／整个界面短暂停住、首次浏览／快速回看”的对应关系；如安装来源或版本仍不明确，顺带抄录完整版本及构建号。
不用公开私人漫画、WebDAV 地址、账号、完整备份或私人日志附件。

## 数据与边界

- 默认关闭，开启不持久化；不提供自动上传、后台连续监控或跨阅读器采集。
- 版本与构建号从当前应用配置读取，保留 debug／profile／release 标记、平台、阅读模式、显示刷新率和自定义图片处理开关；不读取机型标识符或脚本正文。
- 原始图片身份只作为进程内整数键映射到本轮从 1 开始的匿名编号，报告不包含原缓存键或哈希。停止后立即丢弃映射。
- 单轮保留最多 480 个图片事件、6000 个帧样本、256 个图片身份；报告明确标出被覆盖的事件／帧及忽略的图片查找。缓冲满时保留较新的样本，不无限增长。
- 复制报告最多 60,000 个字符，预留 issue 评论的说明空间；过长时只省略较早的事件明细并记录 `omittedEventsForCopy`，不修改内存中的样本或统计，`retainedEventCount` 与各阶段摘要仍按保留的完整样本计算。预览与复制使用同一份报告，不静默裁掉 JSON 正文。
- 帧统计来自采样窗口内 Flutter `FrameTiming` 回调，分别统计 UI 和 raster，不将二者简单相加当成帧阻塞；按显示刷新率给出预算、保留样本的中位数／P95／最大值和最多 40 个慢帧。回调接收时间不是原始引擎时间戳，窗口边界及过渡帧可能影响样本，不能换算为整段实测 FPS。
- 图片阶段分别为本地文件读取（`localRead`）／来源读取（`sourceRead`）、自定义图片处理等待（`processingWait`）、codec 初始化等待、首个原生 `getNextFrame` 等待，以及可见显示代理收到首帧前的等待。来源读取包含编码字节缓存、共享请求和来源回调，不是纯网络时间；自定义处理开关与阶段不覆盖来源自己的响应处理或去混淆，不能由开关关闭推导出完全没有图片处理。时间都是经过的异步等待，可能与 UI、raster 或其他请求重叠，**不等于 CPU 耗时或 UI 线程被阻塞**。
- 显示代理在委托底层缓存键前采样缓存状态，不修改键、缓存所有权、共享加载或 ScrollAware 策略。显示等待从代理实际开始加载计时，不包括所有滚动延迟加载前的时间。
- 已解码缓存、共享加载、窗口前已开始的读取／解码可能没有完整阶段记录；阶段缺失不代表该阶段耗时为零。停止时注明仍未结束的阶段数量，跨停止、清除或新采集返回的旧结果不会污染报告。
- 首帧／显示阶段的图片宽高是解码后的尺寸，可能受已有 resize 策略影响，不一定是原文件尺寸。宽高、编码字节数与全局 ImageCache 的计数／字节数仅为辅助数值；全局缓存包含其他界面图片，不是阅读器独占内存、进程 RSS 或内存峰值。
- 成功／失败只记录布尔值，诊断不收集错误正文。即使平台复制失败，界面也只显示通用提示，不把系统错误或路径写入报告。

## rc.6 报告后的单变量对照（2026-10-31，已完成）

#125 的连续上下、分页、瀑布流三份报告均来自 Android release `1.18.2-rc.6+242`，只有本地读取样本，且均开启自定义图片处理。
头部摘要完整，事件明细被截断不妨碍这一步定位，不要求报告者重贴全文。

| 模式 | 处理等待 P95 | 首帧解码等待 P95 | UI／raster 超预算帧数 |
| --- | ---: | ---: | ---: |
| 连续上下 | 1060.527 ms | 232.775 ms | 0 |
| 分页 | 95.243 ms | 58.748 ms | 25 |
| 瀑布流 | 774.792 ms | 349.303 ms | 2 |

来源：[连续上下](https://github.com/CyrilPeng/Venera-Next/issues/125#issuecomment-6536113851)、[分页](https://github.com/CyrilPeng/Venera-Next/issues/125#issuecomment-6536117211)、[瀑布流](https://github.com/CyrilPeng/Venera-Next/issues/125#issuecomment-6536121756)。
这是不同采集窗口，不能横向排名性能；异步等待与帧数据要结合解读，不能把处理等待当作 UI 阻塞，也不能由超预算帧少否认用户感受到的卡顿。
分页和瀑布流采集结束时的全局解码缓存已接近 500 MiB，但这既不直接证明泄漏，也不是继续扩大缓存的理由。

[当时追加的关闭处理对照](https://github.com/CyrilPeng/Venera-Next/issues/125#issuecomment-6537714278)如下，仅保留为历史步骤，不要求报告者重复执行：

1. 退出阅读器，临时关闭“设置 → 阅读器 → 自定义图片处理 → 启用”，保留脚本正文，不删除、重置或修改；其他设置不变。
2. 用同一本地入口、同一部已下载漫画的少量尚未浏览页面，测最明显的连续上下模式；不清缓存、不重新下载，避免刚看过的解码缓存掩盖区别。
3. 手动开始诊断，先浏览再回看；若图片不能正常显示，立即恢复开关并停止对照。结束后可恢复原开关。
4. 退出阅读器前停止、预览并复制，只贴 `imageEvents` 之前的摘要文字，并对应说明是否改善、图片出现慢还是整个界面停住。不要求完整 JSON、私人内容或全量日志。

本地图片也会经过这个开关；即使使用内置默认脚本，也有 JS 调用、字节桥接和 Promise 处理。因此不先归咎于报告者脚本复杂度，不由开关开启就判定根因，issue 保持开放。

## 默认处理链路的宿主探针

`tool/reader_processing_probe.dart` 只使用生成的 1500×2400 PNG／JPEG，不读取私人文件或修改应用持久化设置。
默认比较以下三组，并分别运行逐张与每批 8 张的合成负载：

- `disabled`：不调用处理函数，直接解码编码字节；此处的处理计时仅是探针分支开销，生产诊断关闭处理时没有该阶段样本。
- `synchronousIdentity`：经生产 `processReaderImageBytes` 执行 `function processImage(image) { return image; }`，保留字节往返桥接，作为定位参照，不改用户脚本。
- `defaultScript`：经相同生产函数执行 `application_preferences.dart` 中原样的 `defaultCustomImageProcessing`，保留默认 Promise 协议。

每组先预热一轮、再记录九轮，按轮轮换顺序。测量区间外校验每个输出字节、输入未被修改、实际首帧尺寸和操作持有引用已释放；首帧图片及 codec 及时释放。
输出包括处理、codec 初始化、首帧解码、编码内存到首帧及整批完成的经过时间，提供逐张原始样本与 nearest-rank P50／P95；没有机器相关的性能通过阈值。
额外单独计时当前 QuickJS `JSRef.dupRecursive`／`freeRecursive` 对相同字节的成对扫描，用于检查 Promise 引用管理开销，不把这组耗时再加到处理等待上。

Windows 示例（从仓库根目录执行，先准备同一锁定版本的 `flutter_windows.dll`、`flutter_qjs_plugin.dll`）：

```powershell
$env:PUB_HOSTED_URL = 'https://pub.dev'
flutter pub get --offline --enforce-lockfile
$revision = git rev-parse HEAD
flutter test --no-pub --reporter expanded tool/reader_processing_probe.dart `
  "--dart-define=READER_PROCESSING_REVISION=$revision"
```

Windows 默认从 `build/windows/x64/runner/Release` 加载 DLL，也可通过 `READER_PROCESSING_NATIVE_DIR` 指定已有匹配构建目录；Linux／macOS 需让对应 QuickJS 共享库可加载。
缺少原生库会直接失败，不把跳过当成有效测量。输出默认写入 `build/reader-processing-probe/report.json`；`READER_PROCESSING_OUTPUT` 可指定另一份报告路径，便于保留多轮结果。
可通过 `READER_PROCESSING_WIDTH`／`HEIGHT`／`RUNS`／`BURST` 控制合成负载，首次运行可用 150×240、1 轮、2 张做冒烟；这些参数不改变生产阅读器并发或设置。

原生回归另覆盖 256 KiB／2 MiB 带偏移的字节视图、8 个不同输入的同时处理，以及本地图片关闭处理时不执行脚本、开启时执行和默认脚本原样返回。

### 隔离候选补丁与 A/B/A 结果（2026-10-31）

基线为应用 `2e9ea2b`、锁定 QuickJS `8feae95df7fb00455df129ad7a0dfec1d0e8d8e4`，宿主为 Windows、Flutter 3.41.6／Dart 3.11.4 的 `flutter test`。
合成 PNG 为 120,499 字节，JPEG 为 2,424,487 字节；它们不是报告者的原图，也不是原设备 release 性能样本。

源码与独立引用扫描计时指向 QuickJS 的 `JSRef._callRecursive`：`Uint8List` 被当作普通 `List`，先 `List.from` 再逐个元素扫描。
Promise 回传还会在 `wrapper.dart` 的 `dupRecursive` 以及 `object.dart` 的参数释放路径各扫描一次；字节只含数值，不可能持有 `JSRef`。

对[锁定依赖的引用扫描实现](https://github.com/CyrilPeng/flutter_qjs/blob/8feae95df7fb00455df129ad7a0dfec1d0e8d8e4/lib/src/ffi.dart)做最小隔离实验：仅增加 `dart:typed_data` 导入，并将空值提前返回扩为 `obj == null || obj is TypedData`。
隔离实验差异保存在 `tool/reader_processing_typed_data.patch`，供重现实验使用，不会自动应用。
实验不改原生代码、默认脚本、应用运行时或共享 Pub 缓存；临时使用独立依赖副本，核对除 QuickJS 外所有锁文件记录不变，测完恢复原依赖并再次测量。

下表为默认脚本每张图片的 `processingWait` 中位数；单张组每轮一张，共 9 个样本，8 张组共 72 个样本。单位为 ms：

| 合成输入／每批张数 | 原依赖 A1 | 跳过数值缓冲扫描 B | 恢复原依赖 A2 |
| --- | ---: | ---: | ---: |
| PNG／1 | 11.585 | 1.406 | 11.501 |
| PNG／8 | 98.193 | 3.482 | 100.782 |
| JPEG／1 | 213.876 | 2.799 | 213.089 |
| JPEG／8 | 1715.608 | 15.601 | 1688.239 |

A1 中同步原样返回的 JPEG 单张处理等待中位数为 2.219 ms，而独立的成对引用扫描为 212.655 ms。
候选中成对扫描已低于微秒输出分辨率，不表示绝对零开销；恢复原依赖后大额等待重新出现。
这些交叉结果确认了**宿主默认异步字节链路的一项可消除开销**，优先支持继续验证引用扫描修复，而非扩大缓存、增加并发、改写用户脚本或先换解码策略。
它们尚不能证明报告者使用默认脚本，或证明 #125 的所有症状均由此造成；平台构建和原 Android 设备复测仍需单独完成。

探针的 `READER_PROCESSING_CONFIGURATION` 可标记隔离实验；报告同时记录 QuickJS 来源类型，避免把本地副本冒充锁定 Git 版本。
候选回归还覆盖 `Uint8List` 子视图、带符号／浮点数缓冲、`ByteData`，以及包含数值缓冲、别名回调和环的普通引用图；不以跳过扫描为由跳过真正的回调引用释放。
原始报告位于本轮 `build/issue-125-processing-probe-20261031/`，下列 SHA-256 用于核对，构建目录清理前应另存需要的原始证据：

| 报告 | SHA-256 |
| --- | --- |
| `baseline-1.json` | `caaf3bdd9b3195b971086f289962b78aff0cd5e8fc10642918b04b4107506c64` |
| `candidate-guard.json` | `0a7b27aa823c8392f2520724c44276fd4f9c635ce40b0717b77a2cecda0fb8aa` |
| `baseline-2-restored.json` | `6e1ca5dc511c6c1c34fba73bf9c604771690a25ee984a107a447d65516fabacf` |

**边界**：这是 `flutter test` 宿主中的编码内存→处理→解码对照，不包含文件／网络 I/O、阅读器布局、滚动调度或 Flutter ImageCache，不是原设备完整阅读回放。
同批异步等待会相互重叠且受事件调度影响，不能当作各阶段独占 CPU 时间或简单相加；桌面数值不能外推荣耀／Android 16 的 FPS、功耗或修复幅度。
本轮仅将已验证的引用扫描修改接入固定 QuickJS 提交，不修改默认脚本、缓存、并发或画质，再结合原设备开关对照判断剩余问题。

### 修复接入状态

同一 `TypedData` 提前返回已提交到现有 fork 的 `venera-next-pinned` 分支：[295f774](https://github.com/CyrilPeng/flutter_qjs/commit/295f77421eedff356a02e92987181b525970c780)。正式提交另带解释性注释、2 项依赖自身回归和 changelog，不改变实验所验证的逻辑，也不修改原生代码。
应用声明、锁文件和 Git 依赖清单固定到完整提交；[依赖治理说明](dependencies.zh.md)记录全部差异、风险与回滚方式。没有遗留 path override，也没有修改原共享缓存中的旧版本。
从 Git 重新解析正式 pin 后，锁文件除 QuickJS 的 `ref`／`resolved-ref` 外与原基线一致，离线强制锁文件解析通过。同一宿主探针重新通过，默认脚本 PNG 单张／8 张组的处理等待 P50 为 1.257／4.035 ms，JPEG 为 2.826／15.839 ms，与隔离候选结果一致。
这次原始记录为同一构建目录下的 `fixed-pinned.json`，SHA-256 为 `6a7a6e753a8ceb60348778bef4a52c6a179e9e547d92e813f7afe8415751e6b8`；报告明确标注工作副本及 Git 来源，不将未发布的相同应用版本号误认为 rc.6 发布包。
正式 pin 下，Windows 的 foundation／reader 回归 1,696 项通过、2 项平台专用检查跳过；另有 JS UI 引用生命周期、原生图源／调试器、阅读设置、changelog 与依赖清单回归 117 项通过。全仓静态分析、独立代码审查工具自检、依赖清单、版本元数据及变更格式检查通过；这些结果不替代平台构建或设备验收。
**已发布的 `v1.18.2-rc.6+242` 不包含此修复。** 本轮代码接入不是新版本发布，也不是原设备验收；只有后续包含该 pin 的构建才用于验证修复，#125 继续保持开放。

## 关闭处理后的首次加载与回看（2026-10-31）

报告者已[确认保持默认配置、本地漫画关闭自定义处理后恢复正常](https://github.com/CyrilPeng/Venera-Next/issues/125#issuecomment-6538443950)，随后说明[未下载图库首次滑动切图仍短停，点击分页基本正常](https://github.com/CyrilPeng/Venera-Next/issues/125#issuecomment-6538568325)。
最新[回看对照](https://github.com/CyrilPeng/Venera-Next/issues/125#issuecomment-6538658134)确认：处理保持关闭，在瀑布流浏览 3～5 页后立即反向滑回这些页面，不再短停。两项单变量对照都已完成，不再要求重做或提交私人漫画／完整日志。

关闭处理的[瀑布流摘要](https://github.com/CyrilPeng/Venera-Next/issues/125#issuecomment-6538578498)中，`processingWait` 没有样本，来源读取、首帧解码、显示等待 P95 分别为 111.085、109.957、133.820 ms；383 个已采样帧中有 2 个超预算。来源读取包含编码缓存／来源回调，各阶段可以重叠，不能相加或只按网络解释；少量超预算帧也不能否认图片交接的停顿。

因此保留两条独立结论：QuickJS 引用扫描是已复现并修复的额外开销；关闭处理后仅首次浏览的停顿仍待定位，不能归入该修复已覆盖的范围。开发侧下一步应对照首次图片与已解码图片的可见请求、滚动延后、取图、解码和初次布局，而不是先增加缓存／并发或降低画质。
连续／瀑布流目前的显式预加载主要准备编码字节，和分页相邻页的解码预缓存不同；`ComicImage` 仍受 `ScrollAwareImageProvider` 调度。现有宿主回归确认缓存命中／正在加载的图片可直接复用、未缓存图片可能等待滚动减速，但这不是原设备剩余根因的证明。
尤其 `displayWait` 从显示代理真正解析底层 provider 时开始，不涵盖所有可见请求之前的滚动延后；后续测量应补齐这一时间边界，保持手动开启、有界缓冲、退出取消及不记录私人内容的原则。本次只同步证据与后续测量范围，不更改滚动、预加载或诊断运行时策略。

## 开发验证

```text
flutter test test/foundation/reader_diagnostics_test.dart test/features/reader/diagnostics_dialog_test.dart
flutter test test/foundation/reader_image_processing_native_test.dart test/foundation/reader_image_provider_test.dart
flutter test test/foundation/js_reference_bytes_test.dart
flutter test test/features/reader test/foundation
flutter analyze --fatal-infos --fatal-warnings
```

回归覆盖默认关闭、45 秒自动停止、延迟计时器边界、缓冲上限、回调卸载、跨会话旧结果、工作暂停及真实本地 PNG 的读取／codec／首帧／显示阶段，确认缓存键不因诊断改变。
真实阅读器集成同时核对确认前不采集、普通加载／进度更新不误取消、后台或模式切换后旧确认不能开启采样，以及采集停止后不自动恢复。满缓冲报告验证复制长度限制和明确的省略计数。
界面需覆盖 375px 小屏、横屏、大字体、明暗主题及减少动画，报告预览惰性构建，采集期间不按帧刷新界面。
诊断自身仍有少量观测开销。最终性能判断应在原 Android 设备的 profile／release 包中，结合图片显示表现、UI／raster 样本和各阶段信息交叉定位，再决定优化方案；当前不承诺缓存、预解码或布局路径就是第二根因。
