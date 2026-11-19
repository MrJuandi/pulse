import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let slate = CGColor(srgbRed: 0.086, green: 0.145, blue: 0.184, alpha: 1)
let ice = CGColor(srgbRed: 0.784, green: 0.867, blue: 0.898, alpha: 1)

func fill(_ rect: CGRect, radius: CGFloat, color: CGColor) {
    context.setFillColor(color)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

fill(CGRect(x: 82, y: 82, width: 860, height: 860), radius: 192, color: slate)

let widths: [CGFloat] = [226, 338, 442]
for (index, width) in widths.enumerated() {
    let track = CGRect(x: 267, y: CGFloat(590 - 112 * index), width: 490, height: 68)
    fill(track, radius: 34, color: ice)
    fill(track.insetBy(dx: 14, dy: 14), radius: 20, color: slate)
    fill(CGRect(x: track.minX, y: track.minY, width: width, height: track.height), radius: 34, color: ice)
}

let file = URL(fileURLWithPath: CommandLine.arguments[1])
let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(output, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(output))
