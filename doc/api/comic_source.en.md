# Comic Source Guide

[中文](comic_source.zh.md) · [JavaScript API](js.en.md) · [Local debugging](../development/source_debugging.en.md) · [README](../../README.en.md#developing-comic-sources)

This guide follows the repository's [JS runtime](../../assets/init.js), [source parser](../../lib/features/comic_source/parser.dart), and [data models](../../lib/features/comic_source/models.dart). Examples use fictional addresses and are not working comic services or source recommendations.

VeneraNext retains Venera's extension interfaces. Management screens and runtime details vary by version: multiple repositories, unified Add source, and the new reload workflow are currently unreleased main-branch features. Stable v1.16.0 uses the previous import interface.

## Reading path

1. Start with search → details → chapter images.
2. Verify IDs, return types, ordering, and image requests.
3. Add exploration, categories, accounts, network favorites, comments, and settings as needed.
4. Debug locally, then distribute a script URL or catalog.

## 1. Script and minimal example

An extension is a UTF-8 `.js` file with an entry class extending `ComicSource`. Class fields with arrow-function callbacks let callbacks access the source instance through `this`. Do not use `import`, `export`, `require`, or browser-page globals: this is neither Node.js nor a full browser.

| Field | Rule |
|---|---|
| `name` | Nonempty display name |
| `key` | Stable unique identifier matching `^[a-zA-Z_][a-zA-Z0-9_]*$`; keep it unchanged after release |
| `version` | Source version string with three numeric components, such as `1.0.0`; see publishing for suffix comparison rules |
| `minAppVersion` | Explicitly set the lowest app version you have verified, such as `1.16.0`; the base class's empty-string default is not a valid version |
| `url` | Raw HTTP(S) script download URL, or empty when unavailable; not a GitHub file-view page or a catalog URL |
| `init()` | Optional short initialization; do not load an entire site here |

Basic metadata makes a script identifiable. To open and read comics, implement `comic.loadInfo` and `comic.loadEp`, plus an entry through search, exploration, categories, or links. Omit unsupported optional capabilities instead of leaving empty callbacks that advertise support.

Download the complete [minimal_source.js template](../examples/minimal_source.js). It demonstrates requests, search, details, chapters, image headers, and tag navigation with a fictional JSON API. Importing it unchanged only checks script structure; replace domains, paths, and field mappings to load actual content. Its expected API is:

| Request | Example response shape |
|---|---|
| `GET /api/search?q=...&page=1` | `{items: [{id, title, author, cover, tags}], totalPages: 1}` |
| `GET /api/comics/demo` | `{title, author, cover, description, updatedOn: "2026-09-01", chapters: [{id: "1", title: "Chapter 1"}]}` |
| `GET /api/comics/demo/chapters/1` | `{images: ["https://example.invalid/images/1.jpg"]}` |

The essential structure, using static data to illustrate the return contracts:

```javascript
class MinimalSource extends ComicSource {
    name = "Minimal Example";
    key = "minimal_example";
    version = "1.0.0";
    minAppVersion = "1.16.0";
    url = "";

    search = {
        optionList: [],
        load: async (keyword, options, page) => ({
            comics: page === 1 ? [
                new Comic({
                    id: "demo",
                    title: "Demo",
                    cover: "https://example.invalid/cover.jpg"
                })
            ] : [],
            maxPage: 1
        })
    };

    comic = {
        loadInfo: async id => new ComicDetails({
            title: "Demo",
            cover: "https://example.invalid/cover.jpg",
            tags: { author: ["Example Author"] },
            chapters: { ep_1: "Chapter 1", ep_2: "Chapter 2" },
            updateTime: "2026-09-01"
        }),
        loadEp: async (comicId, epId) => ({
            images: ["https://example.invalid/" + epId + "/1.jpg"]
        })
    };
}
```

The app registers the instance in `ComicSource.sources`; do not register it yourself.

## 2. Data and chapter rules

### Lists and details

Use `new Comic({...})`, `new ComicDetails({...})`, or plain objects of the same shape. Return string-keyed objects, arrays, and explicit primitive types rather than relying on native JS `Map`/`Set` or arbitrary class instances crossing the bridge.

| Data | Fields |
|---|---|
| `Comic` list item | `id: string`, `title: string`, `cover: string`; optional `subtitle`, `tags: string[]`, `description`, `language`, `stars`, `maxPage`, `favoriteId` |
| `ComicDetails` | Required `title: string`, `cover: string`, and `tags: {namespace: string[]}` (use `{}` when empty); `chapters` may be null; optional `subtitle`, `description`, `updateTime`, `uploadTime`, `url` |
| Additional detail fields | `thumbnails: string[]`, `recommend: Comic[]`, `comments: Comment[]`, `isFavorite`, `isLiked`, `likesCount`, `commentCount`, `subId`, `uploader`, `stars`, `maxPage` |
| Chapter images | `comic.loadEp(comicId, epId)` returns `{images: string[]}`, not a bare array or `{images: [{url: ...}]}` |

List-item tags are an array; detail tags are grouped by namespace. `stars` uses a 0–5 scale, whereas `comic.starRating` receives 0–10. Use `subtitle` consistently: list items and the `new ComicDetails(...)` constructor accept the `subTitle` alias, but plain detail objects do not remap it. The bridge supplies the comic ID and source identifier to details from the call arguments.

Keep IDs consistent across search, details, favorites, downloads, and history. Expiring URL signatures or access tokens must not become comic or chapter IDs.

### Chapters and reading order

For an unchaptered comic, use `chapters: null` and handle `epId == null` in `loadEp`. An empty chapter object is not a substitute.

Flat chapters:

```json
{
  "ep_1": "Chapter 1",
  "ep_2": "Chapter 2"
}
```

Grouped chapters:

```json
{
  "Main": {
    "main_1": "Chapter 1",
    "main_2": "Chapter 2"
  },
  "Extras": {
    "extra_1": "Extra 1"
  }
}
```

- Return chapters in reading order, normally oldest first, and images in their reading order.
- Do not mix flat and grouped values. Chapter IDs should also be unique across groups.
- JavaScript enumerates integer-like object keys in numeric order. Use stable non-integer keys when custom ordering matters, mapping back to service IDs in `loadEp`; the template uses an `ep_` prefix.
- The details-page ascending/descending setting changes presentation. Do not reverse the source's underlying order to match it.
- Waterfall preloads neighboring chapters. Return only the requested chapter's images from `loadEp`.
- Requests can run concurrently. Use supplied `comicId`/`epId` parameters rather than global “current comic/chapter” variables.
- Split spreads, night dimming, E-Ink refresh, automatic reading, and recognition from original image proportions are reader responsibilities. No per-mode source implementation is needed.

### Update dates and author tags

Update tracking calls `comic.loadInfo` and uses `updateTime`. If absent, it looks at the first tag in `更新`, `最後更新`, `最后更新`, `update`, or `last update`.

Return `YYYY-MM-DD`; a date followed by a space and time is also accepted. Timestamps, relative dates, and ISO strings with a `T` separator are unsuitable. Comparison currently uses the date only, so different times on the same day cannot distinguish updates. Do not substitute the request time for the real update date. Omit an unavailable date; chapter-count changes are not an automatic fallback.

Recognized author namespaces include `author`, `authors`, `artist`, `artists`, `作者`, and `画师`. With `comic.onClickTag`, users can save author/tag searches as shortcuts.

## 3. Search, exploration, and categories

### Pagination contracts

These are **JavaScript callback argument orders**, which can differ from internal Dart signatures.

| Callback | Return value |
|---|---|
| `search.load(keyword, options, page)` | `{comics: Comic[], maxPage: number}` |
| `search.loadNext(keyword, options, next)` | `{comics: Comic[], next: string or null}` |
| `explore[i].load(page)` for `multiPageComicList` | `{comics: Comic[], maxPage: number}` |
| `explore[i].loadNext(next)` for the same type | `{comics: Comic[], next: string or null}` |
| `categoryComics.load(category, param, options, page)` | `{comics: Comic[], maxPage: number}` |
| `categoryComics.ranking.load(option, page)` | `{comics: Comic[], maxPage: number}` |
| `categoryComics.ranking.loadWithNext(option, next)` | `{comics: Comic[], next: string or null}` |

Page numbers start at 1. A cursor is `null` on the first call, and `next: null` ends pagination. Cursor methods return `next`, not `maxPage`. Numbered-page loaders take precedence over cursor loaders in search, paged exploration, and rankings; normally implement one approach.

Each `search.optionList` item uses `{label, type, options, default}`; option strings are `"value-Display label"`. Types are `select`, `multi-select`, and `dropdown`. Multi-select values arrive as JSON array strings; an unselected dropdown can be `null`. `search.enableTagsSuggestions` and the synchronous `onTagSuggestionSelected(namespace, tag)` control inserted suggestion text.

### Exploration

`explore` is an array with unique page titles:

- `multiPageComicList`: use numbered or cursor pagination above.
- `multiPartPage`: `load()` returns `[{title, comics: Comic[], viewMore}]`; use a navigation target below for `viewMore`.
- `mixed`: `load(index)` starts at 0 and returns `{data: [...], maxPage?}`; items may be comic arrays or `{title, comics}` blocks. The current mixed-page parser does not convert `viewMore` objects into navigation targets, so omit that field; use `multiPartPage` when you need “view more” navigation.
- Legacy `singlePageWithMultiPart` returns `{sectionName: Comic[]}`; prefer `multiPartPage` for new extensions.

### Categories and navigation

`category` has `title`, `parts`, and optional `enableRankingPage`. Example class field:

```javascript
category = {
    title: "Example categories",
    parts: [{
        name: "Genres",
        type: "fixed",
        categories: [{
            label: "Adventure",
            target: {
                page: "category",
                attributes: { category: "Adventure", param: "adventure" }
            }
        }]
    }],
    enableRankingPage: false
};
```

Parts support `fixed`, `random` with `randomNumber`, or `dynamic` with a synchronous `loader()` returning `[{label, target}]`. Legacy string categories with `itemType`, `categoryParams`, or `groupParam` remain supported. Do not return an empty `categories` array for a static part.

Use `categoryComics.optionList` for filters or an asynchronous `optionLoader(category, param)`. Items contain `label`, `options: ["value-Display label"]`, and optional `showWhen`/`notShowWhen` conditions that match the category name. Rankings also need `categoryComics.ranking.options`.

Recommended navigation targets:

```javascript
({ page: "search", attributes: { text: "author:Example", options: [] } });
({ page: "category", attributes: { category: "Adventure", param: "adventure" } });
```

`comic.onClickTag(namespace, tag)` synchronously returns a target object or `null`. Legacy `{action, keyword, param}` remains compatible. For links, provide `comic.link = {domains: ["example.invalid"], linkToId: url => ...}`, with a synchronous ID-or-null result. `comic.idMatch` is an optional regex string.

## 4. Image loading

Each string returned by `loadEp` can be a URL or stable image key resolved by `onImageLoad`. Downloads default to GET. For additional headers or signed URLs, return a plain configuration object inside `comic`:

```javascript
onImageLoad: (imageKey, comicId, epId) => ({
    url: imageKey,
    headers: { "Referer": "https://example.invalid/" }
})
```

Fields include `url`, `method`, `data`, `headers`, `onResponse`, `modifyImage`, and `onLoadFailed`; see [Image processing](js.en.md#image-processing).

- `comic.onImageLoad` may return a Promise; **`comic.onThumbnailLoad` must currently return synchronously**, not from an `async` function.
- Covers/thumbnails do not inherit body-image headers. Configure `onThumbnailLoad` separately.
- `onResponse(bytes)` transforms response bytes; `modifyImage` is a script string executed in a separate image-processing engine.
- `onLoadFailed()` supplies a new configuration for bounded body-image recovery. Thumbnails support neither it nor `modifyImage`.
- `comic.loadThumbnails(id, next)` returns `{thumbnails: string[], next}`. It lists thumbnails, while `onThumbnailLoad` configures their requests. Cropped thumbnail references can use `url@x=start-end&y=start-end`.

Let the app download, cache, and preload images. Do not download an entire comic into memory during detail loading.

## 5. Accounts, network favorites, and interaction

### Accounts

Optional members of `account`:

| Member | Contract |
|---|---|
| `login(account, password)` | Async login; throw on failure. Normal return values, including false, do not automatically signal failure |
| `logout()` | Clear the source's login data and cookies |
| `loginWithWebview` | `{url, checkStatus(url, title), onLoginSuccess?}`; status and success callbacks are synchronous |
| `loginWithCookies` | `{fields: string[], validate(values)}`; values follow field order; set cookies before validation and return a boolean or Promise |
| `registerWebsite` | Optional registration URL |

Account/password login takes precedence when both it and cookie login are provided. Store source data with `this.loadData/saveData/deleteData`, and read settings with `this.loadSetting`. Do not embed real credentials or cookies in distributed scripts.

### Network favorites

Local favorites, Read Later, and follow tracking are app features. Implement `favorites` only for a service's account favorites.

| Member | Contract |
|---|---|
| `multiFolder` | Required boolean for multiple network folders |
| `addOrDelFavorite(comicId, folderId, isAdding)` | Add/remove; the current bridge passes only three arguments, not the fourth `favoriteId` mentioned in older documentation |
| `loadComics(page, folder)` | `{comics, maxPage}`; folder may be null for a single-folder service |
| `loadNext(next, folder)` | `{comics, next}`; normally choose cursor or numbered pagination, not both |
| `loadFolders(comicId)` | For multiple folders, `{folders: {id: name}, favorited: string[]}`; identify containing folders when a comic ID is provided |
| `addFolder(name)`, `deleteFolder(folderId)` | Optional async operations; throw on failure |
| `isOldToNewSort`, `singleFolderForSingleComic` | Optional booleans describing sort order and whether a comic belongs to only one folder |

Favorite requests require logged-in state. An error containing `Login expired` makes the app attempt re-login and repeat the relevant operation once; other errors are reported as failures.

### Comments, ratings, and archives

These belong to `comic`. Loaders and submission callbacks may return Promises.

| Callback | Return value or purpose |
|---|---|
| `loadComments(comicId, subId, page, replyTo)` | `{comments: Comment[], maxPage?}` |
| `sendComment(comicId, subId, content, replyTo)` | Submit a comment/reply; throw on failure |
| `loadChapterComments(comicId, epId, page, replyTo)` | `{comments: Comment[], maxPage?}` for the reader |
| `sendChapterComment(comicId, epId, content, replyTo)` | Submit chapter comments/replies |
| `likeComic(id, isLike)`, `likeComment(comicId, subId, commentId, isLike)` | Like/unlike |
| `voteComment(id, subId, commentId, isUp, isCancel)` | Return the new numeric score |
| `starRating(id, rating)` | Receive a 0–10 rating; displayed `stars` uses 0–5 |
| `archive.getArchives(comicId)` | `[{id: string, title: string, description: string}]` |
| `archive.getDownloadUrl(comicId, archiveId)` | Nonempty URL string, not `{url: ...}` |

`Comment` supplies `userName` and `content`, with optional `avatar`, `time`, `id`, `replyCount`, `isLiked`, `score`, and `voteStatus` (1/0/-1). Chapter reply buttons require both `id` and `replyCount`. Comment rich text supports `a/b/i/u/s/br/span/img`, limited font styles on spans, and images placed at the end; it is not full HTML rendering.

## 6. Settings and translations

Place these fields inside the source class:

```javascript
settings = {
    quality: {
        title: "Image quality",
        type: "select",
        options: [
            { value: "original", text: "Original" },
            { value: "small", text: "Small" }
        ],
        default: "original"
    },
    compact: { title: "Compact list", type: "switch", default: false },
    keyword: { title: "Keyword", type: "input", default: "", validator: null },
    check: {
        title: "Connection",
        type: "callback",
        buttonText: "Check",
        callback: async () => UI.showMessage(this.translate("Done"))
    }
};

translation = {
    zh_CN: { "Image quality": "图片质量", "Done": "完成" },
    zh_TW: { "Image quality": "圖片品質", "Done": "完成" },
    en: {}
};
```

`input.validator` is a regex string or null. Async callback settings show a loading state until completion. Read values with `this.loadSetting("quality")`; do not overwrite settings using `saveData("setting", ...)`.

The app translates configured source labels. Strings passed to `UI` require explicit `this.translate(...)`. Use dictionary keys such as `zh_CN`, `zh_TW`, and `en`.

Set `comic.enableTagsTranslate: true` to use the app's existing Chinese tag translations when the service uses matching namespaces and terms. This is separate from the source's own `translation` dictionary; unmatched tags remain unchanged.

## 7. Publishing scripts and repositories

Distribute individual raw JS URLs/files, or a UTF-8 JSON **array** catalog:

```json
[
  {
    "name": "Example Source",
    "key": "example_source",
    "version": "1.0.0",
    "fileName": "scripts/example.js",
    "description": "Example catalog entry"
  }
]
```

- `name`, `key`, and `version` are required. Match the script's key and update catalog/script versions together; use three numeric components, optionally followed by a dot or hyphen suffix.
- Supply a nonempty `url` or `fileName`. A nonempty `url` takes precedence. `description` is optional.
- Relative paths resolve against the **final successful response URL**. From `https://example.invalid/repo/index.json`, `scripts/example.js` resolves to `https://example.invalid/repo/scripts/example.js`.
- Pasted/file catalogs with relative paths need the original catalog URL; catalogs containing only absolute HTTP(S) URLs do not. Supplying a base URL for a local list resolves paths but does not automatically save an online repository.
- The main branch previews entries and can save a URL-loaded catalog as an online repository. The linked repository controls version checks and updates. Without a valid linked repository, manual updates can still use the script's `url`.
- One key is installed only once. Multiple catalog variants with the same key can require a user choice; avoid accidental duplicates.
- The main branch skips invalid entries with a summary and rejects catalogs whose entries are all invalid. Updates with a different script key are rejected.
- Version comparison uses project-specific rules, not full npm SemVer range semantics. Avoid relying on complex suffix ordering and verify updates before release.

The app bundles or recommends no third-party repository. Distribute legal scripts and catalogs through your own channels.

## 8. Debugging, errors, and compatibility

Current main branch: Comic Source → Add source → file/paste → preview/install; source menu → Edit script → Save and reload. Stable v1.16.0 uses the earlier file/link entry points. See [local debugging](../development/source_debugging.en.md) for details and version limits.

Inspect your installed template in JS Evaluator:

```javascript
(async () => {
    const source = ComicSource.sources.example_source;
    const result = await source.search.load("demo", [], 1);
    return result;
})()
```

Before publishing, verify:

- First/last search pages, empty results, field types, unchaptered/grouped comics, and actual chapter order.
- Separate cover/body headers, expired image URLs, malformed JSON, and understandable request failures.
- Local favorites, Read Later, follow tracking, downloaded reading, and resume after exit.
- Stable keys and matching catalog/script versions, minimum app version, and actual downloaded content.
- Cancellation, retries, and reload do not apply late results. Keep remote writes such as comments/favorites out of read loaders.

Read-only calls can retry twice after certain transient JSON/network errors; do not add unlimited retries. On the current main branch, explicit installation/reload waits up to 15 seconds for `init()`, the evaluator waits up to 30 seconds, and each follow check up to 45 seconds. Timeouts do not forcibly terminate QuickJS, and cancellation of asynchronous child requests has limits. See [follow checks and cancellation limits](../development/source_debugging.en.md#follow-checks-and-cancellation-limits).

| Symptom | Check |
|---|---|
| Import fails | Raw JS content, entry class/key, valid versions, and minimum app version |
| Search appears but fails | Empty optional callbacks or incorrect JS argument order |
| `Invalid data` | Grouped detail tags, `{comics, ...}` list wrappers, and `{images: string[]}` chapter responses |
| Covers fail but body images work | Synchronous `onThumbnailLoad` and separate cover headers |
| Follow checks never detect changes | Valid real update date; changes confined to the same day |
| Wrong chapter order or transitions | Integer-like keys, duplicate chapter IDs, group order, and image order |
| Missing fourth favorite argument | Current `addOrDelFavorite` receives three arguments |
