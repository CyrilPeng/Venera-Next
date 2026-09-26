<div align="center">
  <a href="README.md">简体中文</a> | <strong>English</strong>

  <br>
  <img src="assets/readme_logo.png" alt="VeneraNext" width="200" />

  # VeneraNext

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![Release](https://img.shields.io/github/v/release/CyrilPeng/venera-next?label=Release&color=10B981&style=flat-square)](https://github.com/CyrilPeng/venera-next/releases)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
  <br>
  [![Downloads](https://img.shields.io/github/downloads/CyrilPeng/venera-next/total?style=flat-square&color=2ea44f&logo=github)](https://tooomm.github.io/github-release-stats/?user=CyrilPeng&repo=venera-next)
  [![Afdian](https://img.shields.io/badge/Afdian-Sponsor-ff69b4?style=flat-square)](https://ifdian.net/a/cyril)

</div>

<!-- featured-sponsors:start -->
<!-- featured-sponsors:end -->

---

## Contents

- [Introduction](#introduction)
- [Highlights](#highlights)
- [Download and installation](#download-and-installation)
- [Quick start](#quick-start)
- [Usage guide](#usage-guide)
- [Developing comic sources](#developing-comic-sources)
- [FAQ](#faq)
- [Developer resources](#developer-resources)
- [Statement](#statement)
- [Sponsors](#sponsors)
- [Acknowledgements](#acknowledgements)
- [License](#license)

---

## Introduction

[VeneraNext](https://github.com/CyrilPeng/venera-next) continues development of [Venera](https://github.com/venera-app/venera), a Flutter comic reader for **Android, iOS, Windows, Linux, and macOS**.

This fork focuses on fewer interruptions while reading: scroll across chapters, split wide spreads for vertical reading, and adjust the reader for nighttime or E-Ink devices. Read Later, update tracking, offline downloads, reading statistics, and synchronization connect the rest of the reading workflow.

Venera's JavaScript extensions, local reading, search and categories, favorites, downloads, and source-dependent login, comments, and ratings remain available.

**Quick links:** [Install](#download-and-installation) · [Usage](#usage-guide) · [Write a source](doc/api/comic_source.en.md) · [JavaScript API](doc/api/js.en.md) · [Changelog](CHANGELOG.md)

> [!IMPORTANT]
> This repository maintains the reader and extension runtime. It does not provide, bundle, host, or recommend comic sources. Users must configure legal extensions themselves; content and availability depend on the corresponding extension and service.

<div align="center">
  <a href="https://github.com/CyrilPeng/venera-next">GitHub repository</a> ·
  <a href="https://gitee.com/CyrilPeng/venera-next">Gitee mirror</a>
</div>

---

## Highlights

### Improvements in this fork

These features are included in stable releases through **v1.16.0**. See the [changelog](CHANGELOG.md) for individual releases.

| Improvement | What it adds |
|---|---|
| **Waterfall reading across chapters** | The default mode preloads the next chapter near the boundary. Keep scrolling or return to a loaded previous chapter; chapter separators and history follow the actual reading position. |
| **Split wide spreads vertically** | Stack the two halves of a wide image in vertical Continuous and Waterfall modes, with an option to swap their order. Original image counts and progress are preserved. |
| **Night dimming** | An independent reader toggle and 20%–100% brightness control in reader settings and the bottom quick panel, alongside the app's light and dark themes. |
| **E-Ink refresh** | Flash after a configurable number of Gallery page changes, with adjustable duration and black, white, or white-then-black styles to help reduce ghosting. |
| **Clearer comic details** | Consistent two-row actions on desktop and mobile emphasize Download, Read, and Continue, with chapter progress, update indicators, and a saved chapter sort preference. |
| **Read Later and update tracking** | Keep titles you want to start separate from ongoing series. The home page provides the reading queue, followed-cover previews, and update indicators. |
| **Favorites and discovery shortcuts** | Browse favorites in a cover gallery with automatic or 2–6 columns, save author/tag searches, and view saved images in a gallery for each comic. |
| **Reading statistics** | Track active foreground reading time and view totals, comic counts, and rankings from History or Settings. |
| **Expanded local library** | Import image folders, CBZ/ZIP/7Z/CB7, PDF, and image-based EPUB; support chapter folders, natural sorting, batch PDF import, CBZ export, and recovery. |
| **WebDAV library and archives** | Read NAS/WebDAV image folders with directory caching, incremental synchronization, and metadata support; back up local comics as CBZ archives and restore them separately. |
| **Data and desktop improvements** | Atomic settings writes and recovery, sync status and errors, history cleanup, and Windows installers, portable packages, and winget updates. |

### New changes on the main branch

The following changes are merged into the current main branch and remain in the [Unreleased section](CHANGELOG.md#未发布). **They are not part of stable v1.16.0.**

- **Automatic reader mode:** recognize page comics and webtoons from original image proportions and apply separate mode preferences. Off by default; a manual per-comic choice takes priority. [Guide](doc/user/automatic_reader_mode.en.md)
- **Automatic reading and long-press actions:** timed page turns or smooth/stepped scrolling across all seven modes, with optional chapter transitions. Touch, zoom, settings, and background state pause advancement.
- **Background PDF import:** keep reading after hiding progress, then use the PDF task button in Local to check progress, cancel, or review results. Batches run sequentially and require the app to remain running. [Import guide](doc/user/import_comic.en.md#pdf)
- **Unified import and multiple repositories:** preview scripts or catalogs from links, pasted content, or JS/JSON files; select entries, save online repositories, and manage background installation, cancellation, retries, and origins. [Source repositories](doc/user/source_repositories.en.md)
- **Update checks and source debugging:** rate-limit follow checks per source and stop previous runs on cancellation; save and reload source edits while preserving a working source on failure, and inspect asynchronous evaluator results. [Local debugging](doc/development/source_debugging.en.md)

### Core Venera capabilities retained

- **Extensible sources:** use JavaScript to provide search, aggregate search, exploration pages, categories, rankings, and tag translation.
- **Flexible reading:** Gallery pagination, scrolling within a chapter, zoom, and multi-image layouts, with touch, keyboard, and mobile volume-key controls.
- **Favorites and offline access:** local and network favorites, history, saved images, and a download queue; read downloaded chapters offline.
- **Source-dependent interaction:** accounts, cookies, comments and replies, chapter comments, likes, and ratings where implemented by the extension.
- **Multiple devices:** WebDAV app-data synchronization, import/export, and [headless commands](doc/user/headless.en.md) for scripting.

---

## Download and installation

### Android

Download an APK from [GitHub Releases](https://github.com/CyrilPeng/Venera-Next/releases):

| File | Description | Recommended for |
|---|---|---|
| `VeneraNext-xxx-android.apk` | Universal build | Most Android devices |
| `VeneraNext-xxx-android-arm64-v8a.apk` | ARM64 build | Android devices that support ARM64 apps |
| `VeneraNext-xxx-android-armeabi-v7a.apk` | ARM32 build | Older 32-bit devices |

When in doubt, use the universal `VeneraNext-xxx-android.apk` package.

### iOS

Download the IPA from GitHub Releases and sideload it with AltStore.

### Windows

winget is recommended because the same package ID can be used for future upgrades:

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
```

You can also download `VeneraNext-xxx-windows-installer.exe` or the portable ZIP from GitHub Releases. Portable builds are not managed by winget and must be updated manually. New winget versions may appear later than GitHub Releases because Microsoft reviews manifest updates; run `winget source update` before checking again.

See [Windows Distribution](doc/distribution/windows.en.md) for installer, portable build, and winget maintenance details.

### Linux

Download `venera-next_xxx_amd64.deb` or the AppImage from GitHub Releases.

### macOS

Download `VeneraNext-xxx.dmg` from GitHub Releases.

---

## Quick start

1. Install the appropriate build from [Releases](https://github.com/CyrilPeng/venera-next/releases).
2. Choose a channel: use Local → Import for existing images, archives, or image documents; install a compatible extension for network reading; configure Settings → App → WebDAV Comic Library for a NAS.
3. Choose a mode in Settings → Reader. Waterfall is the default for long series; Gallery turns pages; Continuous scrolls within the current chapter.
4. Adjust split spreads, night dimming, or E-Ink refresh for your device. Enable device-specific or per-comic settings when needed.
5. Use Read/Continue or select a chapter. Put titles you will start later in Read Later, and ongoing series in the folder used for update tracking.
6. Download chapters for offline use. Configure data sync, comic archives, or the online library according to your cross-device needs.

## Usage guide

### Reading modes and progress

| Mode | Directions | Suitable for |
|---|---|---|
| Waterfall | Top to bottom | Continuous reading across chapters, loading adjacent chapters near boundaries |
| Gallery | Left to right, right to left, top to bottom | Page turns, with configurable multi-image layouts |
| Continuous | Left to right, right to left, top to bottom | Scrolling inside the current chapter with explicit chapter boundaries |

- **Preloading:** Waterfall reuses the image preload count. Larger values may load content earlier and increase network and memory use.
- **Split wide images:** available in vertical Continuous and Waterfall only. Swap the split order if needed; page counts still refer to original images.
- **Resume:** history stores chapter, page, and chapter group. Waterfall records the chapter actually being read. Ascending/descending on the details page only changes the chapter list display.
- **Setting scope:** ordinary reader settings fall back from enabled per-comic settings to enabled device settings and then global settings. The main branch also has an independent manual per-comic mode override.
- **Automatic mode recognition (main branch):** off by default and based on body-image proportions rather than source declarations. Switching preserves the chapter and original image position, but not the exact pixel offset inside an image. [Details](doc/user/automatic_reader_mode.en.md)

### Nighttime and E-Ink reading

Choose a light, dark, or system theme in Settings → Appearance. **Night dimming** independently darkens the comic in the reader: enable it in reader settings or the bottom quick panel and adjust brightness from 20% to 100%. This changes the in-app image, not the device's system brightness.

For E-Ink devices, choose **Gallery mode** and enable E-Ink display refresh. Set a flash every 1–10 page changes, a duration of 100–1500 ms, and a black, white, or white-then-black style. This is a flash drawn by the reader; results depend on the device's own refresh behavior. Continuous and Waterfall do not trigger it.

### Automatic reading and gestures (main branch)

Gallery turns pages at the configured interval. Continuous and Waterfall can scroll smoothly at 10–1000 pixels/second or in steps at 1–10 steps/second and 10–500 pixels/step. Optional automatic chapter transitions wait until a long image has been scrolled to its end.

Touch, zoom, settings panels, and background state pause advancement. Loading failures or reaching the end of the final chapter stop it. Long press can zoom, start/stop automatic reading, or do nothing; previous zoom preferences are preserved.

### Comic details, Read Later, and update tracking

- **Details:** common interactions and the Download/Read buttons occupy separate rows. Continue, chapter progress, update indicators, and a remembered ascending/descending choice make returning to a comic easier.
- **Read Later:** add/remove a title from comic details or the local-comic menu and open the full list from Home. Reading does not automatically remove it. Its separate local favorites folder can be renamed, deleted, and synchronized.
- **Update tracking:** checks comics in the selected local favorites folder. Home shows covers and update counts. The default quick-favorite target can be the follow folder; existing valid preferences and an explicit disabled state are preserved. Long-press Favorite on the details page for quick favorite.
- **Update detection:** relies on a valid update date supplied by comic details. An additional chapter alone does not guarantee detection. Update indicators can be disabled in Settings.
- **Authors and tags:** save searchable author/tag targets as shortcuts on the search page. A shortcut stores search criteria; it does not automatically follow every work by an author.

### Favorites, images, and reading statistics

Local favorites are managed by the app; network favorites depend on the source account and extension. The cover gallery supports automatic or 2–6 column layouts, and saved images can be browsed in a gallery for each comic.

History stores reading position and active foreground time, with totals, comic counts, and time rankings. Settings also links to reading statistics. History can be cleaned by retention period. Leaving the reader or entering the background records the corresponding active reading period.

### Local comics and offline downloads

| Content | Import and reading behavior |
|---|---|
| Image folders | Single or batch imports, including chapter subfolders; optional covers and natural filename ordering |
| CBZ / ZIP / 7Z / CB7 | Extract into the local library, including archives with a top-level folder and chapter subfolders |
| PDF | Sequential multi-file import with progress and cancellation; render pages to local JPEGs and use the first page as the cover |
| Image-based EPUB | Extract raster images in spine order and retain title, author, cover, and usable chapter navigation where possible |
| Source downloads | Store downloaded chapters in the local library for offline reading, later export, and archival |

CBZ export, scanning to recover downloads, chapter deletion, and storage migration are available. PDF/EPUB imports consume additional storage. Text-only EPUB, directly drawn SVG pages, encrypted PDF, and MOBI/AZW/AZW3 are unsupported.

See [local import, CBZ, and WebDAV library rules](doc/user/import_comic.en.md) for folder examples, archive compatibility, and metadata templates.

### Network comic extensions

User-installed JavaScript extensions provide network content. Search, exploration, categories, accounts, favorites, and comment capabilities vary by extension.

On the main branch, use Comic Source → Add source: paste a script/catalog URL or content, or choose a JS/JSON file, then preview and install. Online catalogs can be saved as repositories, and installed sources can link, switch, or unlink update origins. Stable v1.16.0 uses the previous link/file and single-catalog interfaces.

See [source repositories](doc/user/source_repositories.en.md) for installation tasks, updates, and migration. To write an extension, start with [Developing comic sources](#developing-comic-sources).

### WebDAV data sync, archives, and online library

These are configured separately:

| Capability | Entry in Settings → App | Purpose |
|---|---|---|
| App-data synchronization | Data Sync | Synchronize settings, favorites, history, cookies, and source files; local comic images are excluded |
| Comic archives | Comic Archive Backup | Upload local comics as CBZ archives or download archives into the local library |
| Online library | WebDAV Comic Library | Load remote image folders on demand and cache directory information and images |

The online library accepts ordinary image folders, chapter folders, and extracted CBZ exports from VeneraNext. Valid `metadata.json` can supply title, author, tags, chapter page ranges, and identify comic roots in nested folders. Invalid metadata falls back to ordinary folder detection.

The shelf displays cached entries first and checks remote changes incrementally. Manual synchronization and an automatic update interval are available. Remote CBZ/ZIP/7Z/CB7 files cannot be previewed directly: extract them on the server, or restore an archive for local reading. [Folder and metadata rules](doc/user/import_comic.en.md#webdav-online-library)

## Developing comic sources

**Start here when writing a third-party extension:**

| Document | Contents |
|---|---|
| [Comic Source Guide](doc/api/comic_source.en.md) | Minimal example, search/details/chapter contracts, image requests, optional capabilities, and repository publishing |
| [Minimal source template](doc/examples/minimal_source.js) | Copyable JS file demonstrating the full loading flow with a fictional API |
| [JavaScript API](doc/api/js.en.md) | Network, HTML parsing, source storage, UI, image processing, and runtime limits |
| [Local Source Debugging](doc/development/source_debugging.en.md) | Import, edit, reload, JS Evaluator, logs, and cancellation boundaries |
| [Source repositories](doc/user/source_repositories.en.md) | Installation queue, origins, updates, and legacy configuration migration |

Chinese editions: [漫画源编写指南](doc/api/comic_source.zh.md) · [JavaScript API](doc/api/js.zh.md) · [本地调试](doc/development/source_debugging.zh.md).

This fork continues to maintain Venera-compatible extension interfaces. Waterfall, split spreads, night dimming, and automatic reading are reader responsibilities. Extensions supply stable comic/chapter IDs, correctly ordered chapters and images, and valid update dates; they do not need separate rules for every reader mode.

## FAQ

### Does VeneraNext include comic sources?

No source or recommended catalog is bundled. Import local comics or configure a legal compatible extension or WebDAV library.

### Why are some buttons mentioned here missing?

Check your version in About. Features marked “main branch” remain unreleased and are not in stable v1.16.0. Accounts, comments, ratings, and similar capabilities also require implementation by the source.

### Why are searches, images, or update indicators missing?

Check the extension, login/cookies, service availability, and network. Update tracking additionally requires a valid update date. Contact the relevant maintainer for site/content issues. Reader or extension-runtime problems reproducible independently of a particular site can be reported under the [contribution guidelines](CONTRIBUTING.en.md).

### How do I update on Windows?

Run `winget upgrade --id CyrilPeng.VeneraNext --exact`. Public-source availability may lag behind GitHub Release; try `winget source update` first. Portable installations require downloading and applying an update manually.

## Developer resources

- [Build and Development](doc/development/build.en.md): Flutter/Rust, locked dependencies, tests, and releases.
- [Contributing](CONTRIBUTING.en.md) · [Project Structure](doc/architecture/project_structure.en.md) · [Dependency Governance](doc/development/dependencies.en.md).
- [Windows Distribution](doc/distribution/windows.en.md) · [Headless Mode](doc/user/headless.en.md).
- [Security Policy](SECURITY.md) · [Code of Conduct](CODE_OF_CONDUCT.md) · [Documentation Index](doc/README.en.md).

---

## Star history

<a href="https://www.star-history.com/?repos=CyrilPeng%2Fvenera-next&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&theme=dark&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=CyrilPeng/venera-next&type=date&legend=top-left&sealed_token=2JdfPV5RItrAVJNxNXhSHVr6mVbj9H_y_YMHJio2smj8uoRHGQKgrtY9k0PmbxUf6q0P-dR90ZWZSKlDDaygMd90LT7F0xI-2Bbtiq5muew1iXUSEFJzfouyqu70BiWT-hUeD9BKbFsdVr1knEJDWBqAArkJYIJcJCOYLZ5rUdpFdQ2aBIhT8wTQnOED" />
 </picture>
</a>

---

## Statement

This repository maintains the VeneraNext comic reader itself. It **does not provide, bundle, host, or recommend any comic source and does not handle source-site content**.

Network reading uses extensions compatible with the JavaScript API. Users are responsible for configuring legal extensions. Search results, chapter loading, image availability, and content copyright depend on the corresponding source site and extension implementation.

**Do not submit issues about comic sources, source-site content, specific title availability, or copyright. Such reports will be closed.**

---

## Sponsors

VeneraNext is maintained as a personal-interest project and is not operated for profit. If it helps with your daily reading, you can support ongoing maintenance through [Afdian](https://ifdian.net/a/cyril).

Sponsorship status is synchronized periodically through the Afdian API. To request public acknowledgement, put `公开昵称：Your name` in the order remark. Orders without an explicit public name are not displayed.

See [SPONSORS.md](SPONSORS.md) for the sponsor list and display policy.

---

## Acknowledgements

Thanks to [Venera](https://github.com/venera-app/venera) for the reader and extension foundation, and [EhTagTranslation](https://github.com/EhTagTranslation/Database) for Chinese tag translations. Thanks also to all contributors and sponsors.

## License

This project is licensed under GPL-3.0.

---

## Community Links

- [LINUX DO](https://linux.do/)
