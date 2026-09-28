import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let canvas = NSRect(origin: .zero, size: size)
NSColor.clear.setFill()
canvas.fill()

let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 210, yRadius: 210)
NSGradient(colors: [NSColor(calibratedRed: 1.0, green: 0.973, blue: 0.929, alpha: 1), NSColor(calibratedRed: 0.906, green: 0.941, blue: 0.922, alpha: 1)])!.draw(in: tile, angle: -35)

let ink = NSColor(calibratedRed: 0.188, green: 0.176, blue: 0.165, alpha: 1)
let mint = NSColor(calibratedRed: 0.373, green: 0.584, blue: 0.541, alpha: 1)
let skin = NSColor(calibratedRed: 0.969, green: 0.835, blue: 0.733, alpha: 1)
let coral = NSColor(calibratedRed: 0.945, green: 0.455, blue: 0.475, alpha: 1)

func oval(_ rect: NSRect, color: NSColor, stroke: NSColor? = nil, width: CGFloat = 0) {
    let path = NSBezierPath(ovalIn: rect)
    color.setFill(); path.fill()
    if let stroke { stroke.setStroke(); path.lineWidth = width; path.stroke() }
}

// Ears and head: deliberately simple, hand-drawn and readable at small size.
let leftEar = NSBezierPath(roundedRect: NSRect(x: 278, y: 586, width: 178, height: 206), xRadius: 80, yRadius: 80)
let rightEar = NSBezierPath(roundedRect: NSRect(x: 568, y: 586, width: 178, height: 206), xRadius: 80, yRadius: 80)
for ear in [leftEar, rightEar] { mint.setFill(); ear.fill(); ink.setStroke(); ear.lineWidth = 30; ear.stroke() }

oval(NSRect(x: 279, y: 205, width: 466, height: 542), color: skin, stroke: ink, width: 34)
let fringe = NSBezierPath()
fringe.move(to: NSPoint(x: 316, y: 584))
fringe.curve(to: NSPoint(x: 708, y: 584), controlPoint1: NSPoint(x: 374, y: 746), controlPoint2: NSPoint(x: 650, y: 746))
fringe.curve(to: NSPoint(x: 316, y: 584), controlPoint1: NSPoint(x: 615, y: 618), controlPoint2: NSPoint(x: 409, y: 618))
mint.setFill(); fringe.fill()

oval(NSRect(x: 356, y: 445, width: 74, height: 74), color: ink)
oval(NSRect(x: 594, y: 445, width: 74, height: 74), color: ink)
let smile = NSBezierPath()
smile.move(to: NSPoint(x: 462, y: 350)); smile.curve(to: NSPoint(x: 562, y: 350), controlPoint1: NSPoint(x: 490, y: 318), controlPoint2: NSPoint(x: 534, y: 318))
ink.setStroke(); smile.lineWidth = 27; smile.lineCapStyle = .round; smile.stroke()
oval(NSRect(x: 487, y: 385, width: 50, height: 35), color: ink)
oval(NSRect(x: 327, y: 375, width: 92, height: 38), color: coral.withAlphaComponent(0.55))
oval(NSRect(x: 605, y: 375, width: 92, height: 38), color: coral.withAlphaComponent(0.55))

let heart = NSBezierPath()
heart.move(to: NSPoint(x: 718, y: 210))
heart.curve(to: NSPoint(x: 624, y: 292), controlPoint1: NSPoint(x: 672, y: 244), controlPoint2: NSPoint(x: 622, y: 251))
heart.curve(to: NSPoint(x: 718, y: 369), controlPoint1: NSPoint(x: 625, y: 346), controlPoint2: NSPoint(x: 676, y: 378))
heart.curve(to: NSPoint(x: 812, y: 292), controlPoint1: NSPoint(x: 760, y: 378), controlPoint2: NSPoint(x: 811, y: 346))
heart.curve(to: NSPoint(x: 718, y: 210), controlPoint1: NSPoint(x: 814, y: 251), controlPoint2: NSPoint(x: 764, y: 244))
coral.setFill(); heart.fill(); ink.setStroke(); heart.lineWidth = 22; heart.stroke()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
