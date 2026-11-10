import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels)
        let shape = NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88),
            xRadius: s * 0.21, yRadius: s * 0.21)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.44, blue: 0.39, alpha: 1),
            ending: NSColor(calibratedRed: 0.06, green: 0.23, blue: 0.22, alpha: 1))!
        gradient.draw(in: shape, angle: -90)
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        for (i, height) in ([CGFloat]([0.20, 0.36, 0.52, 0.36, 0.20])).enumerated() {
            let h = s * height
            NSBezierPath(roundedRect: NSRect(x: s * (0.27 + CGFloat(i) * 0.10), y: (s - h) / 2,
                width: s * 0.065, height: h), xRadius: s * 0.0325, yRadius: s * 0.0325).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
