// 把生成的日月图标（白底木牌）做成 macOS 26 起使用的 Icon Composer 图标（AppIcon.icon）。
// 新格式要求满版的正方形画面，圆角由系统统一裁切；旧式「自带圆角 + 透明边」的图标会被系统缩小并放进灰色底座。
// 用法：swift scripts/make-icon.swift design/sunmoon.png Resources
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("用法：swift scripts/make-icon.swift design/sunmoon.png Resources")
    exit(1)
}
let out = URL(fileURLWithPath: args[2])
let rep = NSBitmapImageRep(cgImage: cg)
let w = rep.pixelsWide, h = rep.pixelsHigh

// 1. 沿中线找出木牌的边界（比白色背景和投影明显更深的像素）
func isContent(_ x: Int, _ y: Int) -> Bool {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
    return min(c.redComponent, c.greenComponent, c.blueComponent) < 0.78
}
let left = (0..<w).first { isContent($0, h / 2) } ?? 0
let right = (0..<w).last { isContent($0, h / 2) } ?? w - 1
let top = (0..<h).first { isContent(w / 2, $0) } ?? 0

// 2. 从木牌正面取一块正方形，四边各往里收一点，避开木牌自己的圆角和侧边
let inset = 34
let side = right - left - inset * 2
let crop = CGRect(x: left + inset, y: top + inset, width: side, height: side)
print("取正方形 \(crop)")

// 3. 画成 1024 × 1024 的满版图
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let ctx = NSGraphicsContext.current!.cgContext
ctx.interpolationQuality = .high
ctx.draw(cg.cropping(to: crop)!, in: CGRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()

// 4. 写出 AppIcon.icon：一个图层，不加玻璃效果，保留木纹原貌
let icon = out.appendingPathComponent("AppIcon.icon")
try? FileManager.default.removeItem(at: icon)
try! FileManager.default.createDirectory(at: icon.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try! bitmap.representation(using: .png, properties: [:])!.write(to: icon.appendingPathComponent("Assets/sunmoon.png"))
let json = """
{
  "fill" : {
    "automatic-gradient" : "extended-srgb:0.95000,0.55000,0.35000,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "sunmoon.png",
          "name" : "sunmoon"
        }
      ],
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}
"""
try! json.write(to: icon.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("✓ \(icon.path)")
