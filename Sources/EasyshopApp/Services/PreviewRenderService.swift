import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// An immutable, cheap-to-capture representation of the current document.
///
/// Capture this value on the main actor, then pass it to `PreviewRenderService`.
/// `Data` is copy-on-write, so capturing a request does not duplicate raster
/// payloads. The renderer never touches observable editor models off-main.
struct PreviewRenderRequest: @unchecked Sendable {
    let documentToken: Int
    let revision: UInt64
    let documentWidth: Int
    let documentHeight: Int
    let targetWidth: Int
    let targetHeight: Int
    fileprivate let layers: [PreviewLayerSnapshot]

    /// Creates a viewport-sized request, capped to a bounded render surface.
    ///
    /// - Parameters:
    ///   - document: Current editor document. It is only inspected synchronously.
    ///   - revision: Monotonically increasing workspace render revision.
    ///   - viewportSize: Canvas space available in points.
    ///   - backingScaleFactor: Display scale (normally 2 on Retina).
    ///   - maximumPixelDimension: Memory/latency guard for very large displays.
    @MainActor
    init(
        document: EditorDocument,
        revision: UInt64,
        viewportSize: CGSize,
        backingScaleFactor: CGFloat = NSScreen.main?.backingScaleFactor ?? 2,
        maximumPixelDimension: Int = 2_560
    ) {
        documentToken = ObjectIdentifier(document).hashValue
        self.revision = revision
        documentWidth = document.width
        documentHeight = document.height

        let requestedWidth = max(1, Int((viewportSize.width * backingScaleFactor).rounded(.up)))
        let requestedHeight = max(1, Int((viewportSize.height * backingScaleFactor).rounded(.up)))
        let limit = max(256, maximumPixelDimension)
        let widthLimit = min(requestedWidth, limit)
        let heightLimit = min(requestedHeight, limit)
        let scale = min(
            1,
            min(
                Double(widthLimit) / Double(max(1, document.width)),
                Double(heightLimit) / Double(max(1, document.height))
            )
        )
        targetWidth = max(1, Int((Double(document.width) * scale).rounded()))
        targetHeight = max(1, Int((Double(document.height) * scale).rounded()))
        layers = document.layers.map(PreviewLayerSnapshot.init)
    }
}

/// Metadata returned with a rendered proxy. `scale` maps document coordinates
/// to preview pixels and is useful for overlays and hit-testing.
struct PreviewRenderResult: @unchecked Sendable {
    let image: CGImage
    let revision: UInt64
    let pixelSize: CGSize
    let scale: CGFloat
    let wasCached: Bool
}

/// Serial background renderer for interactive canvas previews.
///
/// The actor bounds memory, caches decoded/downsampled assets, and maintains a
/// short composite LRU. Full-resolution export continues to use
/// `RenderEngine.composite` and is not affected by this service.
actor PreviewRenderService {
    static let shared = PreviewRenderService()
    /// Dedicated queue for full-resolution processing. Keeping it separate from
    /// the canvas renderer means an AI operation cannot stall viewport updates.
    static let processing = PreviewRenderService(
        assetCacheBudget: 96 * 1_024 * 1_024,
        compositeCacheLimit: 1
    )

    private struct CompositeKey: Hashable {
        let documentToken: Int
        let revision: UInt64
        let width: Int
        let height: Int
    }

    private struct AssetKey: Hashable {
        let layerID: UUID
        let role: UInt8
        let fingerprint: UInt64
        let maximumDimension: Int
    }

    private struct CachedAsset {
        let image: CGImage
        let sourceWidth: Int
        let sourceHeight: Int
        let estimatedBytes: Int
    }

    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)
        ?? CGColorSpaceCreateDeviceRGB()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private let context = CIContext(options: [
        .cacheIntermediates: true,
        .workingColorSpace: PreviewRenderService.displayP3,
        .outputColorSpace: PreviewRenderService.sRGB,
        .priorityRequestLow: true
    ])
    // Core Image can refuse a GPU context in headless/test sessions. Keeping a
    // lazy software fallback also makes preview failure non-fatal after a GPU
    // reset; the normal interactive path still uses the hardware context.
    private lazy var softwareContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: true,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])
    private let assetCacheBudget: Int
    private let compositeCacheLimit: Int
    private var assetCache: [AssetKey: CachedAsset] = [:]
    private var assetLRU: [AssetKey] = []
    private var assetCacheBytes = 0
    private var compositeCache: [CompositeKey: CGImage] = [:]
    private var compositeLRU: [CompositeKey] = []

    init(assetCacheBudget: Int = 192 * 1_024 * 1_024, compositeCacheLimit: Int = 4) {
        self.assetCacheBudget = max(16 * 1_024 * 1_024, assetCacheBudget)
        self.compositeCacheLimit = max(1, compositeCacheLimit)
    }

    /// Produces a bounded preview off the main actor.
    ///
    /// Callers should cancel their previous Task when a newer revision arrives,
    /// and only publish a result whose `revision` is still current. Cancellation
    /// is checked before expensive decode and before final rasterization.
    func render(_ request: PreviewRenderRequest) -> PreviewRenderResult? {
        guard request.documentWidth > 0,
              request.documentHeight > 0,
              request.targetWidth > 0,
              request.targetHeight > 0,
              !Task.isCancelled else { return nil }

        let compositeKey = CompositeKey(
            documentToken: request.documentToken,
            revision: request.revision,
            width: request.targetWidth,
            height: request.targetHeight
        )
        if let cached = compositeCache[compositeKey] {
            touchComposite(compositeKey)
            return result(cached, request: request, wasCached: true)
        }

        let extent = CGRect(x: 0, y: 0, width: request.targetWidth, height: request.targetHeight)
        let documentScale = Double(request.targetWidth) / Double(request.documentWidth)
        var output = CIImage(color: .clear).cropped(to: extent)

        for layer in request.layers where layer.isVisible {
            guard !Task.isCancelled else { return nil }

            if layer.kind == .adjustment {
                let adjusted = RenderEngine.apply(layer.adjustment, to: output).cropped(to: extent)
                if let mask = previewMask(for: layer, request: request) {
                    let weightedMask = opacityAdjustedMask(mask.cropped(to: extent), opacity: layer.opacity)
                    output = blendWithMask(foreground: adjusted, background: output, mask: weightedMask)
                } else if layer.opacity < 0.999 {
                    let mask = CIImage(
                        color: CIColor(red: 1, green: 1, blue: 1, alpha: layer.opacity)
                    ).cropped(to: extent)
                    output = blendWithMask(foreground: adjusted, background: output, mask: mask)
                } else {
                    output = adjusted
                }
                continue
            }

            guard var image = previewImage(for: layer, request: request, scale: documentScale) else { continue }
            image = image.cropped(to: extent)
            image = opacityAdjustedImage(image, opacity: layer.opacity)
            if let mask = previewMask(for: layer, request: request) {
                image = blendWithMask(
                    foreground: image,
                    background: CIImage(color: .clear).cropped(to: extent),
                    mask: mask.cropped(to: extent)
                )
            }
            output = composite(image, over: output, mode: layer.blendMode).cropped(to: extent)
        }

        guard !Task.isCancelled else { return nil }
        guard let image = context.createCGImage(output, from: extent)
            ?? softwareContext.createCGImage(output, from: extent) else { return nil }
        insertComposite(image, for: compositeKey)
        return result(image, request: request, wasCached: false)
    }

    /// Renders and encodes a full-resolution request away from the main actor.
    /// Processing requests use the dedicated `processing` instance and purge
    /// their large transient buffers immediately after encoding.
    func renderPNG(_ request: PreviewRenderRequest) -> Data? {
        guard let result = render(request), !Task.isCancelled else { return nil }
        let data = ImageData.pngData(from: result.image)
        purgeCaches()
        return data
    }

    /// Clears all cached image data, for example after a memory-pressure event.
    func purgeCaches() {
        assetCache.removeAll(keepingCapacity: false)
        assetLRU.removeAll(keepingCapacity: false)
        assetCacheBytes = 0
        compositeCache.removeAll(keepingCapacity: false)
        compositeLRU.removeAll(keepingCapacity: false)
        context.clearCaches()
        softwareContext.clearCaches()
    }

    private func result(
        _ image: CGImage,
        request: PreviewRenderRequest,
        wasCached: Bool
    ) -> PreviewRenderResult {
        PreviewRenderResult(
            image: image,
            revision: request.revision,
            pixelSize: CGSize(width: request.targetWidth, height: request.targetHeight),
            scale: CGFloat(request.targetWidth) / CGFloat(request.documentWidth),
            wasCached: wasCached
        )
    }

    private func previewImage(
        for layer: PreviewLayerSnapshot,
        request: PreviewRenderRequest,
        scale documentScale: Double
    ) -> CIImage? {
        switch layer.kind {
        case .raster:
            guard let asset = cachedAsset(
                data: layer.rasterData,
                layerID: layer.id,
                role: 0,
                maximumDimension: max(request.targetWidth, request.targetHeight)
            ) else { return nil }
            var image = CIImage(cgImage: asset.image)
            image = image.transformed(by: CGAffineTransform(
                scaleX: Double(asset.sourceWidth) / Double(asset.image.width),
                y: Double(asset.sourceHeight) / Double(asset.image.height)
            ))
            var layerTransform = CGAffineTransform.identity
            layerTransform = layerTransform.translatedBy(x: layer.transform.x, y: layer.transform.y)
            layerTransform = layerTransform.rotated(by: layer.transform.rotationDegrees * .pi / 180)
            layerTransform = layerTransform.scaledBy(x: layer.transform.scaleX, y: layer.transform.scaleY)
            image = image.transformed(by: layerTransform)
            return image.transformed(by: CGAffineTransform(scaleX: documentScale, y: documentScale))

        case .text:
            var settings = layer.text
            settings.fontSize *= documentScale
            settings.tracking *= documentScale
            settings.width *= documentScale
            var transform = layer.transform
            transform.x *= documentScale
            transform.y *= documentScale
            return RenderEngine.renderText(
                settings,
                transform: transform,
                canvasSize: CGSize(width: request.targetWidth, height: request.targetHeight)
            ).map(CIImage.init(cgImage:))

        case .adjustment:
            return nil
        }
    }

    private func previewMask(for layer: PreviewLayerSnapshot, request: PreviewRenderRequest) -> CIImage? {
        guard let asset = cachedAsset(
            data: layer.maskData,
            layerID: layer.id,
            role: 1,
            maximumDimension: max(request.targetWidth, request.targetHeight)
        ) else { return nil }
        let image = CIImage(cgImage: asset.image)
        return image.transformed(by: CGAffineTransform(
            scaleX: Double(request.targetWidth) / Double(asset.image.width),
            y: Double(request.targetHeight) / Double(asset.image.height)
        ))
    }

    private func cachedAsset(
        data: Data?,
        layerID: UUID,
        role: UInt8,
        maximumDimension: Int
    ) -> CachedAsset? {
        guard let data else { return nil }
        let key = AssetKey(
            layerID: layerID,
            role: role,
            fingerprint: Self.fingerprint(data),
            maximumDimension: maximumDimension
        )
        if let cached = assetCache[key] {
            touchAsset(key)
            return cached
        }
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumDimension),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let asset = CachedAsset(
            image: image,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            estimatedBytes: image.bytesPerRow * image.height
        )
        insertAsset(asset, for: key)
        return asset
    }

    /// O(1) with respect to image payload size: length plus small edge samples.
    /// Revision protects edits inside a document; this fingerprint distinguishes
    /// replaced payloads while keeping request capture and slider updates cheap.
    private static func fingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { bytes in
            for byte in bytes { mix(byte) }
        }
        for byte in data.prefix(32) { mix(byte) }
        for byte in data.suffix(32) { mix(byte) }
        return hash
    }

    private func insertAsset(_ asset: CachedAsset, for key: AssetKey) {
        if let old = assetCache.updateValue(asset, forKey: key) {
            assetCacheBytes -= old.estimatedBytes
        }
        assetCacheBytes += asset.estimatedBytes
        touchAsset(key)
        while assetCacheBytes > assetCacheBudget, let oldest = assetLRU.first {
            assetLRU.removeFirst()
            if let removed = assetCache.removeValue(forKey: oldest) {
                assetCacheBytes -= removed.estimatedBytes
            }
        }
    }

    private func touchAsset(_ key: AssetKey) {
        assetLRU.removeAll { $0 == key }
        assetLRU.append(key)
    }

    private func insertComposite(_ image: CGImage, for key: CompositeKey) {
        compositeCache[key] = image
        touchComposite(key)
        while compositeLRU.count > compositeCacheLimit {
            compositeCache.removeValue(forKey: compositeLRU.removeFirst())
        }
    }

    private func touchComposite(_ key: CompositeKey) {
        compositeLRU.removeAll { $0 == key }
        compositeLRU.append(key)
    }

    private func opacityAdjustedImage(_ image: CIImage, opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
        return filter.outputImage ?? image
    }

    private func opacityAdjustedMask(_ image: CIImage, opacity: Double) -> CIImage {
        guard opacity < 0.999 else { return image }
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: opacity, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: opacity, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: opacity, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage ?? image
    }

    private func blendWithMask(foreground: CIImage, background: CIImage, mask: CIImage) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = foreground
        filter.backgroundImage = background
        filter.maskImage = mask
        return filter.outputImage ?? foreground
    }

    private func composite(_ foreground: CIImage, over background: CIImage, mode: BlendMode) -> CIImage {
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

private struct PreviewLayerSnapshot: @unchecked Sendable {
    let id: UUID
    let kind: LayerKind
    let isVisible: Bool
    let opacity: Double
    let blendMode: BlendMode
    let transform: LayerTransform
    let text: TextSettings
    let adjustment: AdjustmentSettings
    let rasterData: Data?
    let maskData: Data?

    @MainActor
    init(_ layer: EditorLayer) {
        id = layer.id
        kind = layer.kind
        isVisible = layer.isVisible
        opacity = layer.opacity
        blendMode = layer.blendMode
        transform = layer.transform
        text = layer.text
        adjustment = layer.adjustment
        rasterData = layer.rasterData
        maskData = layer.maskData
    }
}
