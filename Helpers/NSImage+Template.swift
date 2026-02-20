import AppKit

extension NSImage {
    func resized(to targetSize: NSSize) -> NSImage {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        self.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: self.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }
}
