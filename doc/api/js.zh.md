# JavaScript API

[English](js.en.md) · [漫画源编写指南](comic_source.zh.md) · [本地调试](../development/source_debugging.zh.md) · [README](../../README.md#漫画源开发)

本文是 VeneraNext 扩展运行时参考，函数名与大小写以 [assets/init.js](../../assets/init.js) 为准；宿主实现见 [js_engine.dart](../../lib/foundation/js_engine.dart)。接口签名中的 `?` 表示可选参数或值，代码示例使用普通 JavaScript。

## 运行环境

源脚本在 QuickJS 中执行，具有标准 JavaScript 语言能力，以及本文列出的应用 API。它不是浏览器页面或 Node.js：没有可依赖的 DOM 全局对象、模块加载器、npm 包或完整 Web API。`fetch`、定时器等是应用提供的有限封装。

数据应使用普通对象、数组、字符串、数字和布尔值。二进制接口采用 `ArrayBuffer`；操作字节时可构造 `Uint8Array`，返回给宿主时使用完整 buffer，注意切片视图的 offset/length。UI API 需要活动的图形界面，后台加载和无头模式不应依赖用户交互。

## Network

所有网络请求函数都返回 Promise。传输错误会抛出异常；HTTP 4xx/5xx 通常仍返回响应，扩展必须自己检查 `status`。

| 调用 | 返回 |
|---|---|
| `Network.get(url, headers?, extra?)` | `{status, headers, body: string}` |
| `Network.delete(url, headers?, extra?)` | 同上 |
| `Network.post(url, headers?, data?, extra?)` | 同上 |
| `Network.put(url, headers?, data?, extra?)` | 同上 |
| `Network.patch(url, headers?, data?, extra?)` | 同上 |
| `Network.sendRequest(method, url, headers?, data?, extra?)` | 同上 |
| `Network.fetchBytes(method, url, headers?, data?, extra?)` | `{status, headers, body: ArrayBuffer}` |

`headers` 为普通对象，响应头为字符串值。`data` 取决于接口，可为文本、字节或宿主支持的请求体；提交 JSON 时显式 `JSON.stringify` 并设置 Content-Type。`extra` 是传给宿主拦截器的选项，不是通用浏览器 RequestInit，也不是任意 Dio 超时配置。

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

读取接口可利用应用的 Cookie、代理和缓存基础能力。`headers["cache-time"] = "no"` 可要求跳过短期网络缓存；该设置不是阅读器图片磁盘缓存的清理指令。`headers["prevent-parallel"] = "true"` 会串行处理相同请求路径，应只在服务确有需要时使用。

### Cookie

| 调用 | 说明 |
|---|---|
| `new Cookie({name, value, domain?})` | 构造 Cookie 数据 |
| `Network.setCookies(url, cookies)` | 为 URL 保存 Cookie 数组 |
| `Network.getCookies(url)` | 返回当前 URL 的 Cookie 数组；当前宿主为同步返回 |
| `Network.deleteCookies(url)` | 删除对应 URL 的 Cookie |

Cookie 与登录状态由不同 API 管理；自行设置 Cookie 不等同于完成源的账号登录流程。

### fetch

`fetch(url, {method?, headers?, body?})` 返回 Promise，可读取 `ok`、`status`、`statusText`、普通对象 `headers`，以及异步方法 `text()`、`json()`、`arrayBuffer()`。

它只包装了这些能力，不是完整浏览器 fetch：没有标准 `Headers` 实例、流式 Response 或 `AbortSignal` 契约。不要照搬依赖这些能力的浏览器代码。

## HTML 解析

`new HtmlDocument(htmlString)` 解析 HTML 字符串，不执行页面脚本。

| 对象 | 方法或属性 |
|---|---|
| `HtmlDocument` | `querySelector(selector)`、`querySelectorAll(selector)`、`getElementById(id)`、`dispose()` |
| `HtmlElement` 查询 | `querySelector(selector)`、`querySelectorAll(selector)` |
| `HtmlElement` 文本与属性 | `text`、`innerHTML`、`attributes`、`classNames`、`id`、`localName` |
| `HtmlElement` 导航 | `children`、`nodes`、`parent`、`previousElementSibling`、`nextElementSibling` |
| `HtmlNode` | `text`、`type`、`toElement()` |

单节点查询、父节点/相邻节点、`toElement()` 可能返回 `null`；多节点查询返回数组。属性通过 `element.attributes["href"]` 读取，没有浏览器 DOM 的 `getAttribute`。注意是 `innerHTML`、`previousElementSibling`、`nextElementSibling`；`getElementById` 只在文档对象上。

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

先复制所需的字符串和数据再 `dispose()`；释放后不要保留节点继续查询。应用只保留有限数量的文档，及时释放可避免旧文档被回收。

## 源数据与应用信息

以下为源实例方法：

| API | 说明 |
|---|---|
| `this.loadData(key)` | 读取该源持久化数据 |
| `this.saveData(key, value)` | 请求保存可序列化数据；不是可等待的落盘完成承诺 |
| `this.deleteData(key)` | 删除该源数据项 |
| `this.loadSetting(key)` | 读取源设置 |
| `this.isLogged` | 应用记录的源登录状态 |
| `this.translate(text)` | 按当前 locale 查该源的翻译词典，找不到时返回原文 |
| `ComicSource.sources[key]` | 调试时访问已安装源实例；应用管理该注册表 |

`setting` 是保留的数据键，不能通过 `saveData` 写入。字段与设置定义见[漫画源编写指南](comic_source.zh.md#6-设置与翻译)。

| 全局 API | 返回 |
|---|---|
| `APP.version` | 应用版本字符串 |
| `APP.locale` | 当前宿主的语言/地区字符串，简繁中文为 `zh_CN`、`zh_TW` |
| `APP.platform` | `android`、`ios`、`windows`、`macos`、`linux` |
| `setClipboard(text)` | `Promise<void>` |
| `getClipboard()` | `Promise<string或null>` |

当前宿主的无地区语言可能返回如 `en_null`；`this.translate` 按完整 locale 查找，而应用原生源标签翻译另有语言回退。需要多语言 UI 文案时请在目标语言实测。

## UI

| API | 返回与用法 |
|---|---|
| `UI.showMessage(message)` | 显示提示 |
| `UI.showDialog(title, content, actions)` | 显示对话框；当前 JS 包装不返回可等待的关闭 Promise |
| `UI.launchUrl(url)` | 打开外部 URL |
| `UI.showLoading(onCancel?)` | 返回加载框 ID；未提供回调时不能由用户取消 |
| `UI.cancelLoading(id)` | 关闭相应加载框 |
| `UI.showInputDialog(title, validator?, image?)` | `Promise<string或null>`，取消返回 null |
| `UI.showSelectDialog(title, options, initialIndex?)` | `Promise<number或null>`，索引从 0 开始 |

`actions` 为 `[{text, callback, style}]`，样式为 `text`、`filled` 或 `danger`；回调可返回 Promise。`validator` 是返回错误文本或 null 的函数，与源设置中正则字符串 validator 不同。`image` 可为图片 URL 或 ArrayBuffer。UI 字符串不自动翻译。

## Convert

以下函数为同步调用。`bytes` 和二进制密钥表示 ArrayBuffer，转换失败可能返回 null，应在使用结果前检查。

| API | 返回或用途 |
|---|---|
| `Convert.encodeUtf8(text)` / `decodeUtf8(bytes)` | UTF-8 字节 / 字符串 |
| `Convert.encodeGbk(text)` / `decodeGbk(bytes)` | GBK 字节 / 字符串 |
| `Convert.encodeBase64(bytes)` / `decodeBase64(text)` | Base64 字符串 / 字节 |
| `Convert.hexEncode(bytes)` | 十六进制字符串 |
| `Convert.md5(bytes)`、`sha1(bytes)`、`sha256(bytes)`、`sha512(bytes)` | 摘要字节；方法均在 Convert 上 |
| `Convert.hmac(key, bytes, hash)` | HMAC 字节，hash 使用 `md5/sha1/sha256/sha512` |
| `Convert.hmacString(key, bytes, hash)` | HMAC 十六进制字符串 |
| `Convert.encryptAesEcb(bytes, key)` / `decryptAesEcb(bytes, key)` | AES ECB |
| `Convert.encryptAesCbc(bytes, key, iv)` / `decryptAesCbc(bytes, key, iv)` | AES CBC |
| `Convert.encryptAesCfb(bytes, key, iv, blockSize)` / `decryptAesCfb(bytes, key, iv, blockSize)` | AES CFB |
| `Convert.encryptAesOfb(bytes, key, blockSize)` / `decryptAesOfb(bytes, key, blockSize)` | 当前 OFB 接口没有独立 iv 参数 |
| `Convert.decryptRsa(bytes, key)` | RSA PKCS#1 解密；key 是 Base64 编码的 PKCS#8 私钥 DER 字符串，不是带 PEM 头尾的文本 |

AES 接口不自动补齐/去除 padding；按服务协议准备块大小、IV 和填充。当前 OFB 包装没有独立的 IV 参数，也未向底层传入 IV；使用前应验证与目标协议的兼容性。

```javascript
Convert.hexEncode(Convert.sha256(Convert.encodeUtf8("example")))
```

## 图片处理

`ImageLoadingConfig` 推荐直接使用普通对象，不要求调用构造函数：

| 字段 | 用途 |
|---|---|
| `url?: string` | 实际请求地址，缺省使用 image key |
| `method?: string`、`data?`、`headers?: object` | 请求方法（默认 GET）、请求体、请求头 |
| `onResponse(bytes)` | 同步或异步返回处理后的图片字节；正文、缩略图均支持 |
| `modifyImage?: string` | 定义 `function modifyImage(image)` 的脚本字符串，返回 Image；仅正文 |
| `onLoadFailed()` | 同步或异步返回新配置，用于有限重试；仅正文 |

图片解码前可用 `onResponse` 做字节转换；解码后的图像重排使用 `modifyImage`。它在独立引擎运行，不能捕获源实例或主引擎闭包。`Image` API 只应在这个图片处理上下文使用。

| Image API | 功能 |
|---|---|
| `image.width`、`image.height` | 尺寸 |
| `image.copyRange(x, y, width, height)` | 复制矩形区域，得到新 Image |
| `image.copyAndRotate90()` | 复制并旋转 90 度 |
| `image.fillImageAt(x, y, other)` | 将另一张图写入当前位置 |
| `image.fillImageRangeAt(x, y, other, srcX, srcY, width, height)` | 复制另一张图的指定区域 |
| `Image.empty(width, height)` | 创建空白图片 |

坐标和尺寸需落在图片边界内。回调不应再进行无关网络请求或 UI 操作；一般阅读模式调整交由阅读器完成。

## 日志、计时与计算

| API | 行为 |
|---|---|
| `log(level, title, content)` | 写应用日志；级别 `info`、`warning`、`error` |
| `console.log(value)`、`console.warn(value)`、`console.error(value)` | 单参数包装，不是完整浏览器 console |
| `createUuid()` | 每次生成新的基于时间的 UUID；需复用时自行保存 |
| `randomInt(min, max)`、`randomDouble(min, max)` | 随机数工具，不用于安全令牌 |
| `setTimeout(callback, delayMs)` | 简单延迟，不返回浏览器定时器 ID，也没有配套 clearTimeout |
| `setInterval(callback, delayMs)` | 返回应用 timer 对象，通过 `timer.cancel()` 停止 |
| `compute(functionCode, ...args)` | Promise；函数代码字符串在后台 JS 引擎池运行，参数分别传入 |

```javascript
compute("(a, b) => a + b", 2, 3)
```

`compute` 应执行返回可传输数据的同步计算，不能传函数对象、访问主引擎闭包或假定源实例存在。不应以它启动长期异步网络任务。

加载接口可能被应用有限重试；不要在只读加载中提交远端写操作。超时不会强制中断同步死循环，详情见[本地调试的取消边界](../development/source_debugging.zh.md#追更调度与取消边界)。

## 业务数据类型

`Comic`、`ComicDetails`、`Comment`、章节结构、分页包装和跳转目标的字段见[漫画源编写指南](comic_source.zh.md#2-数据与章节规则)。特别注意：

- 详情必须有对象形状的 `tags`（没有标签时用 `{}`）；列表 tags 使用数组。
- `loadEp` 返回 `{images: string[]}`。
- `onThumbnailLoad` 同步返回配置，而 `onImageLoad` 可异步。
- `search.loadNext` 返回 `next`；收藏的 `addOrDelFavorite` 当前接收三个参数。
