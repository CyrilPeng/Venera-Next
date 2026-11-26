# Saving reader images

中文：[阅读器保存图片](reader_images.zh.md)

On Windows, Linux and Android, choose a fixed folder under Settings → Reading → Image save directory. The bottom save button and the context-menu Save Image action then write directly to that folder and show the saved location. Until a folder is configured, the system save dialog asks for a location each time.

Hold the bottom save button, or choose Save image as in the context menu, to select another location for that image. Ask every time in settings clears the fixed folder.

The folder belongs to this device and is excluded from portable application backups and WebDAV transfers. Android uses the system's persisted document-tree permission. A removed folder, revoked permission or provider that no longer supports writing prompts for a replacement folder while retaining the selected original image. Cancelling creates no image.

Saving retains the original bytes and actual extension. Names include the title, chapter and original page number, such as `Book_EP2_P13.jpg`. Invalid filename characters are replaced and long titles shortened while retaining the chapter, page and extension. Collisions add a number, such as `Book_EP2_P13 (1).jpg`, preserving existing files.

Write failures are reported. Newly created outputs with confirmed ownership are cleaned up on failure. Application shutdown joins already started writes and document-provider completion.

Other platforms use their system save entry.
