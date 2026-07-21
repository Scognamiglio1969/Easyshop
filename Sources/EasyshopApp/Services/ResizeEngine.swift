import CoreGraphics
import Foundation

enum ResizeEngineError: LocalizedError {
    case lockedLayer(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .lockedLayer(let name):
            "Il livello “\(name)” è protetto. Sbloccalo prima di ridimensionare o ritagliare."
        case .processingFailed(let name):
            "Easyshop non è riuscito a trasformare “\(name)” senza perdita di dati. Il documento non è stato modificato."
        }
    }
}

@MainActor
enum ResizeEngine {
    static func resizeImage(
        document: EditorDocument,
        width newWidth: Int,
        height newHeight: Int,
        dpi: Double,
        method: ResizeMethod
    ) throws {
        try validateTarget(width: newWidth, height: newHeight)
        try requireEditableLayers(document.layers)
        let oldWidth = max(1, document.width)
        let oldHeight = max(1, document.height)
        let scaleX = Double(newWidth) / Double(oldWidth)
        let scaleY = Double(newHeight) / Double(oldHeight)
        let textScale = (scaleX + scaleY) / 2

        var plans: [LayerPlan] = []
        plans.reserveCapacity(document.layers.count)
        for layer in document.layers {
            var rasterData = layer.rasterData
            var maskData = layer.maskData
            var transform = layer.transform
            var text = layer.text
            if layer.kind == .raster {
                if let source = ImageData.cgImage(from: layer.rasterData) {
                    let layerWidth = max(1, Int((Double(source.width) * scaleX).rounded()))
                    let layerHeight = max(1, Int((Double(source.height) * scaleY).rounded()))
                    try validateTarget(width: layerWidth, height: layerHeight)
                    guard let resized = resizedData(
                        layer.rasterData,
                        width: layerWidth,
                        height: layerHeight,
                        method: method
                    ) else { throw ResizeEngineError.processingFailed(layer.name) }
                    rasterData = resized
                } else if layer.rasterData != nil {
                    throw ResizeEngineError.processingFailed(layer.name)
                }
                transform.x *= scaleX
                transform.y *= scaleY
            } else if layer.kind == .text {
                transform.x *= scaleX
                transform.y *= scaleY
                text.fontSize *= textScale
                text.width *= scaleX
            }
            if layer.maskData != nil {
                guard let resizedMask = resizedData(
                    layer.maskData,
                    width: newWidth,
                    height: newHeight,
                    method: method
                ) else { throw ResizeEngineError.processingFailed(layer.name) }
                maskData = resizedMask
            }
            plans.append(LayerPlan(
                layer: layer,
                rasterData: rasterData,
                maskData: maskData,
                transform: transform,
                text: text
            ))
        }

        // Commit only after every layer has been prepared successfully.
        for plan in plans {
            plan.layer.rasterData = plan.rasterData
            plan.layer.maskData = plan.maskData
            plan.layer.transform = plan.transform
            plan.layer.text = plan.text
        }
        document.width = newWidth
        document.height = newHeight
        document.dpi = min(2400, max(1, dpi))
    }

    static func resizeCanvas(
        document: EditorDocument,
        width newWidth: Int,
        height newHeight: Int,
        anchor: CanvasAnchor
    ) throws {
        try validateTarget(width: newWidth, height: newHeight)
        try requireEditableLayers(document.layers)
        let deltaX = newWidth - document.width
        let deltaY = newHeight - document.height
        let offsetX = anchor.horizontal < 0 ? 0 : (anchor.horizontal == 0 ? deltaX / 2 : deltaX)
        let offsetTop = anchor.vertical < 0 ? 0 : (anchor.vertical == 0 ? deltaY / 2 : deltaY)
        let offsetBottom = anchor.vertical > 0 ? 0 : (anchor.vertical == 0 ? deltaY / 2 : deltaY)

        var plans: [LayerPlan] = []
        plans.reserveCapacity(document.layers.count)
        for layer in document.layers {
            var transform = layer.transform
            transform.x += Double(offsetX)
            transform.y += Double(layer.kind == .text ? offsetTop : offsetBottom)
            var maskData = layer.maskData
            if layer.maskData != nil {
                guard let movedMask = ImageData.canvasData(
                    layer.maskData,
                    width: newWidth,
                    height: newHeight,
                    offsetX: offsetX,
                    offsetY: offsetBottom
                ) else { throw ResizeEngineError.processingFailed(layer.name) }
                maskData = movedMask
            }
            plans.append(LayerPlan(
                layer: layer,
                rasterData: layer.rasterData,
                maskData: maskData,
                transform: transform,
                text: layer.text
            ))
        }
        for plan in plans {
            plan.layer.maskData = plan.maskData
            plan.layer.transform = plan.transform
        }
        document.width = newWidth
        document.height = newHeight
    }

    static func crop(document: EditorDocument, selection: SelectionState) throws -> Bool {
        guard let bounds = cropBounds(for: selection, width: document.width, height: document.height),
              bounds.width >= 1, bounds.height >= 1 else { return false }
        let minX = Int(bounds.minX.rounded(.down))
        let minY = Int(bounds.minY.rounded(.down))
        let newWidth = Int(bounds.width.rounded(.up))
        let newHeight = Int(bounds.height.rounded(.up))
        try validateTarget(width: newWidth, height: newHeight)
        try requireEditableLayers(document.layers)
        let bottomOffset = -(document.height - Int(bounds.maxY.rounded(.up)))

        var plans: [LayerPlan] = []
        plans.reserveCapacity(document.layers.count)
        for layer in document.layers {
            var transform = layer.transform
            transform.x -= Double(minX)
            transform.y += Double(layer.kind == .text ? -minY : bottomOffset)
            var maskData = layer.maskData
            if layer.maskData != nil {
                guard let croppedMask = ImageData.canvasData(
                    layer.maskData,
                    width: newWidth,
                    height: newHeight,
                    offsetX: -minX,
                    offsetY: bottomOffset
                ) else { throw ResizeEngineError.processingFailed(layer.name) }
                maskData = croppedMask
            }
            plans.append(LayerPlan(
                layer: layer,
                rasterData: layer.rasterData,
                maskData: maskData,
                transform: transform,
                text: layer.text
            ))
        }
        for plan in plans {
            plan.layer.maskData = plan.maskData
            plan.layer.transform = plan.transform
        }
        document.width = newWidth
        document.height = newHeight
        return true
    }

    static func fitSize(width: Int, height: Int, maxWidth: Int, maxHeight: Int) -> (Int, Int) {
        let scale = min(Double(maxWidth) / Double(max(1, width)), Double(maxHeight) / Double(max(1, height)))
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    static func validateTarget(width: Int, height: Int) throws {
        guard width > 0,
              height > 0,
              width <= ProjectSafetyLimits.maximumCanvasDimension,
              height <= ProjectSafetyLimits.maximumCanvasDimension else {
            throw ProjectIOError.canvasTooLarge(width: width, height: height)
        }
        let (pixels, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !overflow, pixels <= ProjectSafetyLimits.maximumCanvasPixels else {
            throw ProjectIOError.canvasTooLarge(width: width, height: height)
        }
    }

    private static func requireEditableLayers(_ layers: [EditorLayer]) throws {
        if let locked = layers.first(where: \.isLocked) {
            throw ResizeEngineError.lockedLayer(locked.name)
        }
    }

    /// Core Image's one-channel Lanczos path can fail on grayscale masks on some
    /// renderers. Fall back to a bounded Core Graphics resample so a resize never
    /// turns a valid layer into nil.
    private static func resizedData(
        _ data: Data?,
        width: Int,
        height: Int,
        method: ResizeMethod
    ) -> Data? {
        if let resized = ImageData.resizedData(data, width: width, height: height, method: method) {
            return resized
        }
        guard let source = ImageData.cgImage(from: data) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        switch method {
        case .nearest: context.interpolationQuality = .none
        case .bilinear: context.interpolationQuality = .medium
        case .bicubic, .lanczos: context.interpolationQuality = .high
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().flatMap(ImageData.pngData(from:))
    }

    private struct LayerPlan {
        let layer: EditorLayer
        let rasterData: Data?
        let maskData: Data?
        let transform: LayerTransform
        let text: TextSettings
    }

    static func cropBounds(for selection: SelectionState, width: Int, height: Int) -> CGRect? {
        // Prefer the resolved mask. This makes crop honour feather, expansion,
        // inversion and AI/painter refinements instead of reverting to the raw
        // gesture bounds.
        if let data = selection.maskData ?? selection.sourceMaskData,
           let mask = ImageData.cgImage(from: data),
           let pixels = ImageData.rgbaBytes(from: mask, width: width, height: height) {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where pixels[(y * width + x) * 4] > 18 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard minX <= maxX, minY <= maxY else { return nil }
            // Bitmap rows use Core Graphics' bottom-left coordinate system;
            // expose a top-left canvas rectangle to the editor model.
            return CGRect(
                x: minX,
                y: height - maxY - 1,
                width: maxX - minX + 1,
                height: maxY - minY + 1
            )
        }

        if selection.hasUsableVectorPath {
            let xs = selection.points.map(\.x)
            let ys = selection.points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return nil
    }
}
