# Automatic Reader Mode

中文说明：[自动选择阅读模式](automatic_reader_mode.zh.md)

Enable **Choose reading mode automatically** under **Settings → Reader**, then choose separate preferences for:

- **Paged comics**: initially Page turn (Right to Left).
- **Long-strip comics**: initially Continuous (Top to Bottom). Waterfall is also available for reading across chapters.
- **When layout is unknown**: uses your existing default reading mode.

This feature is off by default, so upgrading does not change existing reading behavior. Enable device-specific settings to use different preferences on the current device.

## Choosing a mode for one comic

Use **Reading mode for this comic** at the top of the reader settings to select a mode without enabling other comic-specific settings. This choice affects only the current comic and takes priority over automatic recognition. Select **Follow default** to restore automatic selection, or the device/global default when automatic selection is disabled.

Previously enabled comic-specific reading modes remain effective. Other comic-specific settings, such as brightness and gestures, do not prevent automatic mode selection.

## Recognition and switching

Recognition uses image dimensions only. It does not use source declarations, tags, language, or image contents. Online images reuse the existing downloader and cache. Local images are read to inspect their encoded dimensions without decoding full bitmaps for recognition.

Recognition skips the first image of the current chapter and samples up to six subsequent images, reading at most two at a time. The entire attempt has an eight-second limit. Leaving the reader cancels active downloads and stops further sampling. At least four valid images are required; classification uses **height ÷ width**:

- At least 80% of samples with a ratio of 2.5 or greater indicate a long-strip comic.
- At least 80% of samples with ratios between 0.5 and 2.0, with no image reaching 2.5, indicate a paged comic.
- Other combinations remain unknown. Multiple samples reduce the influence of covers, spreads, and unusual pages. Display scaling and double-page splitting do not affect the sampled dimensions.

These conservative heuristics do not guarantee correct recognition. A long-strip comic sliced into short images may be classified as paged; four-panel comics, stitched pages, and mixed layouts may also be misclassified. You can choose a mode for the comic directly or select **Identify again from this chapter**.

The first attempt adds at most 700 milliseconds to opening the comic. After that, the default mode opens while recognition continues in the background. Once recognized, the reader immediately switches to your corresponding preference if automatic selection is still enabled and no comic-specific mode has been selected. A toast names the selected mode, such as “Switched to Continuous (Top to Bottom)”; no extra confirmation is needed. No toast appears if the current mode already matches. Switching preserves the chapter and corresponding source image, but not the exact pixel offset within a long image.

Reliable results are saved per source and comic ID and reused on the next opening. After changing the general paged or long-strip preference, comics set to follow the default use the new preference the next time they open. Unknown layouts can be sampled again in later chapters. Downloaded online comics reuse the result when they retain the same identity.
