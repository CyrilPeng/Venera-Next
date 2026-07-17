# Import Comic

## Introduction

VeneraNext supports importing comics from local files.
However, the comic files must be in a specific format.

## Restore Local Downloads

If you migrated the app and kept the local download folder but lost `local.db`,
you can restore the local database by scanning the current local path.

- Open `Local` -> `Import` -> `Restore local downloads`.
- The app scans the current local storage path and rebuilds entries.
- It does not copy files or add favorites.
- Duplicates (same title or directory) are skipped.

Make sure the local storage path in Settings points to the folder that contains
the downloaded comics before running this.

## Comic Directory

A directory considered as a comic directory only if it follows one of the following two types of structure:

**Without Chapter**

```
comic_directory
├── cover.[ext]
├── img1.[ext]
├── img2.[ext]
├── img3.[ext]
├── ...
```

**With Chapter**

```
comic_directory
├── cover.[ext]
├── chapter1
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── chapter2
│   ├── img1.[ext]
│   ├── img2.[ext]
│   ├── img3.[ext]
│   ├── ...
├── ...
```

The file name can be anything, but the extension must be a valid image extension.

The page order is determined by the file name. App will sort the files by name and display them in that order.

Cover image is optional. 
If there is a file named `cover.[ext]` in the directory, it will be considered as the cover image.
Otherwise, the first image will be considered as the cover image.

The name of directory will be used as comic title. And the name of chapter directory will be used as chapter title.

## Archive

VeneraNext supports importing comics from archive files.

Archive files are intended for import, export, backup, migration, and distribution. They must follow [Comic Book Archive](https://en.wikipedia.org/wiki/Comic_book_archive_file) format.

Currently, VeneraNext supports the following archive formats:
- `.cbz`
- `.cb7`
- `.zip`
- `.7z`

An archive may contain images directly, or it may contain one top-level folder.
If the top-level folder contains chapter folders, VeneraNext imports those
folders as chapters.

```text
Cat's Eye.cbz
└── Cat's Eye
    ├── cover.jpg
    ├── Volume 01
    │   ├── 001.jpg
    │   └── 002.jpg
    └── Volume 02
        ├── 001.jpg
        └── 002.jpg
```

If there is no `cover.[ext]` in the root folder, the first image from the first
chapter is used as the cover.

## WebDAV Online Library

The WebDAV comic library is an online reading channel. It is separate from local import/export and WebDAV CBZ archive backup.

Online reading only reads images from remote directories. The app lists directories and loads images on demand; remote CBZ/ZIP/7Z files are not used for online preview. You can use a plain image directory or extract a single-comic CBZ exported by VeneraNext to WebDAV to preserve its title, author, tags, and chapters.

### Plain Directory Mode

Recommended structure:

```text
/venera_comics/
└── Cat's Eye
    ├── cover.jpg
    ├── Volume 01
    │   ├── 001.jpg
    │   └── 002.jpg
    └── Volume 02
        ├── 001.jpg
        └── 002.jpg
```

Plain directory rules:

- The comic title defaults to the comic folder name.
- Child directories are chapters. Root-level images can also form a single-chapter comic.
- Pages and chapters are sorted by file name. Zero-padded names such as `0001.jpg` and `0002.jpg` are recommended.
- The preferred cover is a root image whose base name is `cover`. Supported extensions are `jpg`, `jpeg`, `png`, `webp`, `gif`, and `jpe`. Without one, the app tries the first root page, then `cover.*` or the first page in the first readable chapter.
- Neither `metadata.json` nor `ComicInfo.xml` is required.

### Extracted CBZ Enhanced Mode

A single-comic CBZ exported by VeneraNext normally has a flat image layout after extraction:

```text
/venera_comics/
└── Cat's Eye
    ├── metadata.json
    ├── ComicInfo.xml
    ├── cover.jpg
    ├── 0001.jpg
    ├── 0002.jpg
    ├── 0003.jpg
    └── 0004.jpg
```

`metadata.json` template:

```json
{
  "title": "Cat's Eye",
  "author": "Tsukasa Hojo",
  "tags": ["Action", "Manga"],
  "chapters": [
    {"title": "Volume 01", "start": 1, "end": 2},
    {"title": "Volume 02", "start": 3, "end": 4}
  ]
}
```

Field rules:

| Field | Type | Description |
|---|---|---|
| `title` | string | Comic title; an empty string falls back to the folder name |
| `author` | string | Author; may be empty |
| `tags` | string array | Comic tags; may be empty |
| `chapters` | array or `null` | Chapter ranges; root images form one chapter when this is `null` or empty |
| `chapters[].title` | string | Non-empty chapter display name |
| `chapters[].start` | integer | Inclusive first page, starting at 1 |
| `chapters[].end` | integer | Inclusive last page |

Chapter ranges must be ordered, non-overlapping, non-reversed, and within the actual number of root pages. `cover.*` is not included in page numbering. Extra metadata fields are allowed for forward compatibility. Remote URLs, scripts, and local absolute paths are not read from metadata.

`metadata.json` must use UTF-8; its file name is matched case-insensitively. `ComicInfo.xml` remains in the exported CBZ for compatibility with other readers, while the VeneraNext WebDAV library currently uses `metadata.json` as its enhanced metadata source.

If metadata is missing or unreadable, JSON is malformed, field types are invalid, or chapter ranges fail validation, the app logs a warning and falls back to plain directory mode. The comic remains visible under its folder name, and directory images and chapter folders remain readable.

This `metadata.json` is the single-comic CBZ metadata format. It is not the comic-list format inside a `.venera-comics` batch export, and the two formats are not interchangeable.

### Archives and Online Reading

CBZ/ZIP/7Z files can still be uploaded, downloaded, and restored through WebDAV archive backup, but they are backup and distribution formats rather than online reading formats. Extract them on the WebDAV server for online reading; the app then reads images on demand without downloading the whole archive.
