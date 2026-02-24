# SimplShot

SimplShot is a macOS screenshot app focused on fast captures, clean editing, and repeatable output sizes.

Live site: [www.simplshot.com](https://www.simplshot.com)

## Features
- Capture app windows, batches, or free areas
- Built-in editor with annotations, blur/pixelate, crop, and padding
- Gradients and templates for polished screenshots
- Keyboard shortcut support
- Sparkle auto-updates for direct distribution builds
- Separate App Store target configuration

## Project Structure
- `SimplShot/` app source code
- `SimplShot.xcodeproj/` Xcode project
- `ARCHITECTURE.md` architecture notes

## Requirements
- macOS
- Xcode 15+

## Build
1. Open `SimplShot.xcodeproj` in Xcode.
2. Choose scheme:
   - `SimplShot` for direct distribution (Sparkle-enabled)
   - `SimplShot-AppStore` for App Store builds
3. Build and run.

## License
This project is licensed under the MIT License.
See: [MIT License](https://github.com/atlemo/SimplShot-App?tab=MIT-1-ov-file)
