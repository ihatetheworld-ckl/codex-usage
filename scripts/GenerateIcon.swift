import AppKit

@main
struct GenerateIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(1) }
        let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let assets = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let bitmap = Brand.iconBitmap(pixels: points * scale)
                try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
        try Brand.iconBitmap(pixels: 512).representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("AppIcon.png"))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(NSRect(x: 0, y: 0, width: 512, height: 512))
        Brand.drawMark(in: NSRect(x: 0, y: 0, width: 512, height: 512))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("logo-mark.png"))
    }
}
