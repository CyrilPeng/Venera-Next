# Async BuildContext audit

2026-10-03, local working-tree flutter analyze including existing user edits. Enabling the rule exposed 85 diagnostics; import presentation resolved 21 and comment views resolved 8 and source-page flows resolved 8, leaving 48. The rule is currently info and will be raised to warning after all findings are resolved. These are outstanding work, not exemptions. The other existing 23 infos remain unchanged.

| File | Remaining diagnostics |
|---|---:|
| `lib/app_runtime/init.dart` | 1 |
| `lib/app_runtime/sync_window_binding.dart` | 1 |
| `lib/components/rich_comment_content.dart` | 1 |
| `lib/features/comic_details/actions.dart` | 7 |
| `lib/features/comic_details/comic_page.dart` | 1 |
| `lib/features/comic_details/favorite.dart` | 7 |
| `lib/features/favorites/favorite_actions.dart` | 3 |
| `lib/features/favorites/network_favorites_page.dart` | 9 |
| `lib/features/history/history_page.dart` | 2 |
| `lib/features/image_favorites/image_favorites_summary.dart` | 1 |
| `lib/features/local_comics/local_comics_page.dart` | 3 |
| `lib/features/reader/gesture.dart` | 2 |
| `lib/features/settings/app.dart` | 9 |
| `lib/features/settings/local_favorites.dart` | 1 |

Resolution: page-owned work checks the matching context.mounted/State.mounted, including failure/finally/resource cleanup. App-owned work resolves an available current root when presenting UI, without relabelling completed work as failed after an old page disappears. Do not silence findings with global ignores, dynamic casts or unchecked helper functions. The gesture file contains user edits and requires selective staging. Recheck diagnostics and behavior each stage. Logs: output/context-lint-baseline.log and output/source-login-final-analyze.log.
