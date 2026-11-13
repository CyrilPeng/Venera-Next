# Two-Level Local Favorite Folders

> Two-level folders shipped in `v1.18.2+243` for #123; parent-back navigation and clickable paths shipped in `v1.18.3+249`. The new selection entry and in-page subfolder sorting are available for testing in `v1.18.4-rc.1+250` (#152, #155).

Local favorites support at most two levels. Both root folders and child folders can contain comics directly. Network favorites remain managed by their comic sources. Folder names must still be globally unique, even under different parents.

## Upgrading And Importing Older Data

- Before upgrading, export and keep a separate complete app-data backup from Settings > App > Data, and keep your original comic files.
- Before the first database migration, the app saves an independent copy of the old database in a `.favorite_hierarchy_backup_*` directory under the data directory. A snapshot or migration failure stops initialization without clearing favorites.
- Existing folders become root folders. Their names, effective order, comics, network-favorite links, and update-tracking records are retained. No automatic categorization or comic relocation occurs.
- Characters such as `/` in an existing name remain part of that name; they do not create a hierarchy.
- Restoring an older complete backup also makes its folders roots. Importing a legacy single-folder JSON always creates a root folder, regardless of the parent currently selected in the creation dialog. Duplicate names receive a numeric suffix rather than replacing an existing folder.
- Invalid or unsupported new-format hierarchy metadata is rejected before import, rather than clearing or flattening folders to bypass the error.

## Browsing And Selecting Folders

In the favorites sidebar, select a folder name to open it. Use the separate arrow to expand or collapse its children. Search matches folder names and `Parent / Child` paths; clearing search does not change the saved hierarchy.

Back in a child folder first exits search or multi-selection, then opens its parent. Root folders and All retain the existing app-back behavior. An open folder picker or other dialog closes first. Select the parent name in the toolbar path to jump directly; a full-size parent button replaces that label in narrow titles, with the complete name available in its tooltip. The current label can still open the picker on narrow screens. A `/` inside a name is text, not another hierarchy level. The resulting folder selection is saved and restored after restart.

A root folder page provides links to its children, but its comic list and count show **direct favorites only**, not an aggregate of child contents. Comic search, reading-status filters, and blocked keywords continue to apply to the current comic list. All includes favorites from both levels and deduplicates comic identities. A comic can still belong to multiple folders.

Comic-detail favorites, bulk add/transfer, Quick Favorite settings, and update-tracking selection share a searchable folder picker. It displays paths while retaining the original folder reference. Parents and children can be selected separately. Quick Favorite also supports None.

In the unreleased version, the comic-detail favorite panel lets local folders use the full available height and scrolls local and network favorites together. New Folder stays in the fixed toolbar on the right while folders scroll. The Local favorites first setting still determines section order (#157).

On TV, use direction keys to move focus and Select to activate a folder or its separate expansion arrow. Back closes the picker and returns focus to its opening control. In folder search, Up/Down leave text input while Left/Right still edit the caret. Sorting offers Move up/Move down buttons without dragging. These controls do not change TV's separate data or low-memory policy; an actual device's input method may still require a companion input device.

## Bulk Actions (v1.18.4-rc.1)

Use Select comics in the favorites toolbar on wide screens or in the More menu on narrow screens. The existing long-press entry also remains available. Once selection mode is open, click comics to select them; the More menu offers Select All, Invert Selection, and move, copy, delete, and download actions for the current selection.

Select All, inversion, and long-press range selection include only comics visible under the current search, reading-status filter, and blocked-keyword rules. They exclude subfolders and their contents. Empty selections offer selection controls only. Bulk deletion first confirms the number of comics; cancelling keeps favorites, and confirmation removes only those favorite records from the current folder. Back or Cancel exits selection, and switching folders clears it.

The unreleased version puts Select All, Invert Selection, and Deselect directly in the toolbar when there is enough space, retaining the More menu on narrow screens. On desktop, Escape closes a dialog first, then exits selection. If search is also active, the query remains after selection ends; a second Escape exits search and restores the full list (#152).

## Creating, Moving And Sorting

- New Folder lets you choose First-level folder or a root folder as the parent. A root folder's menu also offers Create subfolder. A child cannot have another level beneath it.
- Move folder changes ancestry only. Comics and folder names stay in place, as do Quick Favorite, Read Later, update-tracking, and network-favorite references.
- A root without children can move under another root. A child can change parents or return to the root level. A root with children cannot move under another folder, preventing a third level.
- Sidebar Sort defaults to root folders; choose a parent to sort its children. The new Sort subfolders action in the folder page's More menu opens the current parent's children directly. Reorder comics affects only comics directly in that folder, keeping folder and comic ordering separate. Folder sorting supports dragging and Move up/Move down buttons; closing the window saves the order while retaining folder IDs, ancestry, and comic contents.
- A root with children cannot be deleted directly. Move or delete its children first. Deleting a folder removes its favorite records, not the original comic files or membership in other folders.

## Backups And Synchronization

| Method | Preserved data |
|---|---|
| Complete app-data export/import | Stable folder IDs, both levels, sibling order, direct contents, and links; settings follow existing import rules |
| WebDAV app-data synchronization | Complete favorites database snapshots retain hierarchy; setting exclusions still apply, with no multi-device folder conflict merge |
| Single-folder JSON export/import | Legacy format containing only direct favorites; imports create a new root folder without ancestry |

When a root has children, its export menu explicitly says Export this folder only (no subfolders). Use a complete app-data backup to preserve an entire tree. A single-folder JSON is not a tree backup. Complete app-data backups do not contain local comic images; keep those files separately.

**Do not alternate old and new versions against the same favorites database or WebDAV data.** Older versions do not understand hierarchy metadata and may damage relationships when editing folder order. All synchronizing devices should use a version supporting this feature. Before downgrading, keep a separate copy of the new data and restore a pre-upgrade backup; compatibility with data modified by newer versions is not guaranteed.

See [App-data synchronization](data_sync.en.md) for synchronization settings.
