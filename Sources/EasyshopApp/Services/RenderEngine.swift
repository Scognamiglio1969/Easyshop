import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum RenderEngine {
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)
        ?? CGColorSpaceCreateDeviceRGB()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    @MainActor
    static let context = CIContext(options: [
        .cacheIntermediates: true,
        .workingColorSpace: displayP3,
        .outputColorSpace: sRGB
    ])
    @MainActor
    private static let softwareContext = CIContext(options: [
        .useSoftwareRenderer: true,
        .cacheIntermediates: true,
        .workingColorSpace: sRGB,
        .outputColorSpace: sRGB
    ])

    @MainActor
    static func makeCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        context.createCGImage(image, from: rect)
            ?? softwareContext.createCGImage(image, from: rect)
    }

    @MainActor
    static func composite(document: EditorDocument, through upperBound: Int? = nil) -> CGImage? {
        composite(width: document.width, height: document.height, layers: document.layers, through: upperBound)
    }

    @MainActor
    static func composite(width: Int, height: Int, layers: [EditorLayer], through upperBound: Int? = nil) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        var output = CIImage(color: .clear).cropped(to: extent)
        let lastIndex = min(upperBound ?? (layers.count - 1), layers.count - 1)
        guard lastIndex >= 0 else {
            return makeCGImage(output, from: extent)
        }

        for index in 0...lastIndex {
            let layer = layers[index]
            guard layer.isVisible else { continue }

            if layer.kind == .adjustment {
                let adjusted = apply(layer.adjustment, to: output).cropped(to: extent)
                let mixMask = layer.maskData.flatMap(ImageData.cgImage(from:)).map(CIImage.init(cgImage:))
                if let mixMask {
                    let mask = opacityAdjustedMask(mixMask.cropped(to: extent), opacity: layer.opacity)
                    output = blendWithMask(foreground: adjusted, background: output, mask: mask)
                } else if layer.opacity < 0.999 {
                    let mask = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: layer.opacity)).cropped(to: extent)
                    output = blendWithMask(foreground: adjusted, background: output, mask: mask)
                } else {
                    output = adjusted
                }
                continue
            }

            guard var image = renderedLayer(layer, canvasSize: CGSize(width: width, height: height)) else { continue }
            image = image.cropped(to: extent)
            output = composite(image, over: output, mode: layer.blendMode).cropped(to: extent)
        }
        return makeCGImage(output, from: extent)
    }

    @MainActor
    static func renderedLayer(_ layer: EditorLayer, canvasSize: CGSize) -> CIImage? {
        let canvasExtent = CGRect(origin: .zero, size: canvasSize)
        var image: CIImage?
        switch layer.kind {
        case .raster:
            image = layer.rasterData.flatMap(ImageData.cgImage(from:)).map(CIImage.init(cgImage:))
        case .text:
            image = renderText(layer.text, transform: layer.transform, canvasSize: canvasSize).map(CIImage.init(cgImage:))
        case .adjustment:
            return nil
        }
        guard var image else { return nil }

        if layer.kind == .raster {
            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: layer.transform.x, y: layer.transform.y)
            transform = transform.rotated(by: layer.transform.rotationDegrees * .pi / 180)
            transform = transform.scaledBy(x: layer.transform.scaleX, y: layer.transform.scaleY)
            image = image.transformed(by: transform)
        }

        image = opacityAdjustedImage(image, opacity: layer.opacity)
        if let maskImage = layer.maskData.flatMap(ImageData.cgImage(from:)).map(CIImage.init(cgImage:)) {
            image = blendWithMask(
                foreground: image,
                background: CIImage(color: .clear).cropped(to: canvasExtent),
                mask: maskImage.cropped(to: canvasExtent)
            )
        }
        return image.cropped(to: canvasExtent)
    }

    static func apply(_ settings: AdjustmentSettings, to source: CIImage) -> CIImage {
        var image = source
        if abs(settings.exposure) > 0.0001 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(settings.exposure)
            image = filter.outputImage ?? image
        }
        if abs(settings.brightness) > 0.0001 || abs(settings.contrast - 1) > 0.0001 || abs(settings.saturation - 1) > 0.0001 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.brightness = Float(settings.brightness)
            filter.contrast = Float(settings.contrast)
            filter.saturation = Float(settings.saturation)
            image = filter.outputImage ?? image
        }
        if abs(settings.highlights - 1) > 0.0001 || abs(settings.shadows) > 0.0001 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(settings.highlights)
            filter.shadowAmount = Float(settings.shadows)
            image = filter.outputImage ?? image
        }
        if abs(settings.vibrance) > 0.0001 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(settings.vibrance)
            image = filter.outputImage ?? image
        }
        if abs(settings.hue) > 0.0001 {
            let filter = CIFilter.hueAdjust()
            filter.inputImage = image
            filter.angle = Float(settings.hue * .pi / 180)
            image = filter.outputImage ?? image
        }
        if abs(settings.temperature) > 0.5 || abs(settings.tint) > 0.5 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 + settings.temperature, y: settings.tint)
            image = filter.outputImage ?? image
        }
        if abs(settings.gamma - 1) > 0.0001 {
            let filter = CIFilter.gammaAdjust()
            filter.inputImage = image
            filter.power = Float(settings.gamma)
            image = filter.outputImage ?? image
        }
        if abs(settings.blackPoint) > 0.0001 || abs(settings.whitePoint - 1) > 0.0001 ||
            abs(settings.curveShadows) > 0.0001 || abs(settings.curveMidtones) > 0.0001 || abs(settings.curveHighlights) > 0.0001 {
            let filter = CIFilter.toneCurve()
            filter.inputImage = image
            filter.point0 = CGPoint(x: 0, y: settings.blackPoint)
            filter.point1 = CGPoint(x: 0.25, y: min(1, max(0, 0.25 + settings.curveShadows)))
            filter.point2 = CGPoint(x: 0.5, y: min(1, max(0, 0.5 + settings.curveMidtones)))
            filter.point3 = CGPoint(x: 0.75, y: min(1, max(0, 0.75 + settings.curveHighlights)))
            filter.point4 = CGPoint(x: 1, y: settings.whitePoint)
            image = filter.outputImage ?? image
        }
        if abs(settings.redBalance - 1) > 0.0001 || abs(settings.greenBalance - 1) > 0.0001 || abs(settings.blueBalance - 1) > 0.0001 {
            let filter = CIFilter.colorMatrix()
            filter.inputImage = image
            filter.rVector = CIVector(x: settings.redBalance, y: 0, z: 0, w: 0)
            filter.gVector = CIVector(x: 0, y: settings.greenBalance, z: 0, w: 0)
            filter.bVector = CIVector(x: 0, y: 0, z: settings.blueBalance, w: 0)
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            image = filter.outputImage ?? image
        }
        if settings.clarity > 0.0001 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = 2.2
            filter.intensity = Float(settings.clarity)
            image = filter.outputImage ?? image
        }
        if settings.noiseReduction > 0.0001 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(settings.noiseReduction)
            filter.sharpness = 0.4
            image = filter.outputImage ?? image
        }
        if settings.sharpness > 0.0001 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(settings.sharpness)
            image = filter.outputImage ?? image
        }
        return image
    }

    static func renderText(_ settings: TextSettings, transform: LayerTransform, canvasSize: CGSize) -> CGImage? {
        let width = max(1, Int(canvasSize.width.rounded()))
        let height = max(1, Int(canvasSize.height.rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = graphics
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = NSTextAlignment(rawValue: settings.alignment) ?? .left
        let font = NSFont(name: settings.fontName, size: settings.fontSize) ?? .systemFont(ofSize: settings.fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: settings.color.nsColor,
            .kern: settings.tracking,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: settings.content, attributes: attributes)
        let proposedHeight = max(settings.fontSize * 3, Double(height))
        let rect = NSRect(
            x: transform.x,
            y: Double(height) - transform.y - proposedHeight,
            width: max(40, settings.width),
            height: proposedHeight
        )
        let affine = NSAffineTransform()
        affine.translateX(by: transform.x, yBy: Double(height) - transform.y)
        affine.rotate(byDegrees: transform.rotationDegrees)
        affine.scaleX(by: transform.scaleX, yBy: transform.scaleY)
        affine.translateX(by: -transform.x, yBy: -(Double(height) - transform.y))
        affine.concat()
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }

    private static func opacityAdjustedImage(_ image: CIImage, opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
        return filter.outputImage ?? image
    }

    private static func opacityAdjustedMask(_ image: CIImage, opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: opacity, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: opacity, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: opacity, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage ?? image
    }

    private static func blendWithMask(foreground: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = foreground
        filter.backgroundImage = background
        filter.maskImage = mask
        return filter.outputImage ?? foreground
    }

    private static func composite(_ foreground: CIImage, over background: CIImage, mode: BlendMode) -> CIImage {
        let filterName: String
        switch mode {
        case .normal: filterName = "CISourceOverCompositing"
        case .multiply: filterName = "CIMultiplyBlendMode"
        case .screen: filterName = "CIScreenBlendMode"
        case .overlay: filterName = "CIOverlayBlendMode"
        case .softLight: filterName = "CISoftLightBlendMode"
        case .darken: filterName = "CIDarkenBlendMode"
        case .lighten: filterName = "CILightenBlendMode"
        }
        guard let filter = CIFilter(name: filterName) else { return foreground.composited(over: background) }
        filter.setValue(foreground, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        return filter.outputImage ?? foreground.composited(over: background)
    }
}
