# 外挂漫画字幕候选版试用记录

2026-11-28 · `test/comic-subtitles` · 《山路》0.1 校对版

## 可复查的测试包

GitHub Actions 从 `16c447934f3ced911a199baee569ca6e6f64faef` 构建了 1.18.5+254 的三个候选包，并校验包内平台、版本和内容。手机版与 TV 版均提供 arm64、armeabi-v7a、x86_64 和通用 APK。表内摘要对应解开 Actions 下载件后得到的文件。[构建和校验回执](https://github.com/CyrilPeng/Venera-Next/actions/runs/46103440848)

| 平台 | 下载 | 文件 SHA-256 |
| --- | --- | --- |
| Android 手机 arm64 | [APK](https://github.com/CyrilPeng/Venera-Next/actions/runs/46103440848/artifacts/15247830600) | `ba512353cef21daf2cc92d39ca253ba8e775bd81a2828065a6f8efc6a72c9257` |
| Android TV arm64 | [APK](https://github.com/CyrilPeng/Venera-Next/actions/runs/46103440848/artifacts/15247715635) | `2a6ae1da7e2b1d5dc5b41d2c8535259e3ddeeea2418b7df0b72c78e62fe594a8` |
| Windows x64 | [安装包和便携包](https://github.com/CyrilPeng/Venera-Next/actions/runs/46103440848/artifacts/15247361398) | 安装包 `56058f840fb8baca28571a556e2c5fef2245714b25682e50eaee5b12045c762b`，便携 ZIP `6bd32d30bcbdda1854c016423446b48d08972211a41a669b6963340958942fac` |

样章包含三张原创 PNG、四句校对原文、十处语言区域和三次拆并记录。CBZ 的 SHA-256 为 `b8315eec00285a1d6c79b9b8dc18c3f85b3b8bf4797dba96d5ae29d6a3c5f6b4`。[下载《山路》CBZ](../../spec/comic-subtitles/fixtures/mountain-path-0.1.cbz)

## 阅读器测量方法

试用入口使用正式应用的启动流程、CBZ 导入器、SQLite 挂载、图片组件、搜索索引和连续阅读视口。每台设备在同一进程内开启、关闭字幕各三轮，按「关、开／开、关／关、开」交错执行。每轮进入前清空 Flutter 图片缓存和阅读器图片尺寸缓存，保留操作系统文件缓存。首图耗时从打开阅读页计至首次观测到已解码原图，轮询间隔为 16 ms。首轮还包含本进程首次进入阅读器的成本。

每轮在连续阅读模式往返滚动，单程 1.1 秒。滚动 P95 取该段引擎帧的总耗时。RSS 峰值每 32 ms 采样一次，覆盖开页、滚动和搜句。HTTP 请求数取同期主 isolate 的 `AppDio` 请求日志，涵盖成功和失败的请求。Android 试用开始前关闭 Wi-Fi 和移动数据并核对飞行模式。[试用入口](../../tool/comic_subtitles/device_trial.dart) · [主机采集](../../tool/comic_subtitles/run_trial.py)

## Android 飞行模式

试用检出 `5b23ae34cc874f00d942f721dc0d1ea7a7f4d7f5`。两台均为 Android 14 API 34、x86_64、320 × 640、SwiftShader，系统镜像构建为 UE1A.230829.050 / 12077443。以下为各组三轮中位数，括号内为最小至最大值。[工作流](https://github.com/CyrilPeng/Venera-Next/actions/runs/46105129731)

| 配置与字幕 | 首图 ms | 滚动帧 P95 ms | RSS 峰值 MiB |
| --- | ---: | ---: | ---: |
| 1536 MiB · 关 | 303.2（283.3–357.1） | 46.8（28.8–47.8） | 103.3（100.0–149.3） |
| 1536 MiB · 开 | 284.7（160.7–416.8） | 45.3（24.8–52.4） | 129.8（97.9–130.0） |
| 3072 MiB · 关 | 125.4（60.8–194.0） | 24.2（21.8–59.5） | 230.9（226.7–231.0） |
| 3072 MiB · 开 | 89.9（58.5–123.3） | 23.2（21.4–82.9） | 228.4（227.5–228.6） |

系统实际报告 `MemTotal` 分别为 1,505,432 和 3,050,652 KiB。两档均能在中文和英文译本中定位第一页的日文对白，第三页底部「日出」进入视口，三张原图逐一核对摘要成功。12 轮的应用 HTTP 请求计数均为零。低内存档开启字幕时 RSS 峰值中位数增加 26.5 MiB，三轮开页与帧耗时均有较大波动。当前数据可作为模拟器复测基线，物理手机的性能预算待同机对照。[1536 MiB 逐轮记录](https://github.com/CyrilPeng/Venera-Next/actions/runs/46105129731/artifacts/15247607566) · [3072 MiB 逐轮记录](https://github.com/CyrilPeng/Venera-Next/actions/runs/46105129731/artifacts/15248060761)

## 人工复核

TV flavor 的阅读器回归从阅读画面用方向键和确认键打开字幕面板，返回后核对页码。桌面布局回归在 720 × 560、1040 × 680 两种逻辑窗口中，将第一页译文中心与原图对白框逐一比对，误差均小于 1 个逻辑像素。本机 124 项字幕、翻页、遥控和 CBZ 回归通过。[阅读器集成回归](../../test/features/reader/subtitle_reader_integration_test.dart)

导入样章，在阅读设置中开启「外挂漫画字幕（实验）」。打开样章，依次选择「本章字幕」→「管理本章字幕」→「载入归档内的字幕」并保存。选中文时，搜「山の下」与「脚下」都应定位第一页同一气泡。选英文后可搜「Mountain foot」。回到中文并搜「日出」，第三页底部的气泡应进入视口。

实体 Android 手机可在飞行模式下复查双指缩放、翻页、撤下字幕后续读及保存原图。低内存设备另记录型号、可用内存、长时间滚动与回到后台后的表现。TV 可用实体方向键、确认和返回键操作字幕面板。反馈附设备与系统版本、候选包、命中的页码及异常步骤，便于用相同修订复测。
