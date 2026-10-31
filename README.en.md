<div align="center">
  <a href="README.md">简体中文</a> | <strong>English</strong>

  <br>
  <img src="assets/readme_logo.png" alt="VeneraNext" width="200" />

  # VeneraNext

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![Release](https://img.shields.io/github/v/release/CyrilPeng/venera-next?label=Release&color=10B981&style=flat-square)](https://github.com/CyrilPeng/venera-next/releases/latest)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
  <br>
  [![Downloads](https://img.shields.io/github/downloads/CyrilPeng/venera-next/total?style=flat-square&color=2ea44f&logo=github)](https://tooomm.github.io/github-release-stats/?user=CyrilPeng&repo=venera-next)
  [![Afdian](https://img.shields.io/badge/Afdian-Sponsor-ff69b4?style=flat-square)](https://ifdian.net/a/cyril)

  <a href="https://trendshift.io/repositories/140830?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-140830" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/140830" alt="VeneraNext repository badge on Trendshift" width="250" height="55" /></a>
  <a href="https://trendshift.io/repositories/140830?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-140830" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/140830/daily?language=Dart" alt="VeneraNext daily Dart ranking on Trendshift" width="250" height="55" /></a>

</div>

<!-- featured-sponsors:start -->
<!-- featured-sponsors:end -->

---

## Introduction

[VeneraNext](https://github.com/CyrilPeng/venera-next) continues development of [Venera](https://github.com/venera-app/venera), a Flutter comic reader for **Android, Android TV, iOS, Windows, Linux, and macOS**.

This fork focuses on fewer interruptions and more reading: Waterfall mode scrolls across chapters without leaving the reader, long-pressing Favorite skips the folder picker, and nighttime and E-Ink devices get their own reading adjustments. Local import, offline downloads, reading statistics, and multi-device sync make finding comics, reading them, and following ongoing series easier.

Venera's JavaScript extensions, local reading, search and categories, favorites, downloads, and source-dependent login, comments, and ratings remain available.

**Quick links:** [Install](#download-and-installation) · [Usage](#usage-guide) · [Write a source](doc/api/comic_source.en.md) · [JavaScript API](doc/api/js.en.md) · [Changelog](CHANGELOG.md)

> [!IMPORTANT]
> This repository maintains the reader and extension runtime. It does not provide, bundle, host, or recommend comic sources. Users must configure legal extensions themselves; content and availability depend on the corresponding extension and service.

<div align="center">
  <a href="https://github.com/CyrilPeng/Venera-Next">
    <img alt="GitHub main repository" src="https://img.shields.io/badge/GitHub-Main_repository-181717?style=for-the-badge&logo=github&logoColor=white" />
  </a>
  <a href="https://gitee.com/CyrilPeng/venera-next">
    <img alt="Gitee China mirror" src="https://img.shields.io/badge/Gitee-China_mirror-C71D23?style=for-the-badge&logo=gitee&logoColor=white" />
  </a>
</div>

---

## Screenshots

| Home: history, Read Later, and update tracking | Comic details |
|---|---|
| <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Home.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Home.jpg" alt="VeneraNext home page with reading history, Read Later, and update tracking" width="100%" /></a> | <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Details.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Details.jpg" alt="VeneraNext comic details page with reading actions, comic information, and chapters" width="100%" /></a> |

---

## Highlights

### Track updates with one long-press

With the default settings, **long-press Favorite** on a comic's details page to add it straight to the Follow Updates folder, without opening the folder picker. The app checks for updates automatically and shows update counts and comic covers on Home. Tap a cover to open the details page, then choose Read or Continue to start reading.

A fresh install creates this folder automatically (named "追更" by default). To change the quick-favorite or update-tracking folder, see [Favorites, Read Later, and update tracking](#favorites-read-later-and-update-tracking).

### Reading experience

- **Waterfall reading across chapters (non-TV default)**: finish a chapter and keep going — the next chapter loads automatically near the end, and you can scroll back to a previously loaded chapter. Progress is recorded where you actually stopped.
- **Android TV and boxes**: a separate TV package with a landscape launcher, directional remote navigation, visible focus, and single-page low-memory reading by default. It can coexist with the mobile app.
- **Split wide spreads vertically**: two-page spreads too small on a phone? Enable split double pages in vertical Continuous/Waterfall modes to stack the two halves, and swap their order to match the reading direction.
- **Night dimming**: dim the comic inside the reader for nighttime reading, without changing the system brightness.
- **E-Ink refresh**: Gallery mode can flash the screen at a page-turn interval to help reduce ghosting, with adjustable intervals and styles.
- **A handier details page**: Download and Read/Continue are easier to find, chapter progress and update indicators are visible at a glance, and your last chapter sort choice is remembered.

### Discovery, favorites, and data

- **Read Later**: keep comics you plan to read in their own list, ready to find on Home.
- **Local library**: import image folders, CBZ/ZIP/7Z/CB7, PDF, and image-based EPUB and read them right away, with chapter subfolders and natural sorting; local comics can also be exported as CBZ.
- **WebDAV: sync, backup, and NAS reading**: sync settings, favorites, and reading progress across devices, back up local comics, or read NAS image folders online. Each feature is configured separately.
- **Reading statistics**: track the time you spend reading; History shows total time, comics read, and time rankings.
- **Favorites gallery and search shortcuts**: switch favorites to a cover gallery, save frequent author/tag searches as shortcuts, and browse saved images per comic.

### Core Venera capabilities retained

- **Extensible sources:** use JavaScript to provide search, aggregate search, exploration pages, categories, rankings, and tag translation.
- **Flexible reading:** Gallery pagination, scrolling within a chapter, zoom, and multi-image layouts, with touch, keyboard, and mobile volume-key controls.
- **Favorites and offline access:** local and network favorites, history, saved images, and a download queue; read downloaded chapters offline.
- **Source-dependent interaction:** accounts, cookies, comments and replies, likes, and ratings where implemented by the extension.
- **Multiple devices:** WebDAV app-data synchronization, import/export, and [headless commands](doc/user/headless.en.md) for scripting.

---

## Download and installation

### Android phones and tablets

Download an APK from the [latest stable release](https://github.com/CyrilPeng/Venera-Next/releases/latest):

| File | Description | Recommended for |
|---|---|---|
| `VeneraNext-xxx-android.apk` | Universal build | Most Android devices |
| `VeneraNext-xxx-android-arm64-v8a.apk` | ARM64 build | Android devices that support ARM64 apps |
| `VeneraNext-xxx-android-armeabi-v7a.apk` | ARM32 build | Older 32-bit devices |
| `VeneraNext-xxx-android-x86_64.apk` | x86_64 build | x86_64 devices or emulators |

When in doubt, use the universal `VeneraNext-xxx-android.apk` package.

### Android TV

TV support has completed small-scale testing and is integrated into the main branch. Future builds and releases include both mobile and TV packages. Choose a version with TV assets on the [Releases page](https://github.com/CyrilPeng/venera-next/releases):

| File | Description |
|---|---|
| `VeneraNext-xxx-android-tv.apk` | Universal TV build; recommended when the device ABI is unknown |
| `VeneraNext-xxx-android-tv-arm64-v8a.apk` | TV ARM64 build; requires an OS that supports ARM64 apps |
| `VeneraNext-xxx-android-tv-armeabi-v7a.apk` | TV ARM32 build for 32-bit TV or box systems |
| `VeneraNext-xxx-android-tv-x86_64.apk` | TV x86_64 build for matching devices or emulators |

Transfer the APK to the TV and sideload it; its launcher name is **VeneraNext TV**. The separate `.tv` package and data directory do not replace the mobile app. Existing official TV Alpha installations can upgrade in place with the new TV package. Export a separate backup first; uninstalling or clearing data is not required.

> TV packages start with builds after this mainline integration. Published `v1.18.1` and `v1.18.2-rc.6` releases do not contain TV APKs and will not be backfilled. An update notification opens the matching release page; choose an `android-tv` APK, not a mobile package.

See [TV remote controls and low-memory reading](#tv-remote-controls-and-low-memory-reading) for usage and [Android TV Distribution](doc/distribution/android_tv.en.md) for builds, upgrade rules, and compatibility limits.

### iOS

Download the IPA from the [latest stable release](https://github.com/CyrilPeng/Venera-Next/releases/latest) and sideload it with AltStore.

### Windows

winget is recommended because the same package ID can be used for future upgrades:

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
```

You can also download `VeneraNext-xxx-windows-installer.exe` or the portable ZIP from the [latest stable release](https://github.com/CyrilPeng/Venera-Next/releases/latest). Portable builds are not managed by winget and must be updated manually. New winget versions may appear later than GitHub Releases because Microsoft reviews manifest updates; run `winget source update` before checking again.

See [Windows Distribution](doc/distribution/windows.en.md) for installer, portable build, and winget maintenance details.

### Linux

Download the package matching your distribution and architecture from the [latest stable release](https://github.com/CyrilPeng/venera-next/releases/latest):

| Distribution / format | Install or run |
|---|---|
| Debian / Ubuntu (DEB) | `sudo apt install ./venera-next_xxx_amd64.deb` (use `arm64` on ARM64) |
| Fedora and other distributions providing the required dependencies (RPM) | `sudo dnf install ./venera-next-xxx.x86_64.rpm` (use `aarch64` on ARM64) |
| Arch Linux (x86_64) | `sudo pacman -U ./venera-next-xxx-x86_64.pkg.tar.zst` |
| AppImage (x86_64 / ARM64) | Run `chmod +x VeneraNext-xxx-x86_64.AppImage`, then `./VeneraNext-xxx-x86_64.AppImage` (use the `aarch64` file on ARM64) |

Replace `xxx` with the actual version in the downloaded filename. The v1.18.1 stable release includes RPM and AppImage packages for both x86_64 and ARM64. Use `uname -m` to check your architecture.

Linux packages are built on Ubuntu 22.04 with a glibc 2.35 baseline. The current stable AppImage includes GTK 3 and WebKitGTK 4.1, so no separate GTK/WebKit installation is needed. It still requires host glibc 2.35 or newer and compatible OpenGL/EGL graphics drivers. See [Linux Installation and Distribution](doc/distribution/linux.en.md) for dependencies, FUSE troubleshooting, and distribution compatibility.

### macOS

Download `VeneraNext-xxx.dmg` from the [latest stable release](https://github.com/CyrilPeng/Venera-Next/releases/latest).

---

## Quick start

1. **Install** the build for your platform from the [latest stable release](https://github.com/CyrilPeng/venera-next/releases/latest); on a TV, choose the separate package described under [Android TV](#android-tv).
2. **Add content** (any one of these is enough to get started): existing comic files → Local → Import; network series → install an extension in Comic Source management; a NAS folder → Settings → APP → WebDAV Comic Library.
3. **Start reading**: phones and desktops default to Waterfall reading across chapters, while TV defaults to single-page low-memory reading. When you find a series to follow, try long-pressing the Favorite button on its details page. Reading mode, split spreads, night dimming, and more can be adjusted anytime in Settings → Reading or inside the reader.

## Usage guide

### Reading modes and progress

| Mode | Directions | Best for |
|---|---|---|
| Waterfall (non-TV default) | Top to bottom | Continuous reading across chapters; adjacent chapters load near boundaries |
| Gallery | L→R / R→L / T→B | Page-by-page reading with configurable multi-image layouts |
| Continuous | L→R / R→L / T→B | Scrolling inside the current chapter with explicit boundaries |

- **Preloading:** adjust the image preload count in Settings → Reading to prepare upcoming images and reduce waits. Loading more images also uses more data and memory.
- **Resume:** progress stores the chapter and page, and Waterfall records the chapter you are actually reading. Ascending/descending on the details page only changes the list display.
- **Separate reader settings:** enable device-specific or per-comic settings so you do not have to readjust them each time.

| Single-page view | Split double-page view |
|---|---|
| <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Single%20Page%20View.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Single%20Page%20View.jpg" alt="A wide page before splitting" width="100%" /></a> | <a href="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Double%20Page%20View.jpg"><img src="https://git-pictures.cyrilworkshop.dpdns.org/veneranext/Double%20Page%20View.jpg" alt="The same spread with double-page splitting enabled" width="100%" /></a> |

### TV remote controls and low-memory reading

- **Main UI:** use direction keys to move focus and Select / gamepad A to activate; Back / gamepad B returns. Remotes with a menu key can open context menus on supported controls.
- **Reading surface:** direction keys turn pages or scroll; Select opens the reader menu. While the menu is open, direction keys navigate controls without turning pages in the background. Back closes the menu first, then saves progress and exits the reader.
- **Low-memory defaults:** single-page reading, one-page preloading, a 64 MiB decoded-image cache, and an approximately 2.07-megapixel decode budget. Disable Settings → Reading → TV low-memory mode to restore previous settings and use modes such as Waterfall. This switch is device-local and excluded from backups and synchronization.
- **Compatibility limits:** originals are unchanged, but long strips and zoomed details may look softer. The image-cache cap is not a total process-memory cap. Web login, CAPTCHA, file pickers, and similar flows may still need an input method or companion device; small-scale testing does not certify every TV or box.

### Nighttime and E-Ink reading

- **Night dimming:** turn it on inside the reader (reader settings or the bottom quick panel) and dim from 20% to 100%; it affects only the in-app image. Choose the app's light/dark/system theme in Settings → Appearance.
- **E-Ink:** enable E-Ink refresh in Gallery mode and choose a flash every 1–10 page turns, a duration of 100–1500 ms, and a black, white, or white-then-black style. Continuous and Waterfall do not trigger it.

### Favorites, Read Later, and update tracking

- **Favorites:** tap Favorite on the details page to open the panel and pick a local folder or the source account (extension-dependent). The favorites page supports list and cover-gallery layouts (auto or 2–6 columns).
- **Quick Favorite:** long-press Favorite on the details page to add the comic directly to the selected local folder, which defaults to the Follow Updates folder. Change the target in Settings → Local Favorites → Quick Favorite.
- **Update tracking settings:** open Follow Updates from Home to choose which folder to track, or select Check Now to refresh manually.
- **Read Later:** add or remove a title from comic details or the local-comic menu and open the full list from Home; opening a comic does not remove it.
- **Reading statistics:** History shows total reading time, comics read, and time rankings; history can be cleaned by retention period.
- **Search shortcuts:** save frequent author/tag searches as shortcuts and reuse them from the search page.

### Local comics and offline downloads

| Content | Import and reading behavior |
|---|---|
| Image folders | Single or batch imports, including chapter subfolders; optional covers and natural filename ordering |
| CBZ / ZIP / 7Z / CB7 | Extract into the local library, including archives with a top-level folder and chapter subfolders |
| PDF | Sequential multi-file import with progress and cancellation; render pages to local JPEGs and use the first page as the cover |
| Image-based EPUB | Import comic images in the EPUB's reading order, keeping title, author, cover, and chapter navigation where available |
| Source downloads | Store downloaded chapters in the local library for offline reading, later export, and archival |

CBZ export, scanning to recover downloads, chapter deletion, and storage migration are available. PDF/EPUB imports consume additional storage; text-only EPUB, directly drawn SVG pages, encrypted PDF, and MOBI/AZW/AZW3 are not supported. See [local import, CBZ, and WebDAV library rules](doc/user/import_comic.en.md) for folder examples, archive compatibility, and metadata templates.

### Network comic extensions

User-installed JavaScript extensions provide network content. Search, exploration, categories, accounts, favorites, and comment capabilities vary by extension.

Add a compatible script link or file in Comic Source management. To write an extension, start with [Developing comic sources](#developing-comic-sources).

### WebDAV data sync, archives, and online library

These are configured separately:

| Capability | Entry in Settings → APP | Purpose |
|---|---|---|
| App-data synchronization | Data Sync | Synchronize settings, favorites, history, cookies, and source files; local comic images are excluded |
| Comic archives | Comic Archive Backup | Upload local comics as CBZ archives or download archives into the local library |
| Online library | WebDAV Comic Library | Load remote image folders on demand and cache directory information and images |

The online library accepts image folders, chapter subfolders, and extracted CBZ exports from VeneraNext. A `metadata.json` file can add title, author, tags, and chapter information. The shelf shows cached comics first, then checks for new or changed content on the server. You can sync manually or set an automatic update interval.

Remote CBZ/ZIP/7Z/CB7 archives must be extracted on the server or restored locally before reading. See [folder and metadata rules](doc/user/import_comic.en.md#webdav-online-library).

## Developing comic sources

**Start here when writing a third-party extension:**

| Document | Contents |
|---|---|
| [Comic Source Guide](doc/api/comic_source.en.md) | Minimal example, search/details/chapter contracts, image requests, and optional capabilities |
| [Minimal source template](doc/examples/minimal_source.js) | Copyable JS file demonstrating the full loading flow with a fictional API |
| [JavaScript API](doc/api/js.en.md) | Network, HTML parsing, source storage, UI, image processing, and runtime limits |
| [Local Source Debugging](doc/development/source_debugging.en.md) | Import, edit, JS Evaluator, and logs |

Chinese editions: [漫画源编写指南](doc/api/comic_source.zh.md) · [JavaScript API](doc/api/js.zh.md) · [本地调试](doc/development/source_debugging.zh.md).

This fork continues to maintain Venera-compatible extension interfaces. Waterfall, split spreads, and night dimming are reader responsibilities. Extensions supply stable comic/chapter IDs, correctly ordered chapters and images, and valid update dates; they do not need separate rules for every reader mode.

## FAQ

### Does VeneraNext include comic sources?

No source or recommended catalog is bundled. Import local comics or configure a legal compatible extension or WebDAV library.

### Why are search results or images missing?

Check the comic source extension, login status (cookies), service availability, and network first. Contact the relevant extension maintainer for site and content issues. Reader or extension-runtime problems reproducible independently of a particular site can be reported under the [contribution guidelines](CONTRIBUTING.en.md).

### How often are updates checked, and why are some updates not flagged?

- **Automatic checks:** while the app is running, checks run every 10 minutes and skip comics successfully checked within the past 24 hours. Select Check Now on the Follow Updates page to refresh immediately.
- **Update detection:** a comic is flagged when the extension returns a changed, valid update time. A new chapter without a changed update time may not be flagged.
- **Update indicators:** Settings → Explore → Show update status on comic tile controls indicators on comic thumbnails, not update checking or the count on the Home card.

### How do I shrink strip comics on a tablet?

Select vertical continuous or waterfall reading in reader settings, then adjust **Shrink strip comics (margin per side)**. At 20% per side, image width becomes 60% of its original size, with proportional height and the same reading progress. See [strip comic size and side margins](doc/user/reader_width.en.md).

### How do I update on Windows?

Run `winget upgrade --id CyrilPeng.VeneraNext --exact`. Public-source availability may lag behind GitHub Release; try `winget source update` first. Portable installations require downloading and applying an update manually.

## Developer resources

- [Build and Development](doc/development/build.en.md): Flutter/Rust, locked dependencies, tests, and releases.
- [Contributing](CONTRIBUTING.en.md) · [Dependency Governance](doc/development/dependencies.en.md).
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
