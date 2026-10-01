# 项目结构约定

本文档记录 `lib/` 与 `test/` 的目录边界，用于后续新增功能、迁移旧代码和审查结构调整。

## 总体原则

- `app_shell/` 放应用壳层入口，例如鉴权页、首页编排和主导航壳。
- `app_runtime/` 放应用运行时组装，例如启动初始化、更新检查、调试重载和无头命令入口。
- 优先按功能域归集代码。一个功能同时包含状态、数据模型、服务、页面和子组件时，应放在同一个 `features/<domain>/` 下。
- 不再新增 `pages/` 目录；应用级入口放入 `app_shell/`，业务页面放入对应 `features/<domain>/`。
- `foundation/` 放跨业务域的应用基础能力，例如应用状态、初始化协议、异步队列、通用 Dart 扩展、常量、日志、本地化、中文转换、文件系统基础工具、文件类型识别、平台文件交互、节流任务调度、图片处理、图片 provider 基类、阅读历史元数据契约、平台连接和通用数据基建。
- `components/` 放可跨页面复用的 UI 组件。若组件只服务某个业务域，应放回对应的 `features/<domain>/`。
- `foundation/app.dart` 只作为 `App` 单例入口，不再 re-export `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- 任何文件若使用 BuildContext、Widget、TextStyle 或 Color 扩展，应显式引用实际使用的 `foundation/context.dart` 或 `foundation/widget_utils.dart`，避免把应用状态入口当作 UI 扩展桶。
- `utils/` 已进入退场状态，不再作为新增工具的默认目录。新增工具应先判断归属：跨功能域基础能力放入 `foundation/`，带明确业务语义的工具放入对应功能域。
- 文件路径、文件名清洗、目录复制、文件系统扩展和大小格式化等基础文件能力应直接引用 `foundation/file_system.dart`，避免通过平台文件交互入口绕行。
- 文件选择、目录选择、文件保存、分享和 Android SAF IO override 等平台文件交互应归入 `foundation/file_interaction.dart`；`utils/io.dart` 已退场，不再作为导出入口。
- 通用 Dart 扩展通过 `foundation/extensions.dart` 对外暴露；具体 List、String、Future 和 nullable collection 转换实现放在 `foundation/extensions/` 下。
- `network/` 放通用网络、缓存、请求和文件传输基础设施；`network/webdav.dart` 统一 WebDAV 端点、认证、客户端创建和远端路径规则。业务下载任务与接口封装应放在所属功能域中。
- `foundation/image_provider` 只保留通用图片加载基础设施；依赖具体业务模型、缓存目录或功能域管理器的 provider 应放在所属 `features/<domain>/`。

## `lib/features`

`features/` 是业务代码的主要归属地。当前功能域包括：

- `comic_source/`：漫画源模型、解析、分类、首页摘要、收藏映射、标签翻译和漫画源翻译等漫画源能力。
- `comic_storage/`：跨本地目录、CBZ 与 WebDAV 复用的漫画归档元数据、图片文件规则和本地文件系统布局识别。
- `comic_widgets/`：漫画卡片、列表、评分和跨功能域复用的漫画展示组件；内部按列表、卡片、评分等职责拆分，并通过 `comic_widgets.dart` 统一导出。
- `comic_details/`：漫画详情页及章节、评论、收藏按钮、封面和缩略图等详情页子模块。
- `discovery/`：探索页、分类页、分类漫画列表和排行榜等浏览发现页面。
- `favorites/`：本地收藏、网络收藏、收藏夹页面和收藏操作。
- `follow_updates/`：追更状态、追更检查和追更页面。
- `history/`：阅读历史、首页历史摘要、图片收藏模型、图片收藏管理和图片收藏 provider。
- `image_favorites/`：图片收藏页面、首页摘要、图库浏览和图片查看 UI。
- `local_comics/`：本地漫画库管理、首页本地漫画摘要、下载任务，以及 `import_export/` 下的 CBZ、EPUB、PDF、导入导出工具。
- `reader/`：阅读器页面、手势、章节、图片加载、瀑布流阅读实现，以及图片剪贴板写入、音量键监听等阅读场景专用平台交互。
- `search/`：首页搜索入口、搜索首页、搜索结果页、聚合搜索页面和搜索查询过滤规则。
- `settings/`：设置页面、阅读设置、设置页共享控件和各业务域的页面选择设置。
- `sync/`：WebDAV 数据同步、首页同步状态、应用数据导入导出和本地漫画备份恢复。
- `webdav_library/`：WebDAV 漫画库在线阅读源，负责远端目录图片结构的列表、详情和图片加载配置。

新增功能域时，优先采用以下形态：

```text
lib/features/<domain>/
  <domain>.dart
  <domain>_page.dart
  ...
test/features/<domain>/
  <domain>_test.dart
```

不是每个功能域都必须同时有数据层和页面层；目录边界应以业务归属为准。

外部模块应优先通过功能域入口引用能力，而不是直接依赖功能域内部实现文件。已经建立稳定入口的功能域，应在入口文件中 export 对外类型；例如漫画源功能通过 `features/comic_source/comic_source.dart` 暴露漫画源模型、服务、首页摘要、标签翻译和管理页面，漫画详情页通过 `features/comic_details/comic_details.dart` 暴露 `ComicPage`，浏览发现功能通过 `features/discovery/discovery.dart` 暴露探索页、分类页、分类漫画列表和排行榜，收藏功能通过 `features/favorites/favorites.dart` 暴露收藏管理器和收藏页面，追更功能通过 `features/follow_updates/follow_updates.dart` 暴露追更服务和追更页面，历史功能通过 `features/history/history.dart` 暴露历史管理器、首页摘要、图片收藏 provider 和历史页面，图片收藏功能通过 `features/image_favorites/image_favorites.dart` 暴露图片收藏页面、首页摘要和排序类型，阅读器通过 `features/reader/reader.dart` 暴露阅读页面、加载入口、章节评论页和瀑布流模型，搜索功能通过 `features/search/search.dart` 暴露首页搜索入口、搜索首页、搜索结果页、聚合搜索页和搜索查询过滤规则，设置功能通过 `features/settings/settings.dart` 暴露设置页、应用设置、探索设置、阅读器设置、外观设置、本地收藏设置、网络设置、日志页、调试页、关于页、更新日志和可复用设置面板，同步功能通过 `features/sync/sync.dart` 暴露数据同步、首页同步状态、数据迁移、漫画备份和漫画归档页面，本地漫画通过 `features/local_comics/local_comics.dart` 暴露本地库、首页摘要、下载任务、本地漫画页面和下载队列弹窗，本地漫画导入导出通过 `features/local_comics/import_export/import_export.dart` 暴露格式工具，WebDAV 漫画库通过 `features/webdav_library/webdav_library.dart` 暴露在线目录图片阅读源。外部页面、路由和测试不应绕过这些入口直接 import 内部实现文件。

漫画归档元数据和跨存储介质复用的文件规则统一通过 `features/comic_storage/comic_storage.dart` 暴露；本地漫画、CBZ 和 WebDAV 不应分别复制这些规则，也不应绕过入口直接引用其实现文件。

## `lib/app_shell`

`app_shell/` 保留应用级入口和页面编排：

- `main_page.dart`：主导航壳，负责挂载首页、收藏、探索和分类等一级入口。
- `home_page.dart`：首页编排，只通过各功能域入口组装业务摘要组件。
- `auth_page.dart`：应用启动和前后台切换时使用的本地鉴权页面。

应用壳层可以依赖功能域入口；功能域不应反向依赖应用壳层。
`app_shell.dart` 是壳层对外入口，`main.dart` 等应用组装代码应通过它引用应用级页面；`features/`、`routing/`、`foundation/`、`network/`、`utils/` 和 `components/` 不应依赖 `app_shell/`。

## `lib/app_runtime`

`app_runtime/` 保留应用启动和运行模式组装：

- `init.dart`：应用启动初始化、功能域回调注册、更新检查和调试重载入口。
- `headless.dart`：无头命令模式入口。

运行时组装层可以依赖功能域、基础设施和路由入口；业务功能域不应反向依赖运行时组装。
`app_runtime.dart` 是运行时组装对外入口，`main.dart` 等应用入口代码应通过它引用启动和无头模式能力；`app_shell/`、`features/`、`routing/`、`foundation/`、`network/`、`utils/` 和 `components/` 不应依赖 `app_runtime/`。

跨功能域的运行时连接也归 `app_runtime/` 负责。漫画源保存后的数据同步通过回调注入，WebDAV 漫画源通过附加源 provider 注入；`comic_source/` 不应为了这些运行时能力反向依赖 `sync/` 或 `webdav_library/`。

跨功能域复用的漫画展示组件只声明展示所需的状态与 provider 接口。收藏、历史、本地漫画封面和收藏页显示偏好由 `app_runtime/` 注入，`comic_widgets/` 不应直接依赖这些业务域的管理器或实现文件。

## `lib/pages`

`pages/` 已退场，不再承载源码。若新增页面无法归属到现有功能域，应先判断它是应用壳层入口还是新的业务域：前者放入 `app_shell/`，后者放入 `features/<domain>/` 并提供功能域入口。

## `lib/routing`

`routing/` 放应用级路由适配代码，用于把功能域中的纯数据目标、deep link、平台分享入口、设置组件出口、WebView/桌面 WebView 适配和需要页面协作的流程转换为具体页面跳转。功能域模型不应直接 import `pages/`；若需要根据业务目标打开页面，应优先在 `routing/` 中添加薄适配层。

## 测试目录

测试目录应尽量镜像源码目录：

- `lib/features/<domain>/` 对应 `test/features/<domain>/`。
- `lib/foundation/` 对应 `test/foundation/`。
- `lib/network/` 对应 `test/network/`。
- `utils/` 已退场，不再新增对应测试目录；基础工具测试放入 `test/foundation/`，业务工具测试放入对应 `test/features/<domain>/`。

移动源码时，应同步移动或更新对应测试文件，并修正 package import。若当前环境缺少平台依赖导致部分测试跳过，应至少保证相关测试可编译并记录跳过原因。

## 迁移检查清单

每次结构迁移应完成以下检查：

- 使用 `git mv` 保留文件历史。
- 更新所有 `package:venera_next/...` 和相对 import。
- 使用 `rg` 确认旧路径没有残留引用。
- 运行 `python .github/scripts/check_structure_imports.py`，确认没有受限方向的 import/export。
- 更新 `CHANGELOG.md` 的当前版本 `变更` 小节。
- 运行 `flutter analyze`。
- 运行与迁移功能域相关的测试；跨域引用较多时运行更大范围测试。
- 每个独立迁移阶段单独提交，提交信息使用 `refactor(<scope>): ...`。

## 结构边界检查

`.github/scripts/check_structure_imports.py` 会扫描 `lib/` 下的 Dart import/export，阻止新增以下方向的依赖：

需要审查当前功能域依赖时，可运行 `python .github/scripts/check_structure_imports.py --print-feature-dependencies` 输出功能域之间的 import 数量；该报告用于识别后续收束目标，不要求一次性消除所有跨域依赖。

- `lib/pages` 中重新新增 Dart 源码。
- `lib/utils/tags_translation.dart`、`lib/utils/translations.dart`、`lib/utils/image.dart`、`lib/utils/io.dart`、`lib/utils/file_type.dart`、`lib/utils/init.dart`、`lib/utils/throttled_task_runner.dart`、`lib/utils/channel.dart`、`lib/utils/clipboard_image.dart`、`lib/utils/volume.dart`、`lib/utils/opencc.dart`、`lib/utils/ext.dart` 等已退场业务/应用基础文件重新出现。
- `lib/utils/` 下重新新增任何 Dart 源码；跨功能域基础能力应进入 `foundation/`，业务专用 helper 应进入对应 `features/<domain>/`。
- `features/`、`routing/`、`foundation/`、`network/`、`utils/`、`components/` 反向依赖 `app_shell/`。
- `app_shell/`、`features/`、`routing/`、`foundation/`、`network/`、`utils/`、`components/` 反向依赖 `app_runtime/`。
- `foundation/`、`network/`、`utils/`、`components/` 依赖 `features/` 或 `pages/`。
- `features/comic_source/` 不得直接依赖 `features/history/`、`features/sync/` 或 `features/webdav_library/`；共享阅读历史元数据契约应放在 `foundation/history_contract.dart`，同步和附加源由 `app_runtime/` 注入。
- `features/comic_widgets/` 不得直接依赖 `features/favorites/`、`features/history/` 或 `features/local_comics/`；卡片状态、封面 provider、收藏页显示偏好和状态监听由 `app_runtime/` 注入。
- `foundation/app.dart` 重新 export `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `components/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `components/` 中使用 BuildContext UI 扩展、Widget/TextStyle/Color helper 却未显式引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/comic_details/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/comic_source/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/discovery/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/history/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/local_comics/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/reader/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/search/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/settings/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/sync/` 中未使用 `App` 单例的文件通过 `foundation/app.dart` 间接引用 UI 扩展；应直接引用 `foundation/context.dart` 或 `foundation/widget_utils.dart`。
- `features/<domain>/` 依赖 `pages/`。
- 外部 `lib/` 代码绕过 `app_shell/app_shell.dart` 直接依赖应用壳层内部页面。
- 外部 `lib/` 代码绕过 `app_runtime/app_runtime.dart` 直接依赖运行时组装内部文件。
- `foundation/` 和已收窄的纯文件系统调用点通过 `utils/io.dart` 间接引用文件系统基础能力；应直接使用 `foundation/file_system.dart`。
- 已建立稳定入口的功能域，外部 `lib/` 代码绕过入口直接依赖其内部实现文件。
- `foundation/extensions.dart` 重新承载实现、import 或 part，或外部代码绕过该入口直接依赖 `foundation/extensions/` 下的分类实现文件。
- 历史功能中图片收藏模型或管理实现绕过 `features/history/history.dart` 稳定入口，或重新作为 `history_manager.dart` 的 part。
- 设置功能中的共享设置控件绕过 `features/settings/settings.dart` 稳定入口，或重新作为 `settings_page.dart` 的 part。
- 设置功能中的关于页、更新日志或更新检查逻辑绕过 `features/settings/settings.dart` 稳定入口，或重新作为 `settings_page.dart` 的 part。
- 设置功能中的外观设置逻辑绕过 `features/settings/settings.dart` 稳定入口，或重新作为 `settings_page.dart` 的 part。
- 设置功能中的本地收藏设置逻辑绕过 `features/settings/settings.dart` 稳定入口，或重新作为 `settings_page.dart` 的 part。
- 设置功能中的日志查看或导出逻辑绕过 `features/settings/settings.dart` 稳定入口，或重新作为 `app.dart` 的 part。
- 设置功能中的调试工具逻辑绕过 `features/settings/settings.dart` 稳定入口，或重新作为 `settings_page.dart` 的 part。
- 设置功能中的网络、代理或 DNS 设置逻辑绕过 `features/settings/settings.dart` 稳定入口，或重新作为 `settings_page.dart` 的 part。
- 设置功能中的探索页偏好、筛选页配置或屏蔽词设置绕过 `features/settings/settings.dart` 稳定入口，或重新作为 `settings_page.dart` 的 part。
- 设置功能中的应用数据、缓存、认证或同步设置绕过 `features/settings/settings.dart` 稳定入口，或重新作为 `settings_page.dart` 的 part。
- 设置功能中的阅读器设置绕过 `features/settings/settings.dart` 稳定入口，或 `settings_page.dart` 重新声明 part library。

浏览发现页面已经纳入稳定入口约束，外部代码应通过 `features/discovery/discovery.dart` 引用探索页、分类页、分类漫画列表和排行榜。
浏览发现功能内部的分类漫画页和排行榜页不应通过 `foundation/app.dart` 间接引用 UI 扩展；仅实际访问 `App` 单例的发现页实现文件保留该入口。

设置页面已经纳入稳定入口约束，外部代码应通过 `features/settings/settings.dart` 引用设置页、阅读设置和页面选择设置面板。
设置功能内部的本地收藏设置、调试页、日志页和设置入口页不应通过 `foundation/app.dart` 间接引用 UI 扩展；仅实际访问 `App` 单例的设置实现文件保留该入口。

图片收藏页面和首页摘要已经纳入稳定入口约束，外部代码应通过 `features/image_favorites/image_favorites.dart` 引用图片收藏 UI。
图片收藏功能内部的图片查看页应保持独立实现文件，不应重新作为 `image_favorites_page.dart` 的 part。
图片收藏功能内部的图库页应保持独立实现文件，不应重新作为 `image_favorites_page.dart` 的 part。
图片收藏功能内部的条目组件应保持独立实现文件，不应重新作为 `image_favorites_page.dart` 的 part。

同步状态首页卡片已经纳入稳定入口约束，外部代码应通过 `features/sync/sync.dart` 引用同步 UI。
同步功能内部的漫画归档页不应通过 `foundation/app.dart` 间接引用 UI 扩展；仅实际访问 `App` 单例的同步实现文件保留该入口。

本地漫画页面、下载队列和首页摘要已经纳入稳定入口约束，外部代码应通过 `features/local_comics/local_comics.dart` 引用本地漫画 UI。
本地漫画下载队列弹窗不应通过 `foundation/app.dart` 间接引用 UI 扩展；仅实际访问 `App` 单例的本地漫画实现文件保留该入口。

漫画源管理页面、首页摘要和标签翻译已经纳入稳定入口约束，外部代码应通过 `features/comic_source/comic_source.dart` 引用漫画源能力。
漫画源首页摘要不应通过 `foundation/app.dart` 间接引用 UI 扩展；仅实际访问 `App` 单例的漫画源实现文件保留该入口。

历史页面和首页摘要已经纳入稳定入口约束，外部代码应通过 `features/history/history.dart` 引用历史 UI。
历史首页摘要不应通过 `foundation/app.dart` 间接引用 UI 扩展；仅实际访问 `App` 单例的历史实现文件保留该入口。

搜索页面、首页入口和搜索查询过滤规则已经纳入稳定入口约束，外部代码应通过 `features/search/search.dart` 引用搜索能力。
搜索功能内部的聚合搜索页不应通过 `foundation/app.dart` 间接引用 UI 扩展；仅实际访问 `App` 单例的搜索实现文件保留该入口。

漫画展示组件已经纳入稳定入口约束，外部代码应通过 `features/comic_widgets/comic_widgets.dart` 引用漫画列表、卡片、评分控件和后续拆出的展示组件。

收藏功能中的收藏动作应保持独立实现文件，并通过 `features/favorites/favorites.dart` 暴露，不应重新作为 `favorites_page.dart` 的 part。
收藏功能内部的文件夹侧边栏应保持独立实现文件，不应重新作为 `favorites_page.dart` 的 part。
收藏功能内部的网络收藏页应保持独立实现文件，不应重新作为 `favorites_page.dart` 的 part。
收藏功能内部的本地收藏页应保持独立实现文件，不应重新作为 `favorites_page.dart` 的 part。

漫画详情功能内部的封面查看页应保持独立实现文件，不应重新作为 `comic_page.dart` 的 part。
漫画详情功能内部的评论页应保持独立实现文件，不应重新作为 `comic_page.dart` 的 part。
漫画详情功能内部的操作按钮、章节列表、评论页、封面查看、评论预览和缩略图不应通过 `foundation/app.dart` 间接引用 UI 扩展；仅实际访问 `App` 单例的详情实现文件保留该入口。
漫画详情功能内部的操作按钮组件应保持独立实现文件，外部代码不应绕过 `features/comic_details/comic_details.dart` 直接依赖。
漫画详情功能内部的评论预览组件应保持独立实现文件，不应重新作为 `comic_page.dart` 的 part。
漫画详情功能内部的缩略图预览组件应保持独立实现文件，不应重新作为 `comic_page.dart` 的 part。
漫画详情功能内部的章节列表组件应保持独立实现文件，不应重新作为 `comic_page.dart` 的 part。
漫画详情功能内部的收藏面板应保持独立实现文件，不应重新作为 `comic_page.dart` 的 part。
漫画详情功能内部的动作 mixin 应保持独立实现文件，`comic_page.dart` 不应重新声明 part library。
漫画源功能内部的核心模型应保持独立实现文件，并通过 `features/comic_source/comic_source.dart` 稳定入口向外暴露。
漫画源功能内部的回调类型定义应保持独立实现文件，并通过 `features/comic_source/comic_source.dart` 稳定入口向外暴露。
漫画源功能内部的分类数据应保持独立实现文件，并通过 `features/comic_source/comic_source.dart` 稳定入口向外暴露。
漫画源功能内部的翻译扩展应保持独立实现文件，并通过 `features/comic_source/comic_source.dart` 稳定入口向外暴露。
漫画源功能内部的图片加载注册应保持独立实现文件，并通过显式解析器连接漫画源管理器与网络图片层。
漫画源功能内部的收藏数据应保持独立实现文件，并通过 `features/comic_source/comic_source.dart` 稳定入口向外暴露。
漫画源功能内部的 JS 数据桥接应保持独立实现文件，并通过显式回调连接漫画源管理器与 JS 引擎。
漫画源功能内部的类型桥接扩展应保持独立实现文件，并通过 `features/comic_source/comic_source.dart` 稳定入口向外暴露。
漫画源功能内部的 JS 返回值归一化工具应保持独立实现文件，并由解析器与测试入口显式依赖。
漫画源功能内部的主类和源配置数据应保持独立实现文件，并通过注册表回调连接漫画源管理器。
漫画源功能内部的解析器应保持独立实现文件，并通过类型桥接和 JS 数据桥接注册函数连接运行环境。
阅读器功能内部的章节评论页应保持独立实现文件，并通过 `features/reader/reader.dart` 稳定入口向外暴露。
阅读器章节评论页不应通过 `foundation/app.dart` 间接引用 UI 扩展；仅实际访问 `App` 单例的阅读器实现文件保留该入口。
阅读器功能入口 `reader.dart` 应保持 export-only，不应重新声明 part library。
阅读器主实现 `reader_page.dart`、脚手架、图片视图、手势、漫画图片组件、加载入口和章节列表应保持普通 Dart 实现文件，不应重新作为 `reader.dart` 或 `reader_page.dart` 的 part。
阅读器功能外部代码应通过 `features/reader/reader.dart` 引用阅读页面、加载入口、章节评论页和瀑布流模型，不应直接依赖 reader 内部实现文件。

当前不再保留过渡例外；发现受限 import/export 时应通过移动代码、抽出回调或增加 `routing/` 薄适配层来恢复依赖方向。

## 业务与 UI 入口增量迁移

漫画源新增 `comic_source_api.dart`（模型、服务及运行时配置）和 `comic_source_ui.dart`（页面与首页摘要）。`comic_source.dart` 保留为兼容聚合入口；新的业务调用者使用 API 入口。更新检查/下载属于 `SourceUpdateService`，页面只处理交互，无头调用者直接使用服务。

本地漫画阅读位置通过 `local_reading.dart` 的纯函数解析；页面调用 `routing/local_reading.dart` 打开阅读器，`LocalComic` 不承担导航。

CI 同时运行 `check_architecture_dependencies.py`，按 `dependency_baseline.json` 禁止新增功能域依赖，并检查已登记业务入口的传递 UI 依赖。既有聚合图包含 UI 导航环，不能把该报告视为纯业务依赖图。业务入口逐步登记，基线变更必须伴随明确的职责调整。

阅读器运行时通过 `foundation/reader_settings.dart` 的不可变 `ReaderSettings` 快照访问设置，`Settings.readerSettings` 负责对接原有存储，`globalReaderSettings` 保留全局选项的原有范围。阅读器不得调用动态 `getReaderSetting` / `getDeviceReaderSetting`；其他旧调用者及设置表单的兼容接口在 P3 后续任务中继续迁移。

阅读设置字段由 `ReaderPreferences` 统一定义键、默认值、校验和滑块元数据。`ReaderPreferenceStore`/绑定负责有类型的作用域读写；阅读设置控件使用 `.reader` 构造入口，旧通用控件接口仅服务未迁移的其他设置域。运行时快照和 Appdata 初始默认值复用同一字段定义。

通用字段与绑定协议位于 `foundation/preferences.dart`；全局网络/外观字段位于 `application_preferences.dart`，不可变读取模型位于 `application_configuration.dart`，存储通过 `GlobalPreferenceStore` 适配。已迁移页面使用 `.preference` 控件入口，网络/下载/主题消费端不再直接访问对应字符串键。阅读设置继续通过 `ReaderPreferenceStore` 保留范围继承。

应用同步设置由 `foundation/sync_configuration.dart` 解析，`SyncPreferenceStore` 对接原有 settings/implicitData 并提供配置检查点。服务持有传输和回滚事务，适配器不主动持久化或启动定时器；设置预览保持只读。`DataSyncMode` 从原入口继续导出以兼容现有调用者。

`Init.init()` 同一尝试仅执行一次，`ensureInit()` 等待显式启动并共享失败；`retryInit()` 是失败后重新执行的唯一入口。实现应在失败时清理部分资源，不得吞掉异常伪装为就绪。启动依赖不得形成自等待。

DataSync 构造无运行副作用，由运行时显式 start；dispose 禁止新任务和迟到通知，已开始的传输继续收尾。WindowFrame 先执行同步关闭守卫，再逆注册顺序等待异步退出任务；它还持有已卸载组件移交的在途任务。app_runtime/SyncWindowBinding 在最后等待历史队列与上传，挂载/卸载管理任务注册；业务服务不得重新访问 WindowFrame 或根 context。

启动边界：`bootstrap_core.dart` 组装实际核心服务，`core_bootstrap.dart` 定义可注入、单次执行的依赖顺序。`init.dart` 仅组装交互绑定与后台自动工作；`headless.dart` 仅初始化共享核心和无头 JS 适配，不得调用交互入口或启动窗口/自动同步。核心错误缓存，失败后不得自动重开已部分初始化的存储。旧域聚合入口的传递依赖仍按 P2/P6 逐步迁移。

交互事件由 `InteractiveBindings` 实例持有，主应用挂载后 start、卸载时 dispose。链接与文本分享通过 `EventSubscription` 串行处理，await 后必须检查有效性再导航。不得重新引入全局文本分享启动标记或无所有者的心跳/事件订阅。

`BackgroundSync` 在主应用挂载后管理自动同步调度；WebDAV 源只执行检查/传输，不保存静态轮询定时器。DataSync.stop 保留本地变更观察以避免丢失 pending，dispose 才解除观察；停止调度不得中断已进入提交的传输。旧代数 tick 不得启动新调度的工作。

追更后台检查从页面分离到 FollowUpdatesService，通过 follow_updates_api.dart 暴露无 UI 的窄边界。服务只能取消自身任务句柄；运行时负责定时器和外部通知监听的启停。页面订阅 followUpdatesChanges 并在 dispose 退订，不得重新使用全局 State 查找刷新追更页面或预览。

缓存管理器以实例保存路径、数据库、扫描器和操作队列；CacheManager.open 支持独立宿主，start 显式启动一次扫描，dispose 排空已接收操作后关闭。扫描器只返回结果，不访问全局缓存实例；缓存操作不得绕过队列或在未等待 dispose 完成时删除工作目录。

共享图片下载由 SharedRequestStream 持有独立 RequestScope；实际订阅触发源流，最后一个订阅退出时先取消图源/HTTP，再释放源订阅。调用者只能释放自己的订阅，不能把单个调用者的 RequestScope 作为共享请求的父作用域。图片缓存命中须直接完成，不再进入图源或网络加载。

阅读器不得在卸载时调用全局图片取消。ReaderImageDownloads 管理预下载订阅，ReaderImagePrecache 管理解码预取监听；释放 pending 缓存时保留 live 消费者及已解码缓存，最终保活句柄由 Flutter 在帧末释放。正常图片取消不作为加载失败报告，真实错误保留原有处理。

LoadingState 的首次加载与手动重试共享同一尝试流程，每次尝试持有 RequestScope；替换/卸载取消，结果与 onDataLoaded 完成后验证当前尝试身份。loadData/onDataLoaded 显式接收作用域，业务回调必须在 await 后先检查取消再发布副作用；不得恢复重复的未受控 then/setState 路径。

图片序号与显示页码转换统一使用无 UI 依赖的 ReaderPageLayout；持久化历史仍保存图片序号。画廊取图使用零基半开区间，布局重排保持原页首图可见；调用端不得重新实现首页单图、多图同页和章节末图历史规则。跨章节瀑布流及拆图坐标属于独立策略。

章节坐标通过 ComicChapters.positionAt/chapterIndex 转换。ComicChapterPosition 明确源 ID、展开编号、组号和组内编号，历史键沿用原格式；不得用合并 allChapters 后的键序列推断跨组位置，因为不同分组可包含相同源 ID。图片与显示页转换继续交由 ReaderPageLayout。

ReaderController 持有导航状态并提供 ReaderNavigationState 快照；不得导入 Flutter、全局设置或存储。视图导航通过 ReaderNavigationViewport，手势接口保留在 UI 层。ReaderLocation 兼容 mixin 已删除，页面直接装配控制器，不得重新引入页面动画状态机；控制器必须随页面销毁以屏蔽迟到回调。

ReaderImagePosition 表示源图片，ReaderPageLayout 转换显示页，WaterfallChapterFlow 转换跨章列表索引；后者反向定位必须校验章节 ID。ReaderImageSlice 的源/显示区域为归一化绘制偏移，不是新的源图片或历史页。历史只保存转换后的源图片序号，保持现有数据协议。

阅读加载/视图选择保留在 images.dart；gallery_view.dart 与 continuous_view.dart 分别承载画廊和连续/瀑布流适配，chapter_swipe_indicator.dart 负责切章指示。菜单选图使用 ReaderImageViewController.currentImageRange，不依赖具体 State 类型；迁移期 State 导出不应被新业务代码使用。

ChapterImageLoader 只依赖注入的章节访问和错误回调，禁止直接查找全局管理器。loadReaderChapterImages 是连接旧存储/图源的适配入口；稳定章节 ID 与已下载判断在适配层，本地优先/回退/取消在策略层。两层测试分别覆盖真实存储兼容和无全局依赖的行为。

ReaderController 同时持有 ReaderContentState，图片列表必须复制为不可变快照。加载以 ReaderContentLoad 身份提交，旧所有者只能取消自身尝试；布局准备期间不得提前解除加载。视图协调刷新，内容命令不在 build/init 中自行触发通知；已加载瀑布流章节通过 replaceChapterImages 激活。

ReaderHistoryWriter 只负责单个阅读器的延迟保存和退出刷新调度，通过回调访问存储与错误报告。历史坐标转换留在适配端；销毁必须取消待触发定时器，不能取消或重复提交存储已接受的操作。数据库写入排序由存储层负责。

WaterfallController 拥有章节插入/重置、预取/导航状态及请求作用域，连续视图只持有 WaterfallFlowView 查询协议。前插返回源图片数，由视图恢复滚动锚点；跳章和销毁使旧请求及帧回调失效。控制器不依赖 Flutter、ReaderState、全局图源或存储，实际访问由装配端注入。

画廊通过 ReaderGalleryData 和 ReaderController 接收内容/配置与导航，不得查找祖先 ReaderState 或读取全局设置。images.dart 装配评论 Widget、界面回调与图片读取。ReaderImageViewController 独立于页面定义在 reader_viewport.dart；页面不再重导出该接口，调用者必须直接依赖协议。图片列表复用控制器快照，源图片处理页码语义不能在结构迁移中隐式改变。

连续视图通过 ReaderContinuousData 接收设置，通过 ReaderController 读取当前章节/内容，章节加载和 UI 副作用使用显式回调。不得恢复祖先 ReaderState 或全局设置查找；跨章后的当前内容必须即时读取控制器，不能缓存成等待父级重建才更新的章节快照。images.dart 共享视口注册和图片读取适配。

progress_bar.dart 只负责底栏、进度滑块和页码文字展示，通过值与回调接收状态；滑块拥有自己的焦点节点。scaffold.dart 决定章节跳转、业务按钮、显示位置及菜单生命周期，不得向进度组件重新引入 ReaderState/全局设置依赖。底栏高度由 ReaderBottomBar.height 统一声明。

ReaderStatusInfo 拥有时钟与电量轮询，平台访问通过 ReaderBatteryRead 注入并返回 ReaderBatterySnapshot；scaffold 只决定显示条件与位置。每个依赖代数最多一个电量请求，卸载/替换后不得发布旧结果，不支持与瞬时失败必须区分。底层平台 Future 不可取消时仍须停止后续调度。

ReaderTopBar 只接收标题、动作与返回回调，ReaderBrightnessPanel 只接收数值与修改回调；scaffold 负责权限/可见性判断、设置范围与保存、导航和侧栏生命周期。面板不得重新查找阅读器 State 或直接写入设置。

图片导出通过 ReaderImageExporter 编排，ReaderImageSelection 必须在读取前固定身份；外壳提供实际缓存/文件和平台操作，异步完成后不得用当前页面位置重命名已选图片。ReaderImageSelectionOverlay 独立持有覆盖层与等待者，替换/销毁必须结束等待；退出只阻止尚未交付的平台操作。

readerSettingEffects 只解析设置通知的有序效果；ReaderPreferences 是固定键的唯一来源，前缀和未知键兼容规则显式保留。外壳执行效果时检查有效性，不得把 Widget 或平台调用移入规则模块；设置值读取仍由应用适配端完成。

ImageFavoriteActions 是 history 领域的纯业务入口，通过回调访问存储；只依赖收藏模型与常量，不可传递导入 UI。阅读器适配选图、翻译、错误及提示，业务服务返回明确结果。原 history.dart 仅作为已有界面兼容入口，不得用于新收藏业务模块。

ReaderSession 拥有 ReaderHistoryWriter 与 ReadingSessionTracker，通过内容就绪和前台状态共同控制计时；Flutter 生命周期、自动阅读暂停与退出同步由适配端注入。退出立即提交待保存进度并停止计时，等待所有已接受的进度（含退出刷新）和时长写入完成，再通知应用一次；迟到内容/生命周期事件不能重启会话。ReaderHistoryWriter.dispose 返回同一个完成 Future，存储错误由注入回调报告。延迟保存与退出统一调用异步 addHistory，不再提供独立 flush 回调或同步落盘入口。桌面页面注册会话退出任务，卸载时移交在途完成信号，正常关闭窗口必须等待该信号及其触发的同步。

ReaderImageCachePolicy 只负责内存分档与单个阅读器的查询有效性；内存插件、日志和 PaintingBinding 缓存由页面适配。退出恢复原 100 MB 上限且使未完成查询失效，重复配置仅接受最新结果。策略不取消底层平台 Future，也不提供跨阅读器的全局缓存仲裁。

ReaderVolumeController 通过注入事件流和导航回调拥有订阅，不能依赖 Flutter 或页面。切换立即使旧输入失效，重连等待 StreamSubscription.cancel，退出停止后续订阅；音量上键在前章末页回退、下键在后章开头前进的策略保留。volume.dart 只适配 venera/volume 通道，页面判断 Android 支持并记录错误。Flutter EventChannel 的原生启停确认与启停错误仍由框架管理，不能把 Dart 取消 Future 当作原生确认。

ReaderWindowController 拥有关闭监听与全屏请求队列，依赖注入的窗口 API、边框显示和导航回调，不查找 context。ReaderState 在依赖初始化时捕获祖先 WindowFrame 和根 Navigator，保留测试可覆盖的装配/释放入口。退出同步移除监听，再等待已接受的原生操作并恢复窗口模式；平台调用不能强制取消，共享桌面窗口在多个阅读器间的所有权仍需运行时仲裁。

ReaderOrientationScope 必须位于 Navigator 外并由应用树管理生命周期；ReaderOrientationCoordinator 只依赖异步方向回调与错误报告，句柄替代静态 Widget State 所有权。ReaderOrientationState 是 Flutter 适配器，取得/释放句柄并刷新 UI。平台映射集中在 orientation.dart，业务枚举不得依赖 DeviceOrientation；无作用域的 Android 阅读器装配属于错误，不回退到隐藏全局实例。

images.dart 不再重导出 ContinuousModeState；依赖具体视图实现的集成测试直接导入 continuous_view.dart。导航行为测试仅依赖 ReaderController/ReaderNavigationViewport 并注入错误报告，不得通过页面 mixin 或全局日志静音进行测试。

History 数据通过 history_api.dart 提供，history_model.dart 不导入 HistoryManager 或页面；旧 history.dart 对 UI 兼容导出数据入口，history_manager.dart 不再充当模型导出。applyReaderHistoryProgress 负责阅读坐标到历史字段的映射，页面仅在加载完成后调用并安排保存。旧字段、fromMap 兼容构造器与描述格式暂时保留，后续存储分解不得隐式改变数据语义。

HistoryRepository 在调用者拥有的 Database 上管理表结构迁移、查询/删除与进度/时长事务，不管理连接、缓存或通知；historyFromRow 位于 history_row.dart，集中解码 SQLite 字段。History 模型不直接导入 SQLite，也不提供 fromRow。HistoryManager 保留异步队列、连接生命周期、缓存和通知，不再直接执行历史表 SQL；不能通过新数据入口重新导出管理器或页面。

条件删除在提交时固定收藏的完整身份集合，在同一删除事务内判断该集合；判断失败或任一删除失败必须整体回滚。保留期限由管理器计算截止时间，仓储保持严格小于比较；最近记录限制 20 条，时长榜按时长与阅读时间降序。

HistoryCache 使用 (id, type) 作为身份索引及最近写入缓存的键，依赖注入式 identities/load 回调。写入仅重新查询该 ID 的实际来源集合，兼容单 ID 主键替换和旧复合身份表；刷新删除失效身份，关闭清空，保留原 10 条写入顺序淘汰策略。缓存返回前核对可变模型身份，不能用错误来源对象满足查询；缓存不是数据库 schema 迁移，也不解决写入排序。

异步历史操作在入队时用 History.copy 固定数据副本（包括独立已读集合）、数据库路径和管理器代次，不能把外部可变对象留待执行时读取。写入后仅当前代次可从实际存储回填缓存并通知；关闭/重开不改变已接受操作的目标库，旧回调不能污染新实例生命周期。进度、时长与全部历史删除共用管理器队列，各自在 Isolate 拥有独立连接，按接受顺序落盘；失败向调用者传播并记录日志，后续任务继续。批量删除身份和收藏集合在入队前固定。waitForAsyncWrites 等待期间若有后续写入则继续排空；需要读取最终结果、导出、迁移或关闭的调用方必须 await，普通 UI 删除通过完成后的通知刷新。此保证限于同一管理器，不取消已接受操作，也不提供崩溃/强制终止耐久性。

桌面启动在显示窗口前启用 window_manager 的关闭拦截，WindowFrame 挂载期间监听原生 close 事件，统一进入关闭守卫与异步退出任务流程；卸载移除监听。主动强制关闭只调用一次进程退出。此路径覆盖插件窗口 close，不能推断系统关机、macOS 应用 Quit 或进程强杀均会等待。

历史进度写入只更新阅读时间、章节/分组、页码、已读集合与最大页数，已存在行的标题/作者/封面和累计时长不得被进度快照覆盖；新记录仍使用完整初始化数据。metadataUpdaterFor 必须在网络请求前取得，固定目标身份与数据库代次，响应只更新提供的信息字段，不插入缺失行，未提供字段保持原值，空字符串可显式清空。信息刷新与封面补齐使用该入口；importHistory 在同一事务内明确替换进度及信息，继续保留原导入的时长策略。

收藏数据入口为 favorites_api.dart，只导出 favorite_models.dart 中的三种收藏模型；旧 favorites.dart 继续聚合 UI 与管理器，favorites_manager.dart 不再隐式导出模型。跨域模型调用通过数据入口，同域可直接导入实现。favoriteItemFromRow 只在 favorite_row.dart 解码 SQLite Row，FavoriteItem.withTime 接收原始时间字符串，不在读取时解析或重建时间。现有 JSON 来源映射、标签仅移除首个空项、派生模型构造及展示设置读取保持原行为，后续变更须明确兼容策略；SQL/缓存/追更编排继续由管理器持有，尚待拆分。

FavoritesRepository 在调用方持有的 Database 上提供基础收藏查询：目录及顺序、计数/排序边界、目录内容、去重汇总/含目录副本、完整身份存在性及所在目录。管理器持有连接、Isolate、缓存与通知，同步/异步读取共用查询实现。目录列表排除原两张辅助表，排序值一次批量读取，缺失值为 0，重复排序行保留首值，孤立行不参与；同值比较规则未变。汇总按输入目录顺序保留首个完整身份，不隐式统一不同来源；读取目录标识符转义双引号。写入、迁移与搜索的后续进展见下文，收藏仓储尚未全部完成。

收藏单条移动、批量移动与批量复制由 FavoritesRepository 持有事务，插入和来源删除必须一起成功或回滚；管理器仅在仓储成功返回后更新计数、身份缓存/追更状态并通知。单条移动遇到目标已有身份保留来源，成功项置于目标最前；批量操作保留目标重复项并按输入次序追加（重复项仍占排序步长），批量移动删除相应来源。同目录批量操作直接返回，避免自删。复制字段仍限于原八个字段，追更/翻译标签复制策略未在本单元改变。

收藏新增由管理器注入翻译标签、首尾偏好和显式排序，FavoritesRepository 在同一事务中检查重复身份、计算位置、插入及写入可选 last_update_time；旧表缺少该列时继续跳过。目录顺序整体事务更新。标签使用绑定参数拼接，仍保持既有按 ID（不区分来源）更新的接口语义；updateInfo 仅更新名称、作者、封面和标签，不改时间/顺序/翻译标签。管理器在成功返回后维护计数、身份、追更状态与原通知策略。

收藏记录删除由仓储在事务内执行，返回每个目录实际删除的完整身份；重复请求合并，不存在项不影响缓存或通知。管理器在提交后按实际删除结果更新目录计数与身份引用，再清理已无任何目录引用的封面；封面文件同步删除的失败单独记录，不影响已提交数据库状态与通知。跨目录删除整体回滚，目录 DROP 与 folder_order 清理也同属事务。目录级封面回收及整库 clearAll 生命周期策略仍保留原实现，后续单独收敛。

收藏目录建表、重命名与网络关联读写由 FavoritesRepository 执行；管理器继续负责名称/重复校验及设置更新。重命名的表名、folder_order、folder_sync 变更必须同一事务成功；删除目录也清理两张辅助表，防止重建同名目录继承旧关联。创建成功后先初始化 counts 再通知，重命名失败不得提前修改设置或缓存。

FavoritesRepository.initializeMetadata 创建目录排序/关联辅助表；migrateTranslatedTags 对所有既有目录逐个检查，不能因前一个目录已具备字段而停止。缺失列和翻译标签回填在同一事务内完成，翻译函数由管理器注入，既有列的数据不重算。prepareForFollowUpdates 原子补齐追更三列，clearData 只清空新更新标记，不改已存时间；管理器负责默认追更目录、配置回退与缓存刷新。初始化期间的连接复用/失败恢复和整库清空生命周期仍另行处理。

收藏目录限量读取、条目重排、单目录/跨目录搜索已迁入 FavoritesRepository。重排按完整身份在单个事务内更新，管理器保留目录校验、失败日志与成功通知。首词继续使用 SQLite LIKE（含通配符/翻译标签），后续词仍按原字段区分大小写匹配；跨目录按完整身份保留首个候选，保留超过 200 后按目录停止、之后再过滤的行为，不将其改为严格结果上限。稍后阅读沿用 SQLite LIMIT 的 0/负数语义。阅读后移动、标签编辑、导出、追更数据与连接生命周期仍待迁移。

收藏管理器及身份缓存 Isolate 不再直接执行 SQL：仓储接管完整身份列表、标签替换、导出读取、阅读后位置/时间更新和追更查询/读写，追更行映射复用 favorite_row。阅读后更新在一次事务中覆盖所有参与目录，跳过稍后阅读目录，使用同一操作时间，成功后才修改追更缓存和通知；未知移动设置只改时间，none 仍只清除追更标记。onRead 移除无实际 await 的 async，保留 void 接口，存储失败可由调用者同步捕获。追更时间比较和写入同一事务，保留相同版本清除标记、缺失身份抛错的规则。标签编辑仍按 ID 跨来源更新，导出读取保持原时间/字段及无显式排序。连接初始化/关闭/清空所有权、身份哈希碰撞与异步刷新代次仍未收敛。

FavoriteIdentityIndex 使用完整 (id, type) 保存收藏身份引用数，追更集合采用同样的完整键，不能再把异或哈希当作唯一身份。异步快照按代次接收，快照期间本地已提交身份的实际引用数覆盖快照值；失败保留当前状态，初始化/关闭清空索引并使旧代次失效。新增/移动/复制/删除在通知前批量校准受影响身份，仓储每目录每 400 个身份一批查询，删除目录/重命名同时重启快照以避开旧表名。删除 reduceHashedId 的盲减入口；refreshHashedIds 和测试等待入口暂保留原命名，但内部不再使用哈希身份。这里只解决身份及快照合并，不代表初始化共享 Future、连接释放、清空路径、所有 Isolate 取消/排空或性能验收已经完成。

收藏初始化按连接代次持有共享 Future：同一路径的并发及已就绪调用复用结果，失败回收连接后由下一次显式 init 重试，路径变化要求先关闭。先等待已启动的 appdata，再在局部连接完成辅助表/字段迁移与默认目录建立，之后发布连接、持久化配置并启动缓存加载；不再通过公开 createFolder 发出半初始化通知。关闭可重复调用，清空连接/索引/计数并使旧初始化失效；迟到失败不得关闭新连接。clearAll 使用已打开连接记录的路径并经过 close 重建，但所有在途 Isolate 的等待/排空、清空与导入互斥仍待后续完成。共享 SQLite 工厂在 PRAGMA 配置失败时主动 dispose，避免未返回给调用方的连接泄漏。

收藏目录、全量和身份快照读取统一登记为待完成任务，记录启动时的路径与连接代次；关闭后拒绝新读取，旧代次的成功结果返回失效错误，所有读取完成/失败都从任务集合移除。close 仍同步使连接失效；文件替换调用 closeAndWait，等待包括被新快照取代的旧任务释放 Isolate 连接。排空期间 init 等待排空结束，清空期间同路径 init 复用清空结果；并发 clearAll 共用一次操作。清空先排空再删除原连接路径，导入及回滚均 await closeAndWait，关闭失败不能静默继续文件替换。这里只收敛管理器拥有的三类读取；同步导出的独立 Isolate、跨域导入/存储迁移的全程互斥，以及清空失败后的恢复仍待处理。

清空使用同目录临时备份保留原数据库，只有新库初始化成功后才删除备份；初始化失败先排空新读取，再恢复旧库及追更/快捷收藏设置并重开，恢复错误记录原路径和备份位置。文件恢复失败时保留备份，不把清理失败误报为清空失败。foundation/FileReplacement 被清空与应用数据导入共同使用，确认备份存在后才删除目标，防止缺失备份时销毁最后一份文件；目录导入沿用现有实现。测试覆盖普通异常下的恢复与重试，不代表断电/崩溃后的自动恢复或跨进程锁已实现，跨域全程互斥仍待完成。

AppDataOperations 在应用主 Isolate 内按提交顺序串行执行应用数据导入、Pica 导入、导出与收藏清空，覆盖解压/压缩 Isolate、文件替换、回滚及清理；单次失败不阻塞后续请求。收藏区分排队中的 clearRequest 与执行中的 clearing，避免导入等待排队清空而形成循环等待。导出使用 UUID 文件名，失败关闭压缩句柄并删除半成品；设置页导入暂存文件也独立命名并在复制失败时清理。应用数据解压改用已有 archive 流式 ZIP 解码器，输入/输出显式关闭并传播写入错误，避开 zip_flutter 0.0.13 原生解压回调参数被手动释放及终结器重复释放的风险；普通/Pica 导入复用同一路径，并拒绝符号链接和越界条目。该队列保护这些批量操作，不阻止普通业务 SQL 写入，不是跨进程锁或一致性数据库快照；本地漫画目录迁移仍由 LocalComicStorageGuard 管理，其涉及的文件集合与上述归档不同。

应用数据导出先等待历史已接受写入并保存设置，再冻结当前 JSON（同步模式复用既有字段拆分规则过滤），不再依赖可能过期的 syncdata.json。createAppDataSnapshot 在独立暂存目录生成历史/收藏/cookie 数据库副本和设置/源文件副本，压缩仅访问暂存文件，成功/失败均清理目录。createSqliteSnapshot 以只读方式打开源库、设置 5 秒锁等待、建立读事务后使用 SQLite backup，包含已提交 WAL 页面并保留 schema/rowid/二进制字段；不切换源库 journal mode，不创建缺失源库或覆盖已有目标。读取事务固定每个库的视图，新的普通写入不改变已固定副本；三个数据库按顺序取快照，非跨库同一时刻事务。批量队列继续覆盖整个暂存/压缩/清理过程，失败不返回半成品归档。

AppDataArchive 独立负责显式路径下的快照暂存、压缩、解压和临时文件清理，不读取 App/appdata，也不引用页面或业务管理器；app_data_transfer 保留队列、设置冻结、版本判断及导入/回滚协调，移除直接 ZIP/Isolate 处理。普通和 Pica 导入共用提取服务。创建归档拒绝已有目标；解压在写入前验证所有条目的路径和符号链接，避免非法后续条目导致前置文件写入。归档和快照入口纳入 business_entrypoints 检查，防止重新引入 UI 依赖；文件写入异常仍向业务编排传播，提取目录及其失败清理由调用方拥有。
