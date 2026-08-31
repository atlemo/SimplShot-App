# Changelog

## Unreleased

### Add, Remove and Reorder PDF Pages
The page strip is now a real page organiser. The × on a thumbnail deletes the page from the document rather than just hiding its thumbnail — the page disappears from the page count, continuous scroll, Find and the outline as well, and is gone from the saved file. Dragging thumbnails reorders the document itself, so the new order is what gets exported. And pages can be added: drag a PDF or an image onto the strip and drop it wherever the caret appears, or use the Add Pages tile at the bottom of the strip to pick files. A dropped PDF contributes all of its pages, an image becomes a single page at its own resolution, and everything lands in the open document, so page numbering, Find and the single-file save keep working across the additions. Nothing touches the file on disk until you save. The strip now also appears for single-page PDFs, since that is where pages are added.

### Saving a PDF Keeps Its Outline, Links and Metadata
Saving used to rebuild the document from scratch and draw the pages into it, which silently discarded the table of contents, every hyperlink and the document's metadata. That only affected annotated documents before; with page editing it would have hit anyone who merely reordered pages. A document with nothing composited over it — pages added, deleted or reordered — is now saved byte-for-byte intact, so nothing is re-encoded at all. When there are annotations or a watermark the pages still have to be redrawn, but the outline, links and metadata are carried across to the result instead of being dropped. Deleting a page also removes its table-of-contents entry rather than leaving one that jumps to the front of the document.

## 2026-08-31 (1.7.6)

### Hide the Menu Bar Icon
Settings › General can now take SimplShot's icon out of the menu bar, for people who drive the whole app from keyboard shortcuts. SimplShot keeps running in the background, and opening it from Spotlight brings the menu up for as long as it is needed — the icon reveals itself only to anchor the menu and hides again as soon as the menu closes, so the preference survives the visit. Suggested by [Matt Ormianek](https://github.com/MattOrmianek).

### Check for Updates in Settings
Check for Updates is now in Settings › About as well as the menu bar, so an update never depends on the icon being visible.

## 2026-08-24 (1.7.5)

### Crop Mode Takes Over the Sidebar
Starting a crop now replaces the entire sidebar with a dedicated crop panel, in Annotate and Edit mode alike, instead of adding a small crop section to whichever panel happened to be open. Straighten keeps the same slider used by the Light, Color and Detail adjustments; Flip and Rotate sit beside it; and the aspect ratios are listed out with a checkmark rather than hidden behind a pop-up menu, with a Landscape/Portrait switch below them. Apply and Cancel are pinned to the bottom of the panel. Both modes share one panel, so the crop controls are identical wherever you start from.

### Aspect Ratio Survives Flipping and Rotating
Flipping or rotating mid-crop used to drop the pending selection back to the whole canvas — with a background applied, the crop even jumped outside its own bounds and covered the wallpaper until you nudged a handle. The selection now follows the image through both: a flip mirrors it in place at the same size, and a rotate carries it to where the content went while keeping the shape of whichever ratio you locked.

### Flip
A screenshot can be mirrored left to right or top to bottom from the crop panel. Like the 90° rotation and the fine straighten, the flip is non-destructive: the raw image is never modified, annotations are mirrored along with it so they stay glued to the content, and flipping again puts everything back. It applies to the screenshot only, so a template background is unaffected, and it carries through to raster export, the clipboard, printing and the thumbnail strip.

## 2026-08-20 (1.7.4)

### Capture History
The menu bar now offers Capture History: your last 10 captures and opened files as a film strip of thumbnails. Hovering an entry reveals a Restore button that reopens the image with every annotation still editable, rather than as a flat file. Editable state lives in memory, so entries restored after a relaunch reopen the file itself; the list of files persists across launches.

### Even Padding When Aligning
Aligning the screenshot to an edge now places it flush against that edge while every other side keeps its exact padding. Previously the opposite side absorbed the difference and ended up with double the gap.

### Pixelation Matches the Preview
Pixelated regions now export exactly as they appear in the editor — saved and copied images use the same soft mosaic blocks as the on-screen preview, instead of a slightly different block pattern.

### Lower Memory Use
Editing sessions that are not on screen no longer hold their decoded bitmaps. A resting session keeps a losslessly compressed (PNG) copy of its raw image — roughly 5–15% of the decoded size — and re-derives its display bitmaps on demand, so a long day of captures no longer accumulates hundreds of megabytes.

## 2026-08-15 (1.7.3)

### Fixed: ⌘C stopped working in other apps
The Save & Copy shortcut introduced in 1.7.2 was registered as a system-wide hotkey by mistake, so while SimplShot was running it intercepted ⌘C in every other app — Copy would appear to do nothing at all. The shortcut is now confined to the editor window as intended, and Copy works normally everywhere else. Quitting SimplShot always released the key, so no cleanup is needed; simply update.

## 2026-08-12 (1.7.2)

### Customizable Save & Copy Shortcut
The editor's Save & Copy button now has a keyboard shortcut, ⌘C by default: it saves the image, copies it to the clipboard and closes the window, exactly as clicking the button does. The binding lives in a new Editor section under Settings › Shortcuts and can be changed or cleared. It is matched by the editor window's own key monitor rather than registered as a global hotkey, so it only fires while an editor window is focused, never while you are editing text, and it steps aside for ⌘C when PDF text is selected.

### German Localization
German joins English, French, Japanese, Russian and Simplified Chinese. The whole interface — menus, the editor, alerts, Settings and the release notes — is translated, and Deutsch is selectable in Settings › General or picked up automatically from your macOS language preferences.

## 2026-07-07 (1.7.0)

### Bendable Curved Arrows
Curved arrows now have an editable bow. Selecting a curved arrow shows a third, accent-colored handle at the middle of the curve — drag it to bend the shaft exactly where you want it, with the curve staying under the cursor. Pushing the handle back toward the straight line snaps the arrow perfectly straight. The curvature is stored relative to the arrow's endpoints, so it survives moving, resizing, cropping, rotating and straightening.

### Double Arrow Style
A new arrow style with filled arrowheads at both ends. Double arrows start straight and can be bent with the same middle handle as curved arrows. Both curved and double arrows now render as a single filled outline path, so semi-transparent colors stay uniform with no seams between shaft and heads — in the editor, in raster export and in vector PDF export alike.

### Hand-Drawn Sketch Arrows
The Sketch arrow style has been redrawn as a gritty, variable-width ink stroke: a tapering shaft with roughened edges, a thin charcoal-style overdraw strand, and arrowhead flicks that thin out like real pen strokes. Each arrow gets its own stable texture (seeded per annotation), so it never shimmers while editing and exports pixel-identically to the preview.

### Angle Tool (Protractor)
A new measurement tool for angles. Drag between two points to place the outer legs, then pull the middle handle to the corner being measured — SimplShot draws the two rays, a dashed arc spanning the angle, and a degree pill centered on the arc. Hold Shift while dragging any of the three handles to snap the measured angle to 45° steps (dragging an outer point rotates it around the corner; dragging the corner finds the nearest position that hits the target angle exactly).

## 2026-05-20

### Annotation Bounds Clipping
Annotations (shapes, arrows, text, etc.) are now visually clipped to the image boundaries. Shapes that extend beyond the edge of the screenshot are cropped at the image border rather than overflowing into the surrounding editor area.

### Snap-to-Center Alignment
When dragging an annotation, it now snaps to the horizontal and vertical center of the image. Dashed guide lines appear when the annotation's center aligns with the image midpoint, making it easy to position elements precisely.

### Option+Drag to Duplicate
Hold Option (Alt) and drag any annotation to create a duplicate. The original stays in place while you drag the copy to a new position. A copy cursor appears whenever Option is held in annotate mode to indicate this behavior.

### Shift+Drag Axis Lock
Hold Shift while dragging an annotation to constrain movement to a single axis. The dominant direction (horizontal or vertical) is locked based on initial drag movement, matching the behavior of standard design tools.

### Arrow Key Nudging
Selected annotations can now be nudged with the arrow keys:
- Arrow keys move the annotation by 1px
- Shift+Arrow moves by 10px

### PDF Thumbnail Previews
Multi-page PDF documents now show thumbnail previews for all pages immediately upon opening. Previously, thumbnails only appeared after navigating to each page.

### PDF Page Reordering
Pages in a multi-page PDF can now be reordered by dragging and dropping thumbnails in the sidebar strip. Page numbers update to reflect the new order, and PDF export respects the reordered sequence.
