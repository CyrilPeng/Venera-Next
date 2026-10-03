# 异步页面上下文检查清单

2026-10-03，基于本机工作区（含用户未提交改动）的 flutter analyze。启用规则后初始 85 处，导入流程修复 21 处、评论视图修复 8 处、漫画源页面修复 8 处、本地库页面修复 3 处、同步窗口绑定修复 1 处，历史页面修复 2 处，剩余 42 处。当前规则为 info，全部消除后再提升为 warning；这些条目是未完成工作，不是豁免。原有其他 23 个 info 保持不变。

| 文件 | 剩余诊断 |
|---|---:|
| `lib/app_runtime/init.dart` | 1 |
| `lib/components/rich_comment_content.dart` | 1 |
| `lib/features/comic_details/actions.dart` | 7 |
| `lib/features/comic_details/comic_page.dart` | 1 |
| `lib/features/comic_details/favorite.dart` | 7 |
| `lib/features/favorites/favorite_actions.dart` | 3 |
| `lib/features/favorites/network_favorites_page.dart` | 9 |
| `lib/features/image_favorites/image_favorites_summary.dart` | 1 |
| `lib/features/reader/gesture.dart` | 2 |
| `lib/features/settings/app.dart` | 9 |
| `lib/features/settings/local_favorites.dart` | 1 |

处理原则：页面任务使用对应 context.mounted/State.mounted，并检查失败、finally 和资源释放；应用级任务在展示时取得当前可用根页面，不因原页面卸载误报任务失败。禁止靠全局屏蔽、dynamic 或移动到未检查辅助函数消除诊断。手势文件含用户修改，修复时选择性暂存。每阶段重新生成诊断并补行为回归。日志 output/context-lint-baseline.log 与 output/history-refresh-final-analyze.log。
