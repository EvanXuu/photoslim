import AppKit
import Foundation

private let canvas = NSColor(calibratedRed: 0.953, green: 0.941, blue: 0.914, alpha: 1)
private let surface = NSColor(calibratedRed: 0.986, green: 0.980, blue: 0.961, alpha: 1)
private let raised = NSColor.white
private let ink = NSColor(calibratedRed: 0.105, green: 0.102, blue: 0.094, alpha: 1)
private let signal = NSColor(calibratedRed: 0.725, green: 0.341, blue: 0.059, alpha: 1)

private func roundedRect(
  _ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, width: CGFloat = 0
) {
  let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
  fill.setFill()
  path.fill()
  if let stroke, width > 0 {
    stroke.setStroke()
    path.lineWidth = width
    path.stroke()
  }
}

private func drawIcon(pixelSize: Int) -> Data? {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelSize,
      pixelsHigh: pixelSize,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else { return nil }

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  NSColor.clear.setFill()
  NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()

  let scale = CGFloat(pixelSize) / 1024
  let transform = NSAffineTransform()
  transform.scale(by: scale)
  transform.concat()

  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
  shadow.shadowBlurRadius = 32
  shadow.shadowOffset = NSSize(width: 0, height: -14)
  shadow.set()
  roundedRect(NSRect(x: 68, y: 68, width: 888, height: 888), radius: 208, fill: canvas)
  NSGraphicsContext.current?.saveGraphicsState()
  NSShadow().set()

  roundedRect(
    NSRect(x: 208, y: 312, width: 530, height: 414),
    radius: 74,
    fill: surface,
    stroke: ink.withAlphaComponent(0.12),
    width: 8
  )
  roundedRect(
    NSRect(x: 250, y: 264, width: 530, height: 414),
    radius: 74,
    fill: raised,
    stroke: ink.withAlphaComponent(0.16),
    width: 8
  )
  roundedRect(
    NSRect(x: 290, y: 214, width: 530, height: 414),
    radius: 74,
    fill: raised,
    stroke: ink.withAlphaComponent(0.90),
    width: 18
  )

  let imageWindow = NSRect(x: 328, y: 328, width: 454, height: 258)
  roundedRect(imageWindow, radius: 42, fill: ink)

  signal.setFill()
  NSBezierPath(ovalIn: NSRect(x: 654, y: 474, width: 72, height: 72)).fill()

  let landscape = NSBezierPath()
  landscape.move(to: NSPoint(x: 350, y: 350))
  landscape.line(to: NSPoint(x: 474, y: 490))
  landscape.line(to: NSPoint(x: 556, y: 414))
  landscape.line(to: NSPoint(x: 630, y: 486))
  landscape.line(to: NSPoint(x: 760, y: 350))
  landscape.close()
  canvas.setFill()
  landscape.fill()

  roundedRect(NSRect(x: 444, y: 248, width: 222, height: 42), radius: 21, fill: signal)

  signal.setStroke()
  let leftMark = NSBezierPath()
  leftMark.lineWidth = 26
  leftMark.lineCapStyle = .round
  leftMark.lineJoinStyle = .round
  leftMark.move(to: NSPoint(x: 172, y: 568))
  leftMark.line(to: NSPoint(x: 224, y: 518))
  leftMark.line(to: NSPoint(x: 172, y: 468))
  leftMark.stroke()

  let rightMark = NSBezierPath()
  rightMark.lineWidth = 26
  rightMark.lineCapStyle = .round
  rightMark.lineJoinStyle = .round
  rightMark.move(to: NSPoint(x: 852, y: 568))
  rightMark.line(to: NSPoint(x: 800, y: 518))
  rightMark.line(to: NSPoint(x: 852, y: 468))
  rightMark.stroke()

  NSGraphicsContext.current?.restoreGraphicsState()
  NSGraphicsContext.restoreGraphicsState()
  return bitmap.representation(using: .png, properties: [:])
}

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: generate-app-icon.swift OUTPUT_ICONSET\n".utf8))
  exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let variants: [(name: String, pixels: Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for variant in variants {
  guard let data = drawIcon(pixelSize: variant.pixels) else {
    throw CocoaError(.fileWriteUnknown)
  }
  try data.write(to: output.appendingPathComponent(variant.name), options: .atomic)
}
