# Source repositories

中文：[漫画源与源仓库](source_repositories.zh.md)

The Comic Source page has two tabs: **Installed** and **Source repositories**. A source is a script that connects the reader to a comic service. A repository is a catalog of source scripts. You can save multiple repositories.

## Add and install

Open **Source repositories → Add repository**, enter a recognizable name and a complete source list URL (usually `index.json`), then save. The app validates the address and catalog before saving. Errors preserve your input; cancel discards the edits.

Choose **Browse sources** to search a repository and install a source. Use **Install from link** or **Import source file** in the Installed tab for individual scripts. A catalog URL belongs in the repository editor.

## Install several sources

After choosing **Install source**, you can immediately install another source, search, refresh, or switch repositories. Progress stays in the source row instead of opening a blocking dialog.

- Up to three sources download at once. Additional tasks wait for a download slot; downloaded scripts install one at a time. Download percentages appear when the server provides a total size.
- **Installation tasks** at the top of source management and catalog pages lists this session's tasks, origins, and full failure details. Finished records can be cleared.
- Cancel queued, downloading, or waiting-to-install tasks. An installation that is already committing finishes first. Retry individual failures without affecting other tasks.
- Tasks continue when you close a catalog or leave source management. Quitting the app ends unfinished tasks; start them again after relaunching.
- A source already being installed displays the same task in other repositories. If its repository is removed or its URL changes, reopen the catalog and start a new installation.
- Link installs and file imports use the same task list. Successful installs save their origin and register their search and explore entries automatically.

## Origins and updates

An installed source displays its origin. Click that label or choose **Manage source origin** to link a saved repository and select a matching entry.

- Repository installs are linked automatically. Version checks and update downloads use the corresponding entry in that same repository.
- A source is installed once, even if multiple repositories provide it. **Use this repository** changes its future update origin, keeping the current script and settings until the next update.
- Older sources without reliable origin records display **No repository linked**. Manual installs display their installation method.
- Sources without a linked, saved repository are excluded from catalog version checks. Their individual Update action can still use the update URL declared by the script.
- A linked source can use **Remove repository link** in **Manage source origin**. The script and settings are kept, and later updates use the URL declared by the script.
- Checks report checked and skipped counts, plus repository failures. A failed repository does not prevent checking others.
- If a source disappears from its catalog or its variant becomes ambiguous, select its origin again.
- Invalid catalog entries are skipped and reported above the list. The repository stays browsable and saveable while at least one entry is usable; saving is rejected only when every entry is invalid.

Source settings and accounts remain available by expanding the source in the Installed tab.

## Edit, remove and migrate

Repository menus allow editing names and URLs, or removing a repository. Changing a URL changes the update location for linked sources. Refresh reloads the saved catalog address.

Removing a repository keeps its installed sources, settings and reading data. They show **Repository removed** and can be linked elsewhere. Uninstalling a source is a separate action.

On upgrade, the previously saved single catalog URL becomes one repository. Existing source scripts remain installed. Repository records and source origins are stored in the application's `appdata.json` and use the existing backup and synchronization mechanisms.
