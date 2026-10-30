import AppKit

/// Original CU monogram: a surrounding C and a replenishing U.
enum Brand {
    static let ink = NSColor(srgbRed: 0.055, green: 0.25, blue: 0.28, alpha: 1)
    static let mint = NSColor(srgbRed: 0.10, green: 0.65, blue: 0.58, alpha: 1)

    static func drawMark(in rect: NSRect, monochrome: Bool = false) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.maxY)
        transform.scaleX(by: rect.width / 256, yBy: -rect.height / 256)
        transform.concat()
        let c = NSBezierPath()
        c.move(to: NSPoint(x: 187, y: 74))
        c.curve(to: NSPoint(x: 82, y: 68), controlPoint1: NSPoint(x: 158, y: 45), controlPoint2: NSPoint(x: 113, y: 45))
        c.curve(to: NSPoint(x: 94, y: 189), controlPoint1: NSPoint(x: 44, y: 104), controlPoint2: NSPoint(x: 53, y: 164))
        c.curve(to: NSPoint(x: 187, y: 181), controlPoint1: NSPoint(x: 124, y: 208), controlPoint2: NSPoint(x: 164, y: 202))
        c.lineWidth = 20; c.lineCapStyle = .round; c.lineJoinStyle = .round
        (monochrome ? NSColor.labelColor : ink).setStroke(); c.stroke()
        let u = NSBezierPath()
        u.move(to: NSPoint(x: 110, y: 99)); u.line(to: NSPoint(x: 110, y: 139))
        u.curve(to: NSPoint(x: 132, y: 163), controlPoint1: NSPoint(x: 110, y: 154), controlPoint2: NSPoint(x: 118, y: 163))
        u.curve(to: NSPoint(x: 155, y: 139), controlPoint1: NSPoint(x: 146, y: 163), controlPoint2: NSPoint(x: 155, y: 154))
        u.line(to: NSPoint(x: 155, y: 99))
        u.lineWidth = 15; u.lineCapStyle = .round; u.lineJoinStyle = .round
        (monochrome ? NSColor.labelColor : mint).setStroke(); u.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func markImage(size: CGFloat = 24, template: Bool = false) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawMark(in: rect, monochrome: template)
            return true
        }
        result.isTemplate = template
        return result
    }

    static func iconBitmap(pixels: Int) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let edge = CGFloat(pixels)
        NSGraphicsContext.current?.cgContext.clear(NSRect(x: 0, y: 0, width: edge, height: edge))
        let tile = NSBezierPath(roundedRect: NSRect(x: edge * 0.045, y: edge * 0.045, width: edge * 0.91, height: edge * 0.91),
                                xRadius: edge * 0.205, yRadius: edge * 0.205)
        NSGradient(starting: NSColor(srgbRed: 0.91, green: 0.99, blue: 0.97, alpha: 1),
                   ending: NSColor(srgbRed: 0.76, green: 0.92, blue: 0.94, alpha: 1))!.draw(in: tile, angle: -65)
        NSColor.white.withAlphaComponent(0.75).setStroke(); tile.lineWidth = max(0.5, edge / 256); tile.stroke()
        drawMark(in: NSRect(x: edge * 0.03, y: edge * 0.03, width: edge * 0.94, height: edge * 0.94))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
