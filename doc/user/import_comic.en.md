# Import Comic

## Introduction

VeneraNext can import comics from local directories, comic archives, PDF files,
and image-based EPUB files. Imported content is normalized into the existing
local image-comic layout so all reader modes, progress tracking, and split-spread
features continue to work.

Supported comic image extensions are `jpg`, `jpeg`, `jpe`, `png`, `webp`,
`gif`, and `avif`.

If an imported entry is not visible, check the local search and keyword filters
first. The list reports how many entries are hidden by keyword filters; favorites
also explain reading-status exclusions without changing those rules. Unicode,
brackets and double extensions do not by themselves make a filename invalid.
Check the actual success/failure counts and named errors for batch imports;
do not rename all archives or delete data as a first step.

The number at the top left in multi-select mode is the selection count, not the
import success count. Starting with v1.18.2-rc.3, local-list bulk selection no
longer includes hidden entries or keeps stale selection after refresh; v1.18.1
and the earlier rc.1/rc.2 do not contain this fix. This does not resolve every
reported Android archive-visibility scenario. Distinguish
import results, visible/hidden entries and selection counts when reporting, and
include the full version and whether single or batch archive import was used;
there is no need to clear data or upload private archives again.

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

Pages use natural filename order, such as `page_1.jpg`, `page_2.jpg`, `page_10.jpg`. Multiple numeric segments, leading zeros and mixed-case filenames are supported.

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

## PDF and Image-based EPUB

Open `Local` -> `Import` and select either a PDF comic file or an image-based
EPUB file. Both formats are converted into app-managed local image comics during
import; the original document is not streamed by the reader.

### PDF

- Open `Local` -> `Import` -> `PDF comic files` to select one or more PDFs. Each file becomes a separate comic, and the destination favorites folder is selected once for the batch.
- Files are converted sequentially. Progress includes the current file, its position in the batch, and its page count, so there is no need to select each volume separately.
- **New on main (unreleased):** select “Run in background”, close the progress dialog, or go back to keep reading other comics without cancelling import. Open “PDF import tasks” using the PDF icon on the home screen's Local card or the local library page to check progress, cancel, or review individual results. Reopening does not restart import. Additional PDF batches join the same serial queue; queued tasks can be cancelled immediately. Clearing completed task records does not delete imported comics.
- Each successful comic is saved immediately. Duplicate selections and titles already in the local library are skipped. A damaged, password-protected, or unreadable file does not stop the remaining files; individual results are shown at the end.
- Cancelling stops subsequent imports and cleans up the unfinished comic after the current file preparation or page operation finishes safely. Successfully imported comics are kept, and unprocessed files are not counted as failures.
- On main, changing local storage or scanning to restore the library is blocked while a PDF is being converted or registered; wait for import to finish or cancel it first. If migration or recovery has already started, new PDFs wait until it finishes before conversion. You can keep reading other comics.
- Keep the app running during import. Continuing after the app exits or resuming across restarts is not supported. On Android, files that cannot be accessed directly are copied to temporary storage one at a time and released after processing.
- Each PDF page is rendered to JPEG in order, and the first page is also used as the cover.
- The result is a flat comic without chapters. Its title defaults to the PDF file name.
- Pages are rendered at roughly three times their PDF point size with a 3000-pixel longest-edge limit to balance clarity, memory, and storage use.
- Encrypted or password-protected PDF files are not currently supported.
- Import creates a new image copy, so additional local storage is required.

### Image-based EPUB

- Fixed-layout EPUB files may use direct raster-image spine items or XHTML/SVG wrappers containing `img` or SVG `image` references.
- Page order follows the EPUB spine. Title, author, and cover metadata are preserved when available.
- Multiple valid navigation entries are preserved as chapters. Files without meaningful chapter navigation are imported as flat comics.
- Original raster images are copied without recompression.
- Text-based EPUB files, directly rendered SVG pages, external image references, and paths outside the EPUB root are rejected instead of silently dropping content.

MOBI, AZW, and AZW3 are not supported. Convert them externally to an image-based
EPUB, PDF, or CBZ before importing.

Document import never overwrites an existing comic with the same title.

## WebDAV CBZ Archive Results and Retries

Starting with v1.18.2-rc.4 (#126), archiving local comics to WebDAV and downloading
archives for import keep a result dialog open with each title, remote filename,
status and selectable error details instead of a brief count-only message.
v1.18.1 and earlier release candidates do not include these result and retry
improvements.

- Retry one failed item or all failed items without replaying successful uploads
  or imports. Cancellation waits for active work to finish safely, keeps completed
  items and leaves unstarted items available to continue in the same dialog.
- An initially existing remote name is skipped as unverified, not counted as a
  successful archive. Uploads send `If-None-Match: *` and never fall back to an
  unconditional overwrite to bypass a conflict. Real-service support for this
  condition still needs validation.
- If an upload failed but a same-name file appeared remotely, retry downloads it
  and compares SHA-256 with the bytes actually uploaded by that item. Only a match
  confirms success; a mismatch or missing original digest stays a conflict without
  deleting remote files. Verification needs extra bandwidth and temporary space.
- If import registration was committed or its outcome is uncertain, direct retry
  is disabled. Check the local entry, cover, pages and visibility after restarting
  before importing again; do not clear data or delete potentially saved files.
- Results and retry records last only until this dialog closes. There is no
  background or cross-restart queue. Record errors before closing and check for
  credentials, private links and personal paths before sharing; default redaction
  is not a complete anonymization guarantee.

This improves result visibility and recovery, not the unconfirmed root cause of
123 Cloud failures. App-data synchronization and online WebDAV reading are
unchanged.

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
- Pages and chapters in ordinary directories use natural filename order. Explicit chapter ranges from metadata are preserved.
- The preferred cover is a root image whose base name is `cover`. Supported extensions are `jpg`, `jpeg`, `png`, `webp`, `gif`, `jpe`, and `avif`. Without one, the app tries the first root page, then `cover.*` or the first page in the first readable chapter.
- Neither `metadata.json` nor `ComicInfo.xml` is required.

### Metadata-Marked Nested Layout

For a deeply nested WebDAV library, place `metadata.json` in the comic root to explicitly mark that directory as one comic:

```text
/venera_comics/
└── Category/
    └── Author/
        └── Cat's Eye/
            ├── metadata.json
            ├── cover.jpg
            ├── Chapter 01/
            │   ├── 001.jpg
            │   └── 002.jpg
            └── Chapter 02/
                └── 001.jpg
```

During WebDAV synchronization, the app recursively searches for directories containing `metadata.json` and treats each marked directory as one comic. Its direct child directories become chapters. Once a comic root is found, the app does not expose its chapters or deeper directories as separate comics. Comic IDs use paths relative to the configured WebDAV library path, so same-named comics in different categories do not overwrite one another.

In this mode, the title, author, and tags come from `metadata.json`, while chapter names and paths come from direct child directories. A root-level `cover.*` file is used only as the cover. Other root-level images are preserved in an `Images` chapter.

When real chapter directories and `metadata.json` page ranges coexist, the real directory layout takes precedence; page ranges are not matched to directories by position. `chapters[].start` and `chapters[].end` are used for virtual chapters only when the root contains flat images and no chapter directories, which preserves the extracted CBZ layout.

Recursive discovery is limited to directories with an explicit metadata marker. Complex multi-level layouts without metadata are not guessed indefinitely; add `metadata.json` at the comic root to prevent unrelated comics from being merged.

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

This `metadata.json` is the single-comic CBZ metadata format. It is not the comic-list format inside a historical `.venera-comics` batch archive, and the two formats are not interchangeable.

### Archives and Online Reading

CBZ/ZIP/7Z files can still be uploaded, downloaded, and restored through WebDAV archive backup, but they are backup and distribution formats rather than online reading formats. Extract them on the WebDAV server for online reading; the app then reads images on demand without downloading the whole archive.
