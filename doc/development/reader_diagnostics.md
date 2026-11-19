# 阅读器短时诊断与性能排查

## 交付状态与范围

阅读诊断自 v1.18.2-rc.6 提供；v1.18.4-rc.3 的报告使用 schema 2，追加真实引擎帧时间。它用于在原设备区分图片出现慢、处理等待、解码和界面掉帧。历史 #125 的开关／首次和回看对照已经完成，新的症状按各自场景采集。

## 用户采集步骤

1. 使用包含所需诊断字段的已发布版本，记录平台、完整版本与构建号，升级前另存应用数据备份。
2. 从原入口离线阅读少量已经下载的图片，保留原图片和设置；只在需要定位新场景时采集。
3. 打开阅读器菜单中的“阅读诊断”，手动选择“开始新的 45 秒采集”。说明窗口关闭并完成短暂过渡后才开始采样，仅打开窗口不会采集。
4. 同一阅读模式先浏览几页，再快速往返刚看过的页面。采集最多 45 秒，也可主动停止；后台、设置／模式变化、会话中断和退出会停止采集，不会自动恢复。
5. 在阅读器关闭前预览并主动复制报告。报告仅在当前阅读器内存中保留，可清除，不自动写盘或上传。
6. 分页、连续、瀑布流分开采集，保持缩放、刷新率、预加载与图片处理设置。对应说明图片出现慢还是整个界面停住、首次浏览还是回看。

已经提供的机型、图片格式、离线入口和开关对照无需重复索取；采集不需要私人漫画、WebDAV 地址、账号、完整备份或私人日志。

## 数据与边界

- 默认关闭，开启不持久化。版本、构建号、运行模式、平台、阅读模式、刷新率和处理开关来自当前配置，不读取机型标识符或脚本正文。
- 每轮最多 480 个图片事件、6000 个帧样本、256 个图片身份，保留较新数据并记录截断。图片身份仅为本轮匿名编号，停止后丢弃映射。
- 复制最多 60,000 字符，省略较早事件时记录 `omittedEventsForCopy`，不修改内存统计；`retainedEventCount` 和阶段摘要按完整保留样本计算。
- `localRead`／`sourceRead`、`processingWait`、codec 初始化、原生首帧与显示等待都是异步经过时间，可能彼此或与 UI／raster 重叠，不是独占 CPU 时间。来源读取包含编码缓存、共享请求及来源回调，不是纯网络时间。
- 关闭自定义处理不意味着来源脚本没有自己的响应处理。默认脚本也包含 JS 字节桥接和 Promise，不能仅根据开关状态归因。
- `displayWait` 从显示代理订阅底层图片流计时，不含此前 ScrollAware 等待减速、之后排版／绘制及屏幕呈现；较短样本不能排除首次入场等待。
- 编码字节预下载不等于 Flutter 已有 pending／decoded 图片；显示代理委托底层缓存键，保留缓存所有权、共享加载和 ScrollAware 策略。
- UI／raster 分别统计，不简单相加。`receivedAtUs` 是批量回调接收时间；Release 可能约一秒集中回调，不能据此推断一秒周期任务。schema 2 的 `vsyncStartUs`／`buildStartUs` 是相对采集开始的真实引擎时间，负值对应窗口前的帧。
- 窗口前已开始的读取、缓存命中和共享加载可能缺少阶段，缺失不代表零耗时。停止时保留未结束阶段数量；旧结果不能污染下一轮。
- 解码尺寸可能经过 resize；全局 ImageCache 字节与计数不是阅读器独占内存或进程 RSS。报告只记录成功布尔值，失败正文和系统路径不会进入诊断。

## 分阶段宿主探针

各探针只使用生成的合成图片，不读取私人漫画。先准备同一源码和依赖的原生库；缺库直接失败。宿主回归、编译及绘制提交分别记录，原设备帧率、功耗和 GPU 呈现单独验证。

### 编码读取与首帧

```text
flutter test --no-pub --reporter expanded tool/reader_decode_probe.dart
```

默认生成同一组 1500×2400 彩色像素的 PNG／JPEG，分别测试文件读取和编码内存，每组预热一次再取五次。`READER_PROBE_RUNS`／`WIDTH`／`HEIGHT` 可调整样本，只写入忽略的 `build/reader-decode-probe/`。

读取走生产 `ReaderImageProvider.load`，随后单独计时 ImmutableBuffer、codec 和 `getNextFrame`，校验字节、尺寸并释放资源。它不含显示代理生命周期或 ImageCache；编码内存仍需重新解码，重复文件读取也不能当成真实冷盘读取。历史 [2026-10-28 JSONL](https://github.com/CyrilPeng/Venera-Next/blob/v1.18.4-rc.3/doc/experiments/data/reader_decode_windows_20261028.jsonl) 保留原始对照，桌面耗时不能换算 Android FPS。

### 默认图片处理链路

```powershell
$revision = git rev-parse HEAD
flutter test --no-pub --reporter expanded tool/reader_processing_probe.dart `
  "--dart-define=READER_PROCESSING_REVISION=$revision"
```

比较关闭处理、同步原样返回及生产默认 Promise 脚本，分别运行单张和每批八张；测量外校验每个输出字节、输入保持、首帧尺寸及引用释放。报告提供原始样本、P50／P95及独立成对引用扫描，不将后者重复加到处理等待。

Windows 默认从 `build/windows/x64/runner/Release` 加载同一 pin 的 DLL，`READER_PROCESSING_NATIVE_DIR` 可指定匹配目录。`WIDTH`／`HEIGHT`／`RUNS`／`BURST`／`OUTPUT` 参数使用 `READER_PROCESSING_` 前缀；150×240、一轮、两张适合冒烟，不改变生产配置。

2026-10-31 的 A/B/A 确认旧 QuickJS 把数值缓冲当普通 List 扫描，默认异步字节回传因此增加等待。当前 `f5a1f20` 已包含 `TypedData` 提前返回，实际修改及安全边界见[固定来源](https://github.com/CyrilPeng/flutter_qjs/blob/f5a1f20d08c33b0a6b3e38eda2a7b27705420620/lib/src/ffi.dart)与[依赖治理](dependencies.zh.md)。孤立实验补丁已退役，完整历史数值、基线与报告摘要保存在 [RC3 文档](https://github.com/CyrilPeng/Venera-Next/blob/v1.18.4-rc.3/doc/development/reader_diagnostics.md)。

原生回归保留数值子视图、ByteData、带符号／浮点缓冲、普通引用图、别名回调和环。跳过纯数值扫描不能跳过真正的 JSRef 释放；默认脚本、图片画质与并发仍由生产设置控制。

### 首次入场与预解码对照

```text
flutter test --no-pub --reporter expanded tool/reader_first_view_probe.dart
```

探针使用生产 ComicImage、显示代理和 ReaderImagePrecache，同一时钟记录请求、ScrollAware 延后、读取、codec、首帧及 UI 绘制提交。`READER_FIRST_VIEW_WIDTH`／`HEIGHT`／`RUNS`／`DELAY_MS`／`OUTPUT`／`REVISION` 可调整；默认五轮、1500×2400、受控延后 120 ms，冒烟可用 150×240、一轮、30 ms。

[历史宿主记录](../experiments/data/reader-first-view-host-20261103.json)确认有限预解码可以在受控场景绕过冷图延后，但工作被提前执行而未消失。一张原尺寸 RGBA 约 13.73 MiB，不能把多页编码预下载直接替换为无限解码预缓存。无头 widget 的绘制遍历不证明 GPU／屏幕完成，`testPumpWallUs` 不能替代设备帧时间，RSS 阶段采样也不是持续峰值。

## 设备复现与验收

性能对照固定同一组合法可控图片，分别比较网络库、下载后的本地入口及直接导入，并核对是否实际命中缓存。首次、回看、分页／连续／瀑布流分别记录；Android profile／release 联合观察 UI／raster、图片阶段、GC 和内存，稳定定位后再选择有界优化。

- [#178 分页拖动](https://github.com/CyrilPeng/Venera-Next/issues/178)：在缓存页往返时无新读取／解码，优先观察布局、绘制、手势动画与翻页频率。使用 schema 2 的引擎时间；半页正反向拖动和松手的最终页、图片位置及原设备 120 Hz 体感分别验收。
- [#139 白边裁剪](https://github.com/CyrilPeng/Venera-Next/issues/139)：记录启用时机、未裁页格式／尺寸、换章和重新打开表现，区分检测、显示入场和 JPEG 边缘条件。保留完整空白列、浅色／文字边缘、动图、预算限制、原图恢复和退出收尾；合成 PNG 全部成功不代替原 JPEG 验收。
- [#129 封面残留](https://github.com/CyrilPeng/Venera-Next/issues/129)：记录完整版本、本地库／收藏／历史入口、漫画切换顺序和返回时机。嵌套 Navigator 探针不能覆盖本地列表直接进入阅读器的全部时序，需联合封面转场与真实本地图片生命周期定位。
- 导入后不显示：分别检查文件准备／权限、解压与登记、数据库记录、过滤规则、当前可见列表、封面／页面及冷重启。短／长名、双扩展、连续批次、取消及直接读／临时复制／SAF 分支分别对照；关闭关键词屏蔽后恢复应归入显示过滤。[导入指南](../user/import_comic.zh.md)与[屏蔽指南](../user/keyword_blocking.zh.md)描述当前行为。

## 开发验证

```text
flutter test test/foundation/reader_diagnostics_test.dart test/features/reader/diagnostics_dialog_test.dart
flutter test test/foundation/reader_image_processing_native_test.dart test/foundation/reader_image_provider_test.dart
flutter test test/foundation/js_reference_bytes_test.dart
flutter analyze --fatal-infos --fatal-warnings
```

回归覆盖默认关闭、45 秒停止、延迟计时、缓冲／复制上限、跨会话旧结果、后台暂停、真实图片阶段、引擎帧时间、确认窗口生命周期及缓存键。界面覆盖小屏、横屏、大字、明暗与减少动画，采集期间不按帧刷新界面。最终优化结论依据原设备对应场景，历史已完成的跟进与一次性报告从版本标签检索。
