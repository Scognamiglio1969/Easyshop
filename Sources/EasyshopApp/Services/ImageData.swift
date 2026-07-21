import AppKit
import CoreGraphics
import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

enum ImageData {
    static func cgImage(from data: Data?) -> CGImage? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func encode(
        _ image: CGImage,
        type: UTType,
        quality: Double = 0.92,
        properties: [CFString: Any] = [:]
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else { return nil }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func rgbaBytes(from image: CGImage, width: Int? = nil, height: Int? = nil) -> [UInt8]? {
        let w = width ?? image.width
        let h = height ?? image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    static func cgImage(rgba bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard bytes.count == width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func grayscaleImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard bytes.count == width * height,
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func invertedMaskData(_ data: Data?) -> Data? {
        guard let image = cgImage(from: data),
              var rgba = rgbaBytes(from: image) else { return nil }
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let value = UInt8(255 - rgba[offset])
            rgba[offset] = value
            rgba[offset + 1] = value
            rgba[offset + 2] = value
            rgba[offset + 3] = 255
        }
        guard let result = cgImage(rgba: rgba, width: image.width, height: image.height) else { return nil }
        return pngData(from: result)
    }

    static func resizedData(_ data: Data?, width: Int, height: Int, method: ResizeMethod) -> Data? {
        guard width > 0, height > 0, let source = cgImage(from: data) else { return nil }
        if method == .nearest {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .none
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage().flatMap(pngData(from:))
        }

        let input = CIImage(cgImage: source)
        let xScale = Double(width) / Double(source.width)
        let yScale = Double(height) / Double(source.height)
        let output: CIImage
        if method == .lanczos {
            output = input.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: yScale,
                kCIInputAspectRatioKey: xScale / yScale
            ])
        } else if method == .bicubic {
            output = input.applyingFilter("CIBicubicScaleTransform", parameters: [
                kCIInputScaleKey: yScale,
                kCIInputAspectRatioKey: xScale / yScale,
                "inputB": 0,
                "inputC": 0.75
            ])
        } else {
            output = input.transformed(by: CGAffineTransform(scaleX: xScale, y: yScale))
        }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        guard let image = CIContext().createCGImage(output, from: extent) else { return nil }
        return pngData(from: image)
    }

    static func canvasData(_ data: Data?, width: Int, height: Int, offsetX: Int, offsetY: Int) -> Data? {
        guard width > 0, height > 0, let source = cgImage(from: data) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(source, in: CGRect(x: offsetX, y: offsetY, width: source.width, height: source.height))
        return context.makeImage().flatMap(pngData(from:))
    }
}
