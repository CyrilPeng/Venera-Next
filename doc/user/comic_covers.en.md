# Comic cover updates

[简体中文](comic_covers.zh.md)

Online comic covers can change on the source website. The app displays the existing cover first and validates only covers currently on screen. Successful validation replaces the image. The default interval is 24 hours, with at most two concurrent updates. Scrolling away, hiding the page or backgrounding the app stops presentation-related updates for that cover. Failed attempts retain the old image and can retry after five minutes while visible.

Opening details, refreshing comic information or checking for updates publishes a new cover URL to existing favorites and history for that comic. Cover publication preserves favorite order, timestamps, tags and reading progress.

Choose **Refresh cover** from the menu at the top right of the comic details page to fetch the current cover URL and image immediately. The menu button shows progress and the app reports success or failure. A failed attempt leaves the previous cover available.

Automatic validation uses HTTP `ETag` or `Last-Modified` when supported. An unchanged response keeps the existing image. Changed image content at the same URL is also detected during validation or an explicit refresh. Source headers, signed URLs and image transformation hooks remain in effect.

Imported comics and local covers of downloaded comics retain their original files and do not automatically access the network. Online favorites and history can continue updating their online covers.
