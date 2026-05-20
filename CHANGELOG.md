# Changelog

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
