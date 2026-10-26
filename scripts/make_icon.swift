// 產生 assets/ShoWork42.icns：深色圓角方塊上兩張疊著的視窗，後面綠光（完成）、前面紫光（工作中）
// ＝ShoWork42 在畫面上做的事。不用 SF Symbols（授權不准放進 app icon）。
//   swift scripts/make_icon.swift   （輸出到 assets/）
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024, ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)
    // macOS 圖示格線：824×824 內容、圓角約 185
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.15, blue: 0.24, alpha: 1), NSColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1)])!
        .draw(in: body, angle: -90)
    func card(_ r: NSRect, glow: NSColor) {
        let path = NSBezierPath(roundedRect: r, xRadius: 44, yRadius: 44)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = glow; sh.shadowBlurRadius = 70; sh.shadowOffset = .zero; sh.set()
        glow.setStroke(); path.lineWidth = 22; path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(red: 0.11, green: 0.11, blue: 0.16, alpha: 1).setFill(); path.fill()
        glow.setStroke(); path.lineWidth = 14; path.stroke()
        // 標題列的三顆燈
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 46 + CGFloat(i) * 52, y: r.maxY - 82, width: 34, height: 34)).fill()
        }
        // 幾行字
        NSColor(white: 1, alpha: 0.28).setFill()
        for (i, w) in [0.62, 0.48, 0.55].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: r.minX + 50, y: r.maxY - 160 - CGFloat(i) * 58, width: r.width * w, height: 26), xRadius: 13, yRadius: 13).fill()
        }
    }
    card(NSRect(x: 190, y: 330, width: 470, height: 420), glow: NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1))   // 後：綠
    card(NSRect(x: 360, y: 210, width: 470, height: 420), glow: NSColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1))   // 前：紫
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("assets/ShoWork42.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("assets/ShoWork42.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
try! draw(1024).write(to: root.appendingPathComponent("assets/ShoWork42-1024.png"))
print("assets/ShoWork42.icns")
