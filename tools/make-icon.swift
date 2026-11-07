// Erzeugt das App-Symbol von HomeFind (eigenes Motiv: Haus mit Ortungsringen, kein Apple-Symbol):
//   swift tools/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    // iOS maskiert selbst → volle, deckende Fläche
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x4CD964), rgb(0x16A34A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    // Ortungsringe um die Hausmitte
    let c = CGPoint(x: 512, y: 470)
    for (r, a) in [(390.0, 0.16), (290.0, 0.26), (190.0, 0.38)] {
        ctx.setStrokeColor(rgb(0xFFFFFF, a)); ctx.setLineWidth(26)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
    // Stecknadel: Kopf + Spitze
    let pin = CGMutablePath()
    pin.move(to: CGPoint(x: 512, y: 230))
    pin.addArc(center: CGPoint(x: 512, y: 560), radius: 210, startAngle: -.pi * 0.2, endAngle: .pi * 1.2, clockwise: false)
    pin.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.25))
    ctx.addPath(pin); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    // Haus im Kopf der Nadel
    let house = CGMutablePath()
    house.move(to: CGPoint(x: 512, y: 690))
    house.addLine(to: CGPoint(x: 640, y: 580)); house.addLine(to: CGPoint(x: 608, y: 580))
    house.addLine(to: CGPoint(x: 608, y: 470)); house.addLine(to: CGPoint(x: 545, y: 470))
    house.addLine(to: CGPoint(x: 545, y: 535)); house.addLine(to: CGPoint(x: 479, y: 535))
    house.addLine(to: CGPoint(x: 479, y: 470)); house.addLine(to: CGPoint(x: 416, y: 470))
    house.addLine(to: CGPoint(x: 416, y: 580)); house.addLine(to: CGPoint(x: 384, y: 580))
    house.closeSubpath()
    ctx.addPath(house); ctx.setFillColor(rgb(0x16A34A)); ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let rep = render(1024)
// Ohne Alphakanal speichern (App Store/Sideload verlangen deckende Symbole)
let flat = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
flat.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let opaque = NSBitmapImageRep(cgImage: flat.makeImage()!)
try! opaque.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon-1024.png"))
let json = """
{ "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
"""
try! json.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Symbol geschrieben nach \(out.path)")
