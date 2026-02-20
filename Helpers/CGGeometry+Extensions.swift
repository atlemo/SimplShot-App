import AppKit

extension NSScreen {
    /// The screen's frame in the AX coordinate system (top-left origin).
    /// AX API uses a coordinate system where (0,0) is the top-left of the primary screen.
    var frameInAXCoordinates: CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return frame }
        let primaryHeight = primaryScreen.frame.height
        return CGRect(
            x: frame.origin.x,
            y: primaryHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// Find the screen that contains the largest portion of the given rect (in AX coordinates).
    static func screenContaining(axRect: CGRect) -> NSScreen? {
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0

        for screen in NSScreen.screens {
            let screenAX = screen.frameInAXCoordinates
            let intersection = screenAX.intersection(axRect)
            if !intersection.isNull {
                let area = intersection.width * intersection.height
                if area > bestArea {
                    bestArea = area
                    bestScreen = screen
                }
            }
        }
        return bestScreen ?? NSScreen.main
    }
}

/// Nudge a window frame so it stays within screen bounds (AX coordinates).
/// Does not center — only pushes back the minimum distance needed.
func nudgeOntoScreen(windowOrigin: CGPoint, windowSize: CGSize, screenFrame: CGRect) -> CGPoint {
    var origin = windowOrigin

    // Push left if overflowing right edge
    if origin.x + windowSize.width > screenFrame.maxX {
        origin.x = screenFrame.maxX - windowSize.width
    }
    // Push up if overflowing bottom edge
    if origin.y + windowSize.height > screenFrame.maxY {
        origin.y = screenFrame.maxY - windowSize.height
    }
    // Clamp to left/top edges
    origin.x = max(origin.x, screenFrame.minX)
    origin.y = max(origin.y, screenFrame.minY)

    return origin
}
