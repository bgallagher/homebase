// usage: swift tools/make-icns.swift <icon-1024.png> <out.iconset>
// Draws the full-bleed artwork inside the macOS rounded-square shape at every iconset size.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icns.swift <icon.png> <out.iconset>\n".utf8)); exit(2)
}
try FileManager.default.createDirectory(atPath: args[2], withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let s = CGFloat(px) / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s).addClip()
    art.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(args[2])/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(args[2])/icon_\(base)x\(base)@2x.png"))
}
