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

DataSync 构造无运行副作用，由运行时显式 start；dispose 禁止新任务和迟到通知，已开始的传输继续收尾。窗口关闭等待逻辑仅在 app_runtime/SyncWindowBinding 中，由组件挂载/卸载管理监听；业务服务不得重新访问 WindowFrame 或根 context。

启动边界：`bootstrap_core.dart` 组装实际核心服务，`core_bootstrap.dart` 定义可注入、单次执行的依赖顺序。`init.dart` 仅组装交互绑定与后台自动工作；`headless.dart` 仅初始化共享核心和无头 JS 适配，不得调用交互入口或启动窗口/自动同步。核心错误缓存，失败后不得自动重开已部分初始化的存储。旧域聚合入口的传递依赖仍按 P2/P6 逐步迁移。

交互事件由 `InteractiveBindings` 实例持有，主应用挂载后 start、卸载时 dispose。链接与文本分享通过 `EventSubscription` 串行处理，await 后必须检查有效性再导航。不得重新引入全局文本分享启动标记或无所有者的心跳/事件订阅。

`BackgroundSync` 在主应用挂载后管理自动同步调度；WebDAV 源只执行检查/传输，不保存静态轮询定时器。DataSync.stop 保留本地变更观察以避免丢失 pending，dispose 才解除观察；停止调度不得中断已进入提交的传输。旧代数 tick 不得启动新调度的工作。

追更后台检查从页面分离到 FollowUpdatesService，通过 follow_updates_api.dart 暴露无 UI 的窄边界。服务只能取消自身任务句柄；运行时负责定时器和外部通知监听的启停。页面订阅 followUpdatesChanges 并在 dispose 退订，不得重新使用全局 State 查找刷新追更页面或预览。

缓存管理器以实例保存路径、数据库、扫描器和操作队列；CacheManager.open 支持独立宿主，start 显式启动一次扫描，dispose 排空已接收操作后关闭。扫描器只返回结果，不访问全局缓存实例；缓存操作不得绕过队列或在未等待 dispose 完成时删除工作目录。

共享图片下载由 SharedRequestStream 持有独立 RequestScope；实际订阅触发源流，最后一个订阅退出时先取消图源/HTTP，再释放源订阅。调用者只能释放自己的订阅，不能把单个调用者的 RequestScope 作为共享请求的父作用域。图片缓存命中须直接完成，不再进入图源或网络加载。

阅读器不得在卸载时调用全局图片取消。ReaderImageDownloads 管理预下载订阅，ReaderImagePrecache 管理解码预取监听；释放 pending 缓存时保留 live 消费者及已解码缓存，最终保活句柄由 Flutter 在帧末释放。正常图片取消不作为加载失败报告，真实错误保留原有处理。

LoadingState 的首次加载与手动重试共享同一尝试流程，每次尝试持有 RequestScope；替换/卸载取消，结果与 onDataLoaded 完成后验证当前尝试身份。loadData/onDataLoaded 显式接收作用域，业务回调必须在 await 后先检查取消再发布副作用；不得恢复重复的未受控 then/setState 路径。
