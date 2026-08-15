# Changelog

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
