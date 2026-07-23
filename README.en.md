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
- [FAQ](#faq)
- [Developer resources](#developer-resources)
- [Statement](#statement)
- [Sponsors](#sponsors)
- [License](#license)

---

## Introduction

[VeneraNext](https://github.com/CyrilPeng/Venera-Next) is a cross-platform comic reader built with Flutter. It supports local comics and network comic extensions on Android, iOS, Windows, Linux, and macOS.

This project is a fork of [Venera](https://github.com/venera-app/venera), focused on everyday personal reading with as few interruptions as possible.

Long series can be read continuously across chapters in waterfall mode. Frequently read titles can be favorited, followed, or downloaded for offline use, while WebDAV can synchronize common application data across devices.

> [!IMPORTANT]
> **This repository maintains the comic reader only.** It does not provide, bundle, host, or recommend any comic source. Users must configure legal comic source extensions themselves. Do not report source-site content, title availability, or comic-source issues in this repository.

<div align="center">
  <a href="https://github.com/CyrilPeng/Venera-Next">
    <img alt="GitHub main repository" src="https://img.shields.io/badge/GitHub-Main_repository-181717?style=for-the-badge&logo=github&logoColor=white" />
  </a>
  <a href="https://gitee.com/CyrilPeng/venera-next">
    <img alt="Gitee China mirror" src="https://img.shields.io/badge/Gitee-China_mirror-C71D23?style=for-the-badge&logo=gitee&logoColor=white" />
  </a>
</div>

---

## Highlights

### Features specific to this fork

- **Cross-chapter waterfall reading**: the default reading mode preloads the next chapter near the end of the current chapter, making long series and collected volumes easier to read continuously.
- **Split double-page spreads in vertical modes**: landscape spreads can be split into vertically stacked halves in vertical continuous and waterfall modes. The split order can be reversed for titles with a different reading direction.
- **Persistent chapter order preference**: ascending and descending chapter order is controlled by a segmented selector and stored as a global preference.
- **Local and remote libraries**: local comics can be imported from directories, CBZ, ZIP, or 7Z archives. A WebDAV comic library can read regular image directories and extracted VeneraNext CBZ directories online.
- **Reader and sources remain separate**: this repository maintains the reader itself and does not bundle, recommend, or maintain source-site configurations.

### Comic channels

- **Local comics**: read image directories and archives already available on the device. Single-title directories, parent directories containing multiple titles, CBZ, ZIP, 7Z, and CB7 imports are supported.
- **Network comic extensions**: compatible JavaScript extension APIs can provide search, categories, rankings, discovery, favorites, and downloads.
- **WebDAV comic library**: use a NAS, Nextcloud, ownCloud, or another WebDAV server as an online image library. Regular image directories and enhanced extracted CBZ directories are supported; compressed archives are not streamed directly.
- **Downloaded chapters**: chapters from a network extension can be saved into the local comic library for offline reading.

### Management and synchronization

- Favorites, reading history, image favorites, download queues, and update tracking.
- Local comic importing, exporting, recovery scans, chapter deletion, and storage-path migration.
- WebDAV data synchronization, CBZ archive backup and restore, and an online comic library. See the [WebDAV guide](#webdav-data-sync-and-comic-archives) for the differences.

### Cross-platform support

- Android, iOS, Windows, Linux, and macOS.
- Release artifacts are provided for multiple platforms.
- Windows installation and updates are available through winget.

See [CHANGELOG.md](CHANGELOG.md) for the complete release history.

---

## Download and installation

### Android

Download an APK from [GitHub Releases](https://github.com/CyrilPeng/Venera-Next/releases):

| File | Description | Recommended for |
|---|---|---|
| `VeneraNext-xxx-android.apk` | Universal build | Most Android devices |
| `VeneraNext-xxx-android-arm64-v8a.apk` | ARM64 build | 64-bit devices with at least 4 GB RAM |
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

1. Download the package for your platform from [GitHub Releases](https://github.com/CyrilPeng/Venera-Next/releases).
2. Choose a comic channel:
   - For an existing image directory or CBZ file, open `Local` -> `Import`.
   - For a network comic extension, open comic source management and add an extension compatible with the JavaScript API.
   - For online NAS or WebDAV reading, open `Settings` -> `App` -> `WebDAV Comic Library` and configure the remote directory.
3. Select a reading mode under `Settings` -> `Reader`. Waterfall is recommended for long series; Gallery provides traditional page turning; Continuous scrolls within the current chapter only.
4. Check the chapter order on the comic details page. Switch between ascending and descending order when necessary; the preference is remembered globally.
5. For landscape double-page spreads, enable split spreads in vertical continuous or waterfall mode. Enable reverse split order when the halves appear in the wrong reading order.
6. Add frequently read titles to favorites or update tracking. Download chapters first when the network is unreliable or when reading offline.
7. Configure WebDAV only when needed. Application data sync, CBZ archive backup, and the online WebDAV comic library are three independent configurations.

---

## Usage guide

### Reader modes

- **Waterfall (top to bottom)**: the default mode emphasized by this fork. It loads following chapters near the end of the current chapter and is suited to long, uninterrupted reading sessions.
- **Gallery**: traditional paged reading with horizontal or vertical directions.
- **Continuous**: scrolls continuously inside the current chapter without automatically crossing chapter boundaries.
- **Image preloading**: the preload count can be adjusted in reader settings. A larger value may help on slow networks, but should remain moderate on devices with limited memory or thermal headroom.
- **Progress tracking**: chapter, page, and chapter-group positions are recorded. Cross-chapter waterfall reading updates progress to the chapter actually being viewed.
- **Split double-page spreads**: available only in vertical continuous and waterfall modes. A landscape image is transformed into vertically stacked halves without changing the chapter page count. The split order can be reversed.

### Local comics

Local comics support both flat image directories and directories containing chapter folders:

```text
Comic/
|-- cover.jpg
|-- 001.jpg
`-- 002.jpg
```

```text
Comic/
|-- cover.jpg
|-- Volume 01/
|   |-- 001.jpg
|   `-- 002.jpg
`-- Volume 02/
    |-- 001.jpg
    `-- 002.jpg
```

- `cover.jpg` is optional. When it is absent, the app tries to use the first readable image as the cover.
- Pages are ordered by file name. Names such as `001.jpg`, `002.jpg`, and `003.jpg` avoid inconsistent ordering such as `1.jpg`, `10.jpg`, `2.jpg`.
- For batch directory import, select the parent directory containing multiple comic directories, rather than an internal chapter directory.

### CBZ, ZIP, and 7Z import and export

- CBZ, ZIP, 7Z, and CB7 are suitable for importing, exporting, backup, migration, and distribution.
- An archive may contain images directly or wrap everything in one top-level directory. Chapter directories inside that top-level directory are imported as chapters.
- The following layout is supported:

```text
Comic.cbz
`-- Comic/
    |-- cover.jpg
    |-- Volume 01/
    |   |-- 001.jpg
    |   `-- 002.jpg
    `-- Volume 02/
        |-- 001.jpg
        `-- 002.jpg
```

- Large archives must be extracted and copied into the local library before reading. They are best suited to download-first reading, backup, and distribution rather than online streaming.
- Imported local comics can be exported as CBZ files for backup or transfer between devices.

### Network comic extensions

- Network comic functionality is provided by extensions compatible with the JavaScript extension API. Search, browsing, and reading become available after an extension is added.
- This repository does not provide source lists or handle source-site content issues. Missing search results, empty chapters, and image failures usually need to be investigated in the relevant extension, source site, network, or proxy configuration.
- Capabilities differ between extensions. Categories, rankings, comments, ratings, archive downloads, and login entry points are shown only when supported.
- When a source requires login, cookies, or site verification, use the settings or login entry point provided by that extension.

### WebDAV comic library

- The WebDAV comic library treats a NAS, Nextcloud, ownCloud, or another WebDAV directory as an online comic library.
- Configure it under `Settings` -> `App` -> `WebDAV Comic Library`.
- Regular directories do not require metadata. The folder name becomes the comic title and child directories become chapters. Without `cover.*`, the app tries a root image and then the first readable chapter cover or page.
- Example regular directory:

```text
/venera_comics/
|-- Comic A/
|   |-- cover.jpg
|   |-- Volume 01/
|   |   |-- 001.jpg
|   |   `-- 002.jpg
|   `-- Volume 02/
|       |-- 001.jpg
|       `-- 002.jpg
`-- Comic B/
    |-- cover.jpg
    `-- Chapter 01/
        |-- 001.webp
        `-- 002.webp
```

- A single-title CBZ exported by VeneraNext can be extracted directly into the library. Its `metadata.json` supplies title, author, tags, and chapter page ranges while root images remain lazily loaded:

```text
/venera_comics/Comic A/
|-- metadata.json
|-- ComicInfo.xml
|-- cover.jpg
|-- 0001.jpg
`-- 0002.jpg
```

- Missing, damaged, or invalid metadata is ignored and the app falls back to regular directory inference instead of hiding the comic.
- Remote CBZ, ZIP, 7Z, and CB7 files remain archive files and are not previewed online. Extract them on the server for online reading.
- The first visit requires a directory listing and may take time on a slow WebDAV server. Images are then loaded on demand and use the application cache.
- See [Local Comic Import, CBZ, and WebDAV Library](doc/user/import_comic.en.md) for complete directory and metadata rules.

### WebDAV data sync and comic archives

VeneraNext has three independent WebDAV features:

| Feature | Settings entry | Purpose | Online reading |
|---|---|---|---|
| WebDAV data sync | `Settings` -> `App` -> `Data Sync` | Synchronizes settings, favorites, history, cookies, extension files, and other application data | No |
| WebDAV comic archive | `Settings` -> `App` -> `Comic Archive Backup` | Uploads local comics as CBZ archives or downloads them for restoration | No |
| WebDAV comic library | `Settings` -> `App` -> `WebDAV Comic Library` | Reads remote image-directory structures online | Yes |

- Data sync shares application state between devices but does not synchronize local comic images.
- Comic archives are intended for device migration, backup, and restoration. Restored archives enter the local comic library.
- The WebDAV comic library reads remote directories on demand without downloading an entire comic first.

### Favorites, update tracking, and downloads

- Favorites provide long-term organization, while reading history returns to recently viewed positions.
- Update tracking checks followed titles for new chapters and depends on the associated network extension or favorite data.
- Download management provides offline reading, especially on mobile devices or unreliable networks. Downloaded chapters are read as local content.
- Image favorites and gallery browsing store and revisit individual pages.
- Local favorites and network favorites are separate: local favorites belong to the app, while network favorites depend on source-site accounts and extension capabilities.

---

## FAQ

### 1. Does VeneraNext include comic sources?

No. VeneraNext provides the reader, local library management, and a runtime for extensions compatible with the JavaScript API. Users must configure legal network comic extensions themselves.

### 2. Can I report comic-source problems here?

No. Do not file issues about comic sources, source-site content, title availability, missing chapters, image availability, or copyright disputes in this repository.

Issues reproducible without a specific source or title, such as reader crashes, UI defects, settings failures, or build failures, may be reported here.

### 3. Why are search results missing or images failing to load?

This usually depends on the extension, source-site status, network environment, or proxy configuration. Check whether the relevant extension still works and whether the device can reach the associated website.

### 4. Can Windows update with one command?

Yes. Install and upgrade through winget:

```powershell
winget install --id CyrilPeng.VeneraNext --exact
winget upgrade --id CyrilPeng.VeneraNext --exact
```

If a newly released version is not visible, run `winget source update`. Microsoft review means winget releases usually lag behind GitHub Releases. Portable ZIP builds cannot be upgraded by winget.

---

## Developer resources

This README focuses on installation and usage. Build, test, architecture, and distribution details live in the developer documentation:

- [Build and Development](doc/development/build.en.md) / [构建与开发](doc/development/build.zh.md)
- [Repository Structure](doc/architecture/project_structure.en.md)
- [Windows Distribution](doc/distribution/windows.en.md)
- [Documentation Index](doc/README.en.md)

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

## License

This project is licensed under GPL-3.0.
