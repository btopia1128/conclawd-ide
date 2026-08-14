// Generates AppIconDev.appiconset by stamping a "DEV" banner onto each
// AppIcon PNG. Re-run after updating the base icon:
//   swift Scripts/generate-dev-icon.swift
import AppKit
import Foundation

let srcDir = "Conclawd/Resources/Assets.xcassets/AppIcon.appiconset"
let dstDir = "Conclawd/Resources/Assets.xcassets/AppIconDev.appiconset"

let fm = FileManager.default
try? fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
try? fm.removeItem(atPath: dstDir + "/Contents.json")
try fm.copyItem(atPath: srcDir + "/Contents.json", toPath: dstDir + "/Contents.json")

for file in try fm.contentsOfDirectory(atPath: srcDir).sorted() where file.hasSuffix(".png") {
    guard let img = NSImage(contentsOfFile: srcDir + "/" + file),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        FileHandle.standardError.write(Data("skip: \(file)\n".utf8))
        continue
    }
    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    guard let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))

    // macOS icons have ~10% transparent margin; keep the banner inside it.
    let W = CGFloat(w)
    let H = CGFloat(h)
    let bannerH = H * 0.26
    let inset = W * 0.10
    let bannerRect = NSRect(x: inset, y: H * 0.10, width: W - inset * 2, height: bannerH)
    let banner = NSBezierPath(roundedRect: bannerRect, xRadius: bannerH * 0.3, yRadius: bannerH * 0.3)
    NSColor(calibratedRed: 0.93, green: 0.45, blue: 0.09, alpha: 0.95).setFill()
    banner.fill()

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: bannerH * 0.62),
        .foregroundColor: NSColor.white,
    ]
    let text = NSAttributedString(string: "DEV", attributes: attrs)
    let size = text.size()
    text.draw(at: NSPoint(x: bannerRect.midX - size.width / 2, y: bannerRect.midY - size.height / 2))

    NSGraphicsContext.restoreGraphicsState()

    guard let png = out.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: dstDir + "/" + file))
    print("stamped: \(file)")
}
