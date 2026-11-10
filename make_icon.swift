import Cocoa

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// 背景：圆角矩形 + 深色渐变
let bgRect = NSRect(x: 52, y: 52, width: S - 104, height: S - 104)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 224, yRadius: 224)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
])
grad?.draw(in: bgPath, angle: -90)

// 电池主体
let bw: CGFloat = 598
let bh: CGFloat = 312
let bx = (S - bw) / 2 - 28
let by = (S - bh) / 2
let strokeW: CGFloat = 24

let bodyRect = NSRect(x: bx, y: by, width: bw, height: bh)
let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 42, yRadius: 42)
bodyPath.lineWidth = strokeW
NSColor.white.setStroke()
bodyPath.stroke()

// 正极凸点
let nubRect = NSRect(x: bx + bw + 6, y: by + bh / 2 - 46, width: 46, height: 92)
NSColor.white.setFill()
NSBezierPath(roundedRect: nubRect, xRadius: 20, yRadius: 20).fill()

// 电量填充（85%）
let inset = strokeW / 2 + 14
let innerW = bw - inset * 2
let innerH = bh - inset * 2
let fillW = innerW * 0.85
let fillRect = NSRect(x: bx + inset, y: by + inset, width: fillW, height: innerH)
NSColor.white.setFill()
NSBezierPath(roundedRect: fillRect, xRadius: 26, yRadius: 26).fill()

// 数字：用背景深色直接绘制（不能挖空，会透穿背景）
let dark = NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.17, alpha: 1)
let font = NSFont.monospacedDigitSystemFont(ofSize: 158, weight: .bold)
let str = NSAttributedString(string: "85", attributes: [
    .font: font,
    .foregroundColor: dark
])
let ts = str.size()
let origin = NSPoint(x: bx + (bw - ts.width) / 2, y: by + (bh - ts.height) / 2 + 6)
str.draw(at: origin)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("失败"); exit(1)
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.png"
try! png.write(to: URL(fileURLWithPath: out))
print("已输出 \(out)")
