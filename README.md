# SimplShot

SimplShot is a macOS screenshot app focused on fast captures, clean editing, and repeatable output sizes.

Live site: [www.simplshot.com](https://www.simplshot.com)

## Features
- Capture individual windows, batch multiple windows, or select a free area
- Annotations: arrows, shapes, lines, free draw, text, numbered steps, and measurements
- Blur/pixelate and spotlight tools for redacting or highlighting regions
- Crop and padding controls
- Templates with gradient backgrounds, drop shadows, rounded corners, and positioning
- Watermark support with configurable placement
- Screen color picker (eyedropper)
- PDF support with multi-page thumbnails, page reordering, and PDF export
- Drag and drop files onto the status bar icon to open
- Print support
- Snap-to-center guides, axis-lock dragging, Option+drag to duplicate, and arrow key nudging for annotations
- Global keyboard shortcuts
- Sparkle auto-updates for direct distribution builds

## Project Structure
- `SimplShot/` app source code
- `SimplShot.xcodeproj/` Xcode project
- `ARCHITECTURE.md` architecture notes

## Install with Homebrew
```bash
brew tap atlemo/simplshot
brew install --cask simplshot
```

## Requirements
- macOS 26.0 or later
- Xcode 15+

## Build
1. Open `SimplShot.xcodeproj` in Xcode.
2. Make sure you're building on macOS 26.0 or later.
3. Choose scheme:
   - `SimplShot` for direct distribution (Sparkle-enabled)
   - `SimplShot-AppStore` for App Store builds
4. Build and run.

## License
This project is licensed under the MIT License.
See: [MIT License](https://github.com/atlemo/SimplShot-App?tab=MIT-1-ov-file)
