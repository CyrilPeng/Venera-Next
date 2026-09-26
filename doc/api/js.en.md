# JavaScript API

[中文](js.zh.md) · [Comic Source Guide](comic_source.en.md) · [Local debugging](../development/source_debugging.en.md) · [README](../../README.en.md#developing-comic-sources)

Names and capitalization follow [assets/init.js](../../assets/init.js); host implementations are in [js_engine.dart](../../lib/foundation/js_engine.dart). A `?` in a signature denotes an optional argument or value. Examples use ordinary JavaScript.

## Runtime

Sources execute in QuickJS with standard JavaScript language features and the application APIs below. This is not Node.js or a browser page: do not depend on DOM globals, module loading, npm packages, or full Web APIs. Functions such as fetch and timers are limited app wrappers.

Use plain objects, arrays, strings, numbers, and booleans for data. Binary interfaces use `ArrayBuffer`; use `Uint8Array` to access bytes, return an appropriate buffer, and account for offsets/lengths when slicing views. UI APIs require an active graphical interface; background loading and headless commands should not depend on interaction.

## Network

All request functions return Promises. Transport errors throw; HTTP 4xx/5xx generally still return a response, so check `status` explicitly.

| Call | Response |
|---|---|
| `Network.get(url, headers?, extra?)` | `{status, headers, body: string}` |
| `Network.delete(url, headers?, extra?)` | Same |
| `Network.post(url, headers?, data?, extra?)` | Same |
| `Network.put(url, headers?, data?, extra?)` | Same |
| `Network.patch(url, headers?, data?, extra?)` | Same |
| `Network.sendRequest(method, url, headers?, data?, extra?)` | Same |
| `Network.fetchBytes(method, url, headers?, data?, extra?)` | `{status, headers, body: ArrayBuffer}` |

Headers are plain objects; response header values are strings. Request data may be text, bytes, or a body supported by the host. For JSON, explicitly use `JSON.stringify` and set Content-Type. `extra` passes options to host interceptors, not arbitrary browser RequestInit or Dio timeout settings.

```javascript
(async () => {
    const response = await Network.get("https://example.invalid/api/comics", {
        "Accept": "application/json"
    });
    if (response.status !== 200) {
        throw new Error("HTTP " + response.status);
    }
    return JSON.parse(response.body);
})()
```

Requests can use app cookies, proxy, and caching infrastructure. `headers["cache-time"] = "no"` bypasses short-lived network caching; it does not clear the reader's disk image cache. `headers["prevent-parallel"] = "true"` serializes requests to the same path; use it only when required by the service.

### Cookies

| Call | Behavior |
|---|---|
| `new Cookie({name, value, domain?})` | Create cookie data |
| `Network.setCookies(url, cookies)` | Save a cookie array for a URL |
| `Network.getCookies(url)` | Return its cookies; currently synchronous in the host |
| `Network.deleteCookies(url)` | Delete cookies for the URL |

Cookies and source login state are separate. Setting cookies alone does not complete the source account-login workflow.

### fetch

`fetch(url, {method?, headers?, body?})` returns a Promise with `ok`, `status`, `statusText`, plain-object `headers`, and async `text()`, `json()`, and `arrayBuffer()` methods.

It is not full browser fetch: there is no standard Headers instance, streaming Response, or AbortSignal contract. Do not copy browser code that assumes those capabilities.

## HTML parsing

`new HtmlDocument(htmlString)` parses HTML without executing page scripts.

| Object | Methods or properties |
|---|---|
| `HtmlDocument` | `querySelector(selector)`, `querySelectorAll(selector)`, `getElementById(id)`, `dispose()` |
| `HtmlElement` queries | `querySelector(selector)`, `querySelectorAll(selector)` |
| `HtmlElement` content | `text`, `innerHTML`, `attributes`, `classNames`, `id`, `localName` |
| `HtmlElement` navigation | `children`, `nodes`, `parent`, `previousElementSibling`, `nextElementSibling` |
| `HtmlNode` | `text`, `type`, `toElement()` |

Single-node queries, parent/sibling navigation, and `toElement()` can return null; multi-node queries return arrays. Read attributes with `element.attributes["href"]`, not browser DOM `getAttribute`. The exact names are `innerHTML`, `previousElementSibling`, and `nextElementSibling`; only the document has `getElementById`.

```javascript
(() => {
    const document = new HtmlDocument('<a class="comic" href="/demo">Demo</a>');
    try {
        return document.querySelectorAll("a.comic").map(element => ({
            title: element.text,
            href: element.attributes["href"]
        }));
    } finally {
        document.dispose();
    }
})()
```

Copy required strings/data before disposal, and do not query retained nodes afterward. The app retains a limited number of documents and may evict old ones.

## Source storage and app information

Source instance APIs:

| API | Purpose |
|---|---|
| `this.loadData(key)` | Read persistent source data |
| `this.saveData(key, value)` | Request storage of serializable data; not an awaitable disk-flush guarantee |
| `this.deleteData(key)` | Remove an entry |
| `this.loadSetting(key)` | Read a source setting |
| `this.isLogged` | Source login state recorded by the app |
| `this.translate(text)` | Look up the current locale in the source dictionary, falling back to the original text |
| `ComicSource.sources[key]` | Inspect installed source instances for debugging; the app manages this registry |

`setting` is reserved and cannot be written with `saveData`. See [settings and translations](comic_source.en.md#6-settings-and-translations).

| Global API | Result |
|---|---|
| `APP.version` | App version string |
| `APP.locale` | Host language/region string; simplified/traditional Chinese are `zh_CN`/`zh_TW` |
| `APP.platform` | `android`, `ios`, `windows`, `macos`, or `linux` |
| `setClipboard(text)` | `Promise<void>` |
| `getClipboard()` | `Promise<string or null>` |

Locales without a region may currently appear as `en_null`. `this.translate` uses the full locale; native translation of source labels has its own language fallback. Verify custom UI text in the target languages.

## UI

| API | Return value and behavior |
|---|---|
| `UI.showMessage(message)` | Show a message |
| `UI.showDialog(title, content, actions)` | Show a dialog; the current JS wrapper does not return an awaitable close Promise |
| `UI.launchUrl(url)` | Open an external URL |
| `UI.showLoading(onCancel?)` | Return a dialog ID; without a callback, users cannot cancel |
| `UI.cancelLoading(id)` | Close that loading dialog |
| `UI.showInputDialog(title, validator?, image?)` | `Promise<string or null>`; null on cancellation |
| `UI.showSelectDialog(title, options, initialIndex?)` | `Promise<number or null>`; zero-based index |

Actions are `[{text, callback, style}]`, with `text`, `filled`, or `danger` styles; callbacks may return Promises. The input validator is a function returning an error string or null, unlike regex validators in source settings. The optional image is a URL or ArrayBuffer. UI strings are not translated automatically.

## Convert

These calls are synchronous. Binary data and binary keys use ArrayBuffer. Conversion failures can return null; check results before use.

| API | Result or purpose |
|---|---|
| `Convert.encodeUtf8(text)` / `decodeUtf8(bytes)` | UTF-8 bytes / string |
| `Convert.encodeGbk(text)` / `decodeGbk(bytes)` | GBK bytes / string |
| `Convert.encodeBase64(bytes)` / `decodeBase64(text)` | Base64 string / bytes |
| `Convert.hexEncode(bytes)` | Hex string |
| `Convert.md5(bytes)`, `sha1(bytes)`, `sha256(bytes)`, `sha512(bytes)` | Digest bytes; all methods belong to Convert |
| `Convert.hmac(key, bytes, hash)` | HMAC bytes, with `md5/sha1/sha256/sha512` as hash |
| `Convert.hmacString(key, bytes, hash)` | Hex HMAC string |
| `Convert.encryptAesEcb(bytes, key)` / `decryptAesEcb(bytes, key)` | AES ECB |
| `Convert.encryptAesCbc(bytes, key, iv)` / `decryptAesCbc(bytes, key, iv)` | AES CBC |
| `Convert.encryptAesCfb(bytes, key, iv, blockSize)` / `decryptAesCfb(bytes, key, iv, blockSize)` | AES CFB |
| `Convert.encryptAesOfb(bytes, key, blockSize)` / `decryptAesOfb(bytes, key, blockSize)` | Current OFB API has no separate IV parameter |
| `Convert.decryptRsa(bytes, key)` | RSA PKCS#1 decryption; key is a Base64-encoded PKCS#8 private-key DER string, without PEM headers/footers |

AES does not automatically add/remove padding; prepare block sizes, IVs, and padding according to the service protocol. The current OFB wrapper exposes no separate IV parameter and does not pass an IV to the underlying cipher; verify compatibility with the target protocol before use.

```javascript
Convert.hexEncode(Convert.sha256(Convert.encodeUtf8("example")))
```

## Image processing

Prefer plain objects for ImageLoadingConfig; the constructor is not required.

| Field | Purpose |
|---|---|
| `url?: string` | Request URL; defaults to the image key |
| `method?: string`, `data?`, `headers?: object` | Method (GET by default), body, headers |
| `onResponse(bytes)` | Return transformed image bytes synchronously or asynchronously; supported for body images and thumbnails |
| `modifyImage?: string` | Script defining `function modifyImage(image)` and returning Image; body images only |
| `onLoadFailed()` | Return a new configuration synchronously or asynchronously for bounded retries; body images only |

Use `onResponse` for byte transformations before decoding and `modifyImage` for decoded image rearrangement. The latter runs in a separate engine without source-instance or main-engine closures. Use Image APIs only in this processing context.

| Image API | Purpose |
|---|---|
| `image.width`, `image.height` | Dimensions |
| `image.copyRange(x, y, width, height)` | Copy a rectangular region to a new Image |
| `image.copyAndRotate90()` | Copy and rotate 90 degrees |
| `image.fillImageAt(x, y, other)` | Place another image |
| `image.fillImageRangeAt(x, y, other, srcX, srcY, width, height)` | Copy a region of another image |
| `Image.empty(width, height)` | Create an empty image |

Keep coordinates and dimensions within bounds. Avoid unrelated networking or UI in image callbacks; leave ordinary reading-mode changes to the reader.

## Logs, timers, and computation

| API | Behavior |
|---|---|
| `log(level, title, content)` | Application log with `info`, `warning`, or `error` |
| `console.log(value)`, `console.warn(value)`, `console.error(value)` | Single-argument wrappers, not a complete browser console |
| `createUuid()` | A new time-based UUID on each call; persist it if reuse is needed |
| `randomInt(min, max)`, `randomDouble(min, max)` | Random-value helpers, not for security tokens |
| `setTimeout(callback, delayMs)` | Simple delay; no browser timer ID or matching clearTimeout |
| `setInterval(callback, delayMs)` | Return an app timer object; stop it with `timer.cancel()` |
| `compute(functionCode, ...args)` | Promise; evaluate a function string in a background JS engine pool and pass arguments separately |

```javascript
compute("(a, b) => a + b", 2, 3)
```

Use compute for synchronous calculations returning transferable data. Do not pass a function object, access main-engine closures, assume an installed source instance exists, or start long-lived asynchronous network work.

Read loaders may be retried by the app. Do not perform remote writes inside them. Timeouts cannot forcibly interrupt synchronous infinite loops; see [cancellation limits](../development/source_debugging.en.md#follow-checks-and-cancellation-limits).

## Business data types

See the [Comic Source Guide](comic_source.en.md#2-data-and-chapter-rules) for Comic, ComicDetails, Comment, chapters, pagination wrappers, and navigation targets. In particular:

- Details require object-shaped tags, using `{}` when empty; list tags are arrays.
- `loadEp` returns `{images: string[]}`.
- `onThumbnailLoad` is synchronous; `onImageLoad` may be asynchronous.
- `search.loadNext` returns `next`; `addOrDelFavorite` currently receives three arguments.
