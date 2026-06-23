import AppKit

// Render the logo onto Apple's macOS icon grid: a 1024 canvas with an 824 rounded-square
// "body" (corner radius 185.4), the source filling the body. White body + blue glyph.
let args = CommandLine.arguments
let srcPath = args.count > 1 ? args[1] : "logo_src.png"
let outPath = args.count > 2 ? args[2] : "icon_master.png"

guard let src = NSImage(contentsOfFile: srcPath) else {
    FileHandle.standardError.write(Data("cannot load \(srcPath)\n".utf8)); exit(1)
}

let canvas: CGFloat = 1024
let body: CGFloat = 824
let margin = (canvas - body) / 2
let radius: CGFloat = 185.4

let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
let rect = CGRect(x: margin, y: margin, width: body, height: body)
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(path)
ctx.clip()
// fill white first so any non-opaque source still reads as a white body
ctx.setFillColor(NSColor.white.cgColor)
ctx.fill(rect)
src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
out.unlockFocus()

guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("encode failed\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
