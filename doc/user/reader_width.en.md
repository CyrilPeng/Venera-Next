# Shrinking strip comics with side margins

中文：[条漫左右边距](reader_width.zh.md)

If strip comics look too large on a tablet, increase their side margins to shrink the images. In Settings → Reader or the reader's settings panel, select Continuous (Top to Bottom) or Waterfall (Top to Bottom) and adjust **Shrink strip comics (margin per side)**. The setting also appears when automatic reader mode preferences include either vertical flow mode. Earlier versions call it **Side margins (each side)**.

Each side supports 0%–30%, with a default of 0%. At 20%, each side takes 20% of the original content width, leaving centered images at 60% width with proportional height. This setting applies only to vertical continuous and waterfall reading.

| Margin per side | Image width |
|---|---|
| 0% | 100% of the original |
| 10% | 80% of the original |
| 20% | 60% of the original |
| 30% | 40% of the original |

If **Limit image width** is enabled, that limit is applied first, then the side margins. Percentages therefore refer to the limited content width, which may be narrower than the screen.

Both margins and the width limit follow comic-specific, device-specific, then global settings in priority order. Adjusting margins during reading updates the layout immediately. Set the value back to 0% to remove the extra margins; the existing width limit still applies.

The current chapter and page are retained. Pinch zoom remains available for temporarily viewing details; use side margins for a persistent smaller strip layout.

## Crop white side borders (unreleased)

In vertical Continuous or Waterfall mode, enable Crop white side borders in reader settings. It is off by default. Detection removes continuous near-white empty columns on the left and right so content can use more width; the top and bottom remain intact. Side margins and the width limit can still be used together with cropping.

The detector checks each complete column and retains a buffer. Any distinct text or image pixel limits cropping at that edge. Tiny margins, margins wider than one quarter per side, blank pages, animated images, and images beyond the detection memory budget retain their original display. Some borders will consequently remain. Double-page splitting keeps the original center and half-page order.

The image is displayed first; detection then runs in the background and updates its layout. Turn the option off to restore the complete display. Comic files, downloads, saved images, and exports retain their originals. The option follows global, device, and per-comic settings and their existing backup and synchronization rules.
