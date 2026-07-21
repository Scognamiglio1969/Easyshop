import CoreGraphics
import CoreImage
import Foundation

enum SelectionEngine {
    /// Paints a continuous stroke into a selection mask without mutating the
    /// supplied source data. `points` use Easyshop's canvas coordinate system:
    /// the origin is at the top-left and Y grows downwards.
    ///
    /// This deliberately uses a bitmap `CGContext` rather than Core Image so
    /// brush refinement also works when macOS falls back to software rendering.
    static func paintMask(
        baseData: Data?,
        points: [CanvasPoint],
        radius: Double,
        add: Bool,
        width: Int,
        height: Int
    ) -> Data? {
        guard width > 0,
              height > 0,
              width <= Int.max / height,
              radius.isFinite,
              radius > 0
        else { return nil }

        let validPoints = points.compactMap { point -> CGPoint? in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return CGPoint(
                x: min(Double(width), max(0, point.x)),
                y: Double(height) - min(Double(height), max(0, point.y))
            )
        }
        guard !validPoints.isEmpty else { return baseData }

        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Rasterise the existing mask first. A new buffer is used for every
        // stroke, so `baseData` remains the clean, reversible source mask.
        if let source = ImageData.cgImage(from: baseData) {
            context.interpolationQuality = source.width == width && source.height == height ? .none : .high
            context.setBlendMode(.copy)
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let brushRadius = min(max(0.5, radius), Double(max(width, height)))
        let value: CGFloat = add ? 1 : 0
        context.setBlendMode(.copy)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setStrokeColor(gray: value, alpha: 1)
        context.setFillColor(gray: value, alpha: 1)
        context.setLineWidth(brushRadius * 2)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if validPoints.count == 1, let point = validPoints.first {
            context.fillEllipse(in: CGRect(
                x: point.x - brushRadius,
                y: point.y - brushRadius,
                width: brushRadius * 2,
                height: brushRadius * 2
            ))
        } else {
            context.beginPath()
            context.move(to: validPoints[0])
            for point in validPoints.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }

        guard let result = ImageData.grayscaleImage(bytes: pixels, width: width, height: height) else { return nil }
        return ImageData.pngData(from: result)
    }

    static func maskData(for selection: SelectionState, width: Int, height: Int, feather: Double = 1.5) -> Data? {
        guard width > 0,
              height > 0,
              width <= Int.max / height,
              selection.hasUsableVectorPath
        else { return selection.maskData }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(2)

        func flipped(_ point: CanvasPoint) -> CGPoint {
            CGPoint(x: point.x, y: Double(height) - point.y)
        }

        switch selection.kind {
        case .rectangle, .ellipse:
            let a = flipped(selection.points[0])
            let b = flipped(selection.points[1])
            let rect = CGRect(
                x: min(a.x, b.x),
                y: min(a.y, b.y),
                width: abs(a.x - b.x),
                height: abs(a.y - b.y)
            )
            if selection.kind == .ellipse {
                context.fillEllipse(in: rect)
            } else {
                context.fill(rect)
            }
        case .lasso:
            context.beginPath()
            context.move(to: flipped(selection.points[0]))
            for point in selection.points.dropFirst() {
                context.addLine(to: flipped(point))
            }
            context.closePath()
            context.fillPath()
        case .ai:
            return selection.maskData
        }

        guard let rawMask = ImageData.grayscaleImage(bytes: pixels, width: width, height: height) else { return nil }
        guard feather > 0 else { return ImageData.pngData(from: rawMask) }
        let ci = CIImage(cgImage: rawMask)
        let blurred = ci.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let imageContext = CIContext()
        guard let image = imageContext.createCGImage(blurred, from: blurred.extent) else { return nil }
        return ImageData.pngData(from: image)
    }

    static func refinedMaskData(
        _ data: Data,
        width: Int,
        height: Int,
        feather: Double,
        expansion: Double,
        inverted: Bool
    ) -> Data? {
        guard width > 0,
              height > 0,
              width <= Int.max / height,
              let source = ImageData.cgImage(from: data)
        else { return nil }
        let targetRect = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(cgImage: source)
        if source.width != width || source.height != height {
            image = image.transformed(by: CGAffineTransform(
                scaleX: Double(width) / Double(source.width),
                y: Double(height) / Double(source.height)
            ))
        }
        image = image.cropped(to: targetRect)

        if abs(expansion) > 0.05 {
            let radius = min(36, max(0.1, abs(expansion)))
            let filter = expansion > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
            image = image.clampedToExtent()
                .applyingFilter(filter, parameters: [kCIInputRadiusKey: radius])
                .cropped(to: targetRect)
        }
        if feather > 0.05 {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(40, feather)])
                .cropped(to: targetRect)
        }
        if inverted {
            image = image.applyingFilter("CIColorInvert")
        }

        return grayscalePNG(from: image, rect: targetRect, width: width, height: height)
    }

    static func outlineData(from maskData: Data, width: Int, height: Int) -> Data? {
        guard width > 0,
              height > 0,
              width <= Int.max / height,
              let source = ImageData.cgImage(from: maskData)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        var mask = CIImage(cgImage: source)
        if source.width != width || source.height != height {
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: Double(width) / Double(source.width),
                y: Double(height) / Double(source.height)
            ))
        }
        mask = mask.cropped(to: rect)
        let outside = mask.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 3.0])
            .cropped(to: rect)
        let inside = mask.clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 3.0])
            .cropped(to: rect)
        let edge = outside.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: inside])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 2.2])
            .cropped(to: rect)
        return transparentOutlinePNG(from: edge, rect: rect, width: width, height: height)
    }

    /// Outline assets are presentation-only. Encoding luminance into alpha
    /// gives SwiftUI a genuinely transparent contour instead of an opaque
    /// black rectangle whose thin edge can disappear during downscaling.
    private static func transparentOutlinePNG(
        from image: CIImage,
        rect: CGRect,
        width: Int,
        height: Int
    ) -> Data? {
        var source = [UInt8](repeating: 0, count: width * height * 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            image,
            toBitmap: &source,
            rowBytes: width * 4,
            bounds: rect,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        var contour = [UInt8](repeating: 0, count: source.count)
        for offset in stride(from: 0, to: source.count, by: 4) {
            let alpha = source[offset]
            // Premultiplied white: RGB must not exceed alpha.
            contour[offset] = alpha
            contour[offset + 1] = alpha
            contour[offset + 2] = alpha
            contour[offset + 3] = alpha
        }
        guard let result = ImageData.cgImage(rgba: contour, width: width, height: height) else { return nil }
        return ImageData.pngData(from: result)
    }

    private static func grayscalePNG(from image: CIImage, rect: CGRect, width: Int, height: Int) -> Data? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        context.render(
            image,
            toBitmap: &rgba,
            rowBytes: width * 4,
            bounds: rect,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        var gray = [UInt8](repeating: 0, count: width * height)
        for index in gray.indices { gray[index] = rgba[index * 4] }
        guard let result = ImageData.grayscaleImage(bytes: gray, width: width, height: height) else { return nil }
        return ImageData.pngData(from: result)
    }
}
