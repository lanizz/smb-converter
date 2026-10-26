//
//  makeicon.swift — 生成「共享转换器」1024x1024 图标 PNG（简洁 + 立体质感）
//  运行：swift makeicon.swift <输出 png 路径>
//

import AppKit
import Foundation

let S = 1024
let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "icon-1024.png"

let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

// MARK: 工具
func rrect(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func verticalGradient(_ top: NSColor, _ bottom: NSColor, _ rect: NSRect, angle: CGFloat = -90) {
    NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: angle)
}

// MARK: 1) 圆角底板 + 蓝色渐变
let bg = NSRect(x: 64, y: 64, width: 896, height: 896)
let bgPath = rrect(bg, 200)
ctx.saveGState()
bgPath.addClip()
verticalGradient(
    NSColor(srgbRed: 0.34, green: 0.68, blue: 1.00, alpha: 1),   // 顶：亮蓝
    NSColor(srgbRed: 0.04, green: 0.34, blue: 0.86, alpha: 1),   // 底：深蓝
    bg
)

// 顶部光泽（玻璃高光）
let gloss = NSBezierPath(roundedRect: NSRect(x: 64, y: 640, width: 896, height: 320),
                         xRadius: 200, yRadius: 200)
let glossGrad = NSGradient(colors: [
    NSColor(white: 1, alpha: 0.20),
    NSColor(white: 1, alpha: 0.0),
])!
glossGrad.draw(in: NSRect(x: 64, y: 640, width: 896, height: 320), angle: -90)
ctx.restoreGState()

// 底板内缘高光线（上边一道细白边，增强立体边缘）
ctx.saveGState()
bgPath.addClip()
let inner = rrect(NSRect(x: 78, y: 78, width: 868, height: 868), 188)
inner.lineWidth = 4
NSColor(white: 1, alpha: 0.28).setStroke()
inner.stroke()
ctx.restoreGState()

// MARK: 2) 文件夹（带柔和投影 + 微渐变）
// 文件夹几何
let tabRect = NSRect(x: 252, y: 588, width: 250, height: 92)
let frontRect = NSRect(x: 208, y: 300, width: 608, height: 320)

// 接触投影
let folderShadow = NSShadow()
folderShadow.shadowColor = NSColor(white: 0, alpha: 0.28)
folderShadow.shadowBlurRadius = 40
folderShadow.shadowOffset = NSSize(width: 0, height: -20)
NSGraphicsContext.saveGraphicsState()
folderShadow.set()

// 舌片 + 主体先填一层底色（让投影整体成型）
NSColor(white: 0.9, alpha: 1).setFill()
rrect(tabRect, 26).fill()
rrect(frontRect, 46).fill()
NSGraphicsContext.restoreGraphicsState()

// 用渐变重新填充文件夹（白 → 淡蓝，立体）
let folderTop = NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
let folderBottom = NSColor(srgbRed: 0.83, green: 0.90, blue: 1.00, alpha: 1)
func fillFolder(_ r: NSRect, radius: CGFloat) {
    ctx.saveGState()
    rrect(r, radius).addClip()
    verticalGradient(folderTop, folderBottom, r)
    ctx.restoreGState()
}
fillFolder(tabRect, radius: 26)
fillFolder(frontRect, radius: 46)

// 文件夹正面的顶部内高光（一道很淡的白→透明，增加层次）
ctx.saveGState()
rrect(frontRect, 46).addClip()
NSGradient(colors: [NSColor(white: 1, alpha: 0.9), NSColor(white: 1, alpha: 0)])!
    .draw(in: NSRect(x: frontRect.minX, y: frontRect.maxY - 90,
                     width: frontRect.width, height: 90), angle: -90)
ctx.restoreGState()

// MARK: 3) 双向转换箭头
let arrowColor = NSColor(srgbRed: 0.03, green: 0.30, blue: 0.78, alpha: 1)
let lineY: CGFloat = 462
let lx: CGFloat = 360, rx: CGFloat = 668
let w: CGFloat = 46

func arrowStroke() {
    arrowColor.setStroke()
}

// 箭头轻微投影，浮在文件夹上
let aShadow = NSShadow()
aShadow.shadowColor = NSColor(white: 0, alpha: 0.18)
aShadow.shadowBlurRadius = 8
aShadow.shadowOffset = NSSize(width: 0, height: -4)
NSGraphicsContext.saveGraphicsState()
aShadow.set()

arrowStroke()
let line = NSBezierPath()
line.lineWidth = w
line.lineCapStyle = .round
line.move(to: NSPoint(x: lx + 24, y: lineY))
line.line(to: NSPoint(x: rx - 24, y: lineY))
line.stroke()

let h: CGFloat = 66
let head = NSBezierPath()
head.lineWidth = w
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: NSPoint(x: rx, y: lineY))
head.line(to: NSPoint(x: rx - h, y: lineY + h))
head.move(to: NSPoint(x: rx, y: lineY))
head.line(to: NSPoint(x: rx - h, y: lineY - h))
head.move(to: NSPoint(x: lx, y: lineY))
head.line(to: NSPoint(x: lx + h, y: lineY + h))
head.move(to: NSPoint(x: lx, y: lineY))
head.line(to: NSPoint(x: lx + h, y: lineY - h))
head.stroke()
NSGraphicsContext.restoreGraphicsState()

image.unlockFocus()

// MARK: 输出
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
