#!/usr/bin/env swift
import AppKit

// Generate a WindowPin app icon: a pushpin on a rounded-rect background

func createIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded rect background with gradient
    let bgRect = CGRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let cornerRadius = s * 0.2
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Gradient: deep blue to teal
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.15, green: 0.30, blue: 0.65, alpha: 1.0),
        CGColor(red: 0.20, green: 0.55, blue: 0.75, alpha: 1.0),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0])!

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: s/2, y: s * 0.95), end: CGPoint(x: s/2, y: s * 0.05), options: [])
    ctx.restoreGState()

    // Subtle inner shadow / border
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.15))
    ctx.setLineWidth(s * 0.01)
    ctx.strokePath()
    ctx.restoreGState()

    // Draw pushpin using SF Symbol
    if let pinImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: s * 0.45, weight: .medium)
        let configured = pinImage.withSymbolConfiguration(config) ?? pinImage

        // Tint white
        let tinted = NSImage(size: configured.size)
        tinted.lockFocus()
        NSColor.white.set()
        let tintRect = NSRect(origin: .zero, size: configured.size)
        configured.draw(in: tintRect)
        tintRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        // Center the pin in the background
        let pinW = tinted.size.width
        let pinH = tinted.size.height
        let pinX = (s - pinW) / 2
        let pinY = (s - pinH) / 2
        tinted.draw(in: NSRect(x: pinX, y: pinY, width: pinW, height: pinH))
    }

    image.unlockFocus()
    return image
}

// Generate iconset
let iconsetPath = "/tmp/WindowPin.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512]
for size in sizes {
    let img1x = createIcon(size: size)
    let img2x = createIcon(size: size * 2)

    if let tiff1x = img1x.tiffRepresentation,
       let rep1x = NSBitmapImageRep(data: tiff1x),
       let png1x = rep1x.representation(using: .png, properties: [:]) {
        let name = "icon_\(size)x\(size).png"
        try! png1x.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    }

    if let tiff2x = img2x.tiffRepresentation,
       let rep2x = NSBitmapImageRep(data: tiff2x),
       let png2x = rep2x.representation(using: .png, properties: [:]) {
        let name = "icon_\(size)x\(size)@2x.png"
        try! png2x.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
    }
}

print("Iconset generated at \(iconsetPath)")
print("Converting to .icns...")
