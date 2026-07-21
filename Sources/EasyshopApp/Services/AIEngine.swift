@preconcurrency import AppKit
@preconcurrency import CoreImage
@preconcurrency import Vision
import Foundation

enum AIEngineError: LocalizedError {
    case noSubject
    case noFace
    case missingSelection
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .noSubject: "Non ho individuato un soggetto separabile. Prova con una selezione manuale."
        case .noFace: "Non ho individuato volti nell’immagine."
        case .missingSelection: "Crea prima una selezione sull’area da cancellare."
        case .processingFailed: "L’elaborazione locale non è riuscita."
        }
    }
}

enum SubjectMaskProvenance: String, Sendable {
    case visionForegroundInstances
    case visionPersonSegmentation
    case visionAttentionSaliency
    case classicalForeground

    var isVisionML: Bool {
        switch self {
        case .visionForegroundInstances, .visionPersonSegmentation, .visionAttentionSaliency: true
        case .classicalForeground: false
        }
    }

    var userFacingLabel: String {
        isVisionML ? "Vision ML" : "selezione locale non‑AI"
    }
}

struct SubjectMaskResult: Sendable {
    let maskData: Data
    let provenance: SubjectMaskProvenance

    /// Keeps the visual/editor state honest by construction: only results
    /// produced by a Vision request receive the AI selection kind.
    var selectionKind: SelectionKind {
        provenance.isVisionML ? .ai : .lasso
    }
}

enum AIEngine {
    /// Builds a clean, full-resolution foreground mask. When a point is supplied,
    /// Vision's foreground instances are inspected and only the instance below (or
    /// nearest to) that point is selected. Without a point, insignificant fragments
    /// are discarded while all visually meaningful subjects are kept.
    static func subjectMask(from imageData: Data, selectedPoint: CanvasPoint? = nil) async throws -> SubjectMaskResult {
        // Capture primitive values before entering the detached task. This keeps the
        // Vision work fully off the main actor without sending the model value itself.
        let pointX = selectedPoint?.x
        let pointY = selectedPoint?.y
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let image = ImageData.cgImage(from: imageData) else { throw AIEngineError.processingFailed }
            if #available(macOS 14.0, *) {
                do {
                    return SubjectMaskResult(
                        maskData: try foregroundInstanceMask(
                            image: image,
                            pointX: pointX,
                            pointY: pointY
                        ),
                        provenance: .visionForegroundInstances
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Some Intel Macs, virtualized systems and older Neural Engine
                    // runtimes cannot load the instance model. Portrait segmentation
                    // and saliency use independent Vision pipelines, so the feature
                    // remains useful instead of failing with a generic alert.
                    if let personMask = try? personSegmentationMask(image: image),
                       maskCoverageIsUsable(personMask) {
                        return SubjectMaskResult(maskData: personMask, provenance: .visionPersonSegmentation)
                    }
                    if let saliencyMask = try? attentionSaliencyMask(image: image),
                       maskCoverageIsUsable(saliencyMask) {
                        return SubjectMaskResult(maskData: saliencyMask, provenance: .visionAttentionSaliency)
                    }
                    if let classicalMask = classicalForegroundMask(
                        image: image,
                        pointX: pointX,
                        pointY: pointY
                    ), maskCoverageIsUsable(classicalMask) {
                        return SubjectMaskResult(maskData: classicalMask, provenance: .classicalForeground)
                    }
                    throw AIEngineError.noSubject
                }
            }
            throw AIEngineError.processingFailed
        }.value
    }

    @available(macOS 14.0, *)
    private static func foregroundInstanceMask(
        image: CGImage,
        pointX: Double?,
        pointY: Double?
    ) throws -> Data {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw AIEngineError.noSubject }
        let instances = try foregroundInstances(
            in: observation,
            imageWidth: image.width,
            imageHeight: image.height,
            pointX: pointX,
            pointY: pointY
        )
        guard !instances.isEmpty else { throw AIEngineError.noSubject }
        try Task.checkCancellation()
        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: instances,
            from: handler
        )
        guard let data = polishedMaskData(
            from: maskBuffer,
            width: image.width,
            height: image.height
        ), maskCoverageIsUsable(data) else {
            throw AIEngineError.noSubject
        }
        return data
    }

    private static func personSegmentationMask(image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer,
              let data = polishedMaskData(from: buffer, width: image.width, height: image.height) else {
            throw AIEngineError.noSubject
        }
        return data
    }

    private static func attentionSaliencyMask(image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer,
              let data = polishedMaskData(from: buffer, width: image.width, height: image.height) else {
            throw AIEngineError.noSubject
        }
        return data
    }

    /// CPU-only fallback for Macs where a Vision segmentation model is unavailable.
    /// It learns several background colours from the image perimeter, creates a
    /// foreground probability map, then retains the most plausible connected region.
    /// This is intentionally conservative: it is a usable starting mask, never a
    /// destructive edit, and the user can still expand or feather it afterwards.
    static func classicalForegroundMask(
        image: CGImage,
        pointX: Double?,
        pointY: Double?
    ) -> Data? {
        let maximumSide = 384.0
        let scale = min(1, maximumSide / Double(max(image.width, image.height)))
        let width = max(32, Int((Double(image.width) * scale).rounded()))
        let height = max(32, Int((Double(image.height) * scale).rounded()))
        guard let rgba = ImageData.rgbaBytes(from: image, width: width, height: height) else { return nil }

        struct RGBVector {
            var r: Double
            var g: Double
            var b: Double

            func distanceSquared(to other: RGBVector) -> Double {
                let dr = r - other.r
                let dg = g - other.g
                let db = b - other.b
                // Green carries most luminance detail, but chroma differences are
                // also important around skin, foliage and fabric.
                return dr * dr * 0.30 + dg * dg * 0.46 + db * db * 0.24
            }
        }

        func colorAt(x: Int, y: Int) -> RGBVector {
            let offset = (y * width + x) * 4
            return RGBVector(
                r: Double(rgba[offset]) / 255,
                g: Double(rgba[offset + 1]) / 255,
                b: Double(rgba[offset + 2]) / 255
            )
        }

        let strideLength = max(1, min(width, height) / 96)
        let rimDepth = max(2, min(width, height) / 80)
        var border: [RGBVector] = []
        for depth in 0..<rimDepth {
            for x in Swift.stride(from: 0, to: width, by: strideLength) {
                border.append(colorAt(x: x, y: depth))
                border.append(colorAt(x: x, y: height - 1 - depth))
            }
            for y in Swift.stride(from: 0, to: height, by: strideLength) {
                border.append(colorAt(x: depth, y: y))
                border.append(colorAt(x: width - 1 - depth, y: y))
            }
        }
        guard let first = border.first else { return nil }

        // Deterministic farthest-point initialization covers skies, floors and side
        // backgrounds more reliably than a single averaged border colour.
        let clusterCount = min(8, max(3, border.count / 100))
        var centroids = [first]
        while centroids.count < clusterCount {
            guard let farthest = border.max(by: { lhs, rhs in
                let left = centroids.map { lhs.distanceSquared(to: $0) }.min() ?? 0
                let right = centroids.map { rhs.distanceSquared(to: $0) }.min() ?? 0
                return left < right
            }) else { break }
            centroids.append(farthest)
        }
        for _ in 0..<6 {
            var totals: [(r: Double, g: Double, b: Double, count: Int)] = Array(
                repeating: (0, 0, 0, 0),
                count: centroids.count
            )
            for sample in border {
                let index = centroids.indices.min(by: {
                    sample.distanceSquared(to: centroids[$0]) < sample.distanceSquared(to: centroids[$1])
                }) ?? 0
                totals[index].r += sample.r
                totals[index].g += sample.g
                totals[index].b += sample.b
                totals[index].count += 1
            }
            for index in centroids.indices where totals[index].count > 0 {
                let count = Double(totals[index].count)
                centroids[index] = RGBVector(
                    r: totals[index].r / count,
                    g: totals[index].g / count,
                    b: totals[index].b / count
                )
            }
        }

        let selectedX = pointX.map { min(width - 1, max(0, Int($0 / Double(max(1, image.width)) * Double(width)))) }
        let selectedY = pointY.map { min(height - 1, max(0, Int($0 / Double(max(1, image.height)) * Double(height)))) }
        let selectedColor: RGBVector?
        if let selectedX, let selectedY {
            selectedColor = colorAt(x: selectedX, y: selectedY)
        } else {
            selectedColor = nil
        }
        var probability = [Double](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let pixel = colorAt(x: x, y: y)
                let distance = centroids.map { pixel.distanceSquared(to: $0) }.min() ?? 0
                let novelty = min(1, max(0, (sqrt(distance) - 0.035) / 0.19))
                let normalizedX = (Double(x) / Double(max(1, width - 1)) - 0.5) / 0.72
                let normalizedY = (Double(y) / Double(max(1, height - 1)) - 0.5) / 0.82
                let centerPrior = max(0, 1 - hypot(normalizedX, normalizedY))
                var value = novelty * (0.78 + 0.22 * centerPrior)

                if let selectedX, let selectedY, let selectedColor {
                    let colorSimilarity = exp(-pixel.distanceSquared(to: selectedColor) * 14)
                    let dx = Double(x - selectedX) / Double(max(1, width))
                    let dy = Double(y - selectedY) / Double(max(1, height))
                    let spatialAffinity = exp(-(dx * dx + dy * dy) * 7)
                    value = max(value, colorSimilarity * spatialAffinity * 0.88)
                }
                probability[y * width + x] = value
            }
        }

        var foreground = probability.map { $0 > 0.31 }
        // Never treat the outermost rim as foreground. It is the background seed and
        // this also prevents accidental full-canvas masks on low-contrast photographs.
        for x in 0..<width {
            foreground[x] = false
            foreground[(height - 1) * width + x] = false
        }
        for y in 0..<height {
            foreground[y * width] = false
            foreground[y * width + width - 1] = false
        }

        var labels = [Int](repeating: -1, count: width * height)
        var components: [(indices: [Int], score: Double, touchesPoint: Bool, nearestPoint: Double)] = []
        let neighbours = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for start in foreground.indices where foreground[start] && labels[start] < 0 {
            let componentIndex = components.count
            var queue = [start]
            var cursor = 0
            var indices: [Int] = []
            var centralScore = 0.0
            var touchesPoint = false
            var nearestPoint = Double.greatestFiniteMagnitude
            labels[start] = componentIndex
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                indices.append(index)
                let x = index % width
                let y = index / width
                centralScore += probability[index]
                if let selectedX, let selectedY {
                    let distance = Double((x - selectedX) * (x - selectedX) + (y - selectedY) * (y - selectedY))
                    nearestPoint = min(nearestPoint, distance)
                    if distance <= 9 { touchesPoint = true }
                }
                for (dx, dy) in neighbours {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    guard foreground[next], labels[next] < 0 else { continue }
                    labels[next] = componentIndex
                    queue.append(next)
                }
            }
            components.append((indices, centralScore, touchesPoint, nearestPoint))
        }
        guard !components.isEmpty else { return nil }

        let retained: [(indices: [Int], score: Double, touchesPoint: Bool, nearestPoint: Double)]
        if selectedX != nil {
            let best = components.min { lhs, rhs in
                if lhs.touchesPoint != rhs.touchesPoint { return lhs.touchesPoint }
                if lhs.nearestPoint == rhs.nearestPoint { return lhs.indices.count > rhs.indices.count }
                return lhs.nearestPoint < rhs.nearestPoint
            }
            retained = best.map { [$0] } ?? []
        } else {
            let bestArea = components.map { $0.indices.count }.max() ?? 1
            retained = components
                .filter { $0.indices.count >= max(20, bestArea / 7) }
                .sorted { lhs, rhs in
                    (Double(lhs.indices.count) + lhs.score * 0.18) > (Double(rhs.indices.count) + rhs.score * 0.18)
                }
                .prefix(5)
                .map { $0 }
        }

        var bytes = [UInt8](repeating: 0, count: width * height)
        for component in retained {
            for index in component.indices {
                bytes[index] = UInt8(min(255, max(0, Int(probability[index] * 310))))
            }
        }
        guard let rawMask = ImageData.grayscaleImage(bytes: bytes, width: width, height: height) else { return nil }
        // Core Graphics' high-quality interpolation is stable for grayscale images
        // on hardware where Core Image's one-channel morphology path is unavailable.
        guard let scaledRGBA = ImageData.rgbaBytes(from: rawMask, width: image.width, height: image.height) else { return nil }
        var fullSize = [UInt8](repeating: 0, count: image.width * image.height)
        for index in fullSize.indices { fullSize[index] = scaledRGBA[index * 4] }
        guard let result = ImageData.grayscaleImage(bytes: fullSize, width: image.width, height: image.height) else { return nil }
        return ImageData.pngData(from: result)
    }

    @available(macOS 14.0, *)
    private struct ForegroundInstanceScore {
        let index: Int
        let area: Int
        let pointAffinity: Double
        let nearestDistanceSquared: Double
        let centrality: Double
    }

    /// Scores Vision's low-resolution instance masks. This is deliberately done at
    /// analysis resolution: it stays responsive even with 100-megapixel photographs.
    @available(macOS 14.0, *)
    private static func foregroundInstances(
        in observation: VNInstanceMaskObservation,
        imageWidth: Int,
        imageHeight: Int,
        pointX: Double?,
        pointY: Double?
    ) throws -> IndexSet {
        let indexes = observation.allInstances.map { $0 }
        guard !indexes.isEmpty else { return [] }

        var scores: [ForegroundInstanceScore] = []
        scores.reserveCapacity(indexes.count)

        for index in indexes {
            try Task.checkCancellation()
            let buffer = try observation.generateMask(forInstances: IndexSet(integer: index))
            guard let analysis = analyzeMask(
                buffer,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                pointX: pointX,
                pointY: pointY
            ), analysis.area > 0 else { continue }
            scores.append(ForegroundInstanceScore(
                index: index,
                area: analysis.area,
                pointAffinity: analysis.pointAffinity,
                nearestDistanceSquared: analysis.nearestDistanceSquared,
                centrality: analysis.centrality
            ))
        }
        guard !scores.isEmpty else { return observation.allInstances }

        if pointX != nil, pointY != nil {
            // A soft neighbourhood makes selection tolerant of clicks on hair,
            // translucent fabric and anti-aliased boundaries. If the user clicked
            // just outside the subject, choose the nearest instance instead.
            if let hit = scores.max(by: { $0.pointAffinity < $1.pointAffinity }), hit.pointAffinity > 0.035 {
                return IndexSet(integer: hit.index)
            }
            let nearest = scores.min { lhs, rhs in
                if lhs.nearestDistanceSquared == rhs.nearestDistanceSquared {
                    return lhs.area > rhs.area
                }
                return lhs.nearestDistanceSquared < rhs.nearestDistanceSquared
            }
            if let nearest {
                return IndexSet(integer: nearest.index)
            }
        }

        let largestArea = scores.map(\.area).max() ?? 1
        let analysisPixels = max(1, scores.reduce(0) { max($0, $1.area) })
        let sorted = scores.sorted {
            let lhs = Double($0.area) * (0.72 + 0.28 * $0.centrality)
            let rhs = Double($1.area) * (0.72 + 0.28 * $1.centrality)
            return lhs > rhs
        }
        let primary = sorted.first!

        // Preserve groups and supporting subjects, but reject tiny disconnected
        // fragments commonly produced by foliage, reflections and distant signage.
        let selected = sorted
            .filter { score in
                score.index == primary.index
                    || score.area >= max(24, Int(Double(largestArea) * 0.10))
                    || (score.area >= max(48, analysisPixels / 80) && score.centrality > 0.58)
            }
            .prefix(8)
            .map(\.index)
        return IndexSet(selected)
    }

    private struct MaskAnalysis {
        let area: Int
        let pointAffinity: Double
        let nearestDistanceSquared: Double
        let centrality: Double
    }

    private static func analyzeMask(
        _ buffer: CVPixelBuffer,
        imageWidth: Int,
        imageHeight: Int,
        pointX: Double?,
        pointY: Double?
    ) -> MaskAnalysis? {
        let input = CIImage(cvPixelBuffer: buffer)
        let extent = input.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        guard let pixels = grayscaleBytes(
            from: input,
            bounds: extent,
            width: width,
            height: height
        ) else { return nil }

        let sampleX = pointX.map { min(width - 1, max(0, Int(($0 / Double(max(1, imageWidth))) * Double(width)))) }
        let sampleY = pointY.map { min(height - 1, max(0, Int(($0 / Double(max(1, imageHeight))) * Double(height)))) }
        let radius = max(2, min(width, height) / 80)
        var area = 0
        var weightedX = 0.0
        var weightedY = 0.0
        var affinity = 0.0
        var nearest = Double.greatestFiniteMagnitude

        for y in 0..<height {
            for x in 0..<width {
                let value = Double(pixels[y * width + x]) / 255
                guard value > 0.04 else { continue }
                if value > 0.42 {
                    area += 1
                    weightedX += Double(x)
                    weightedY += Double(y)
                }
                if let sampleX, let sampleY {
                    let dx = x - sampleX
                    let dy = y - sampleY
                    if abs(dx) <= radius, abs(dy) <= radius {
                        let falloff = 1 - min(1, hypot(Double(dx), Double(dy)) / Double(radius + 1))
                        affinity = max(affinity, value * (0.55 + 0.45 * falloff))
                    }
                    if value > 0.42 {
                        nearest = min(nearest, Double(dx * dx + dy * dy))
                    }
                }
            }
        }
        guard area > 0 else { return nil }
        let centroidX = weightedX / Double(area) / Double(width)
        let centroidY = weightedY / Double(area) / Double(height)
        let distanceFromCenter = min(1, hypot(centroidX - 0.5, centroidY - 0.5) / 0.7071)
        return MaskAnalysis(
            area: area,
            pointAffinity: affinity,
            nearestDistanceSquared: nearest,
            centrality: 1 - distanceFromCenter
        )
    }

    /// Converts Vision's floating-point mask to a predictable 8-bit grayscale PNG.
    /// A tiny morphological close removes pinholes; sub-pixel smoothing preserves
    /// hair and avoids the cut-out look without baking in a visible feather.
    private static func polishedMaskData(from buffer: CVPixelBuffer, width: Int, height: Int) -> Data? {
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(cvPixelBuffer: buffer)
        if Int(image.extent.width) != width || Int(image.extent.height) != height {
            image = image.transformed(by: CGAffineTransform(
                scaleX: Double(width) / max(1, image.extent.width),
                y: Double(height) / max(1, image.extent.height)
            ))
        }
        image = image
            .cropped(to: target)
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 0.8])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 0.8])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.55])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.16,
                kCIInputBrightnessKey: -0.012
            ])
            .cropped(to: target)

        guard let pixels = grayscaleBytes(
            from: image,
            bounds: target,
            width: width,
            height: height
        ) else { return nil }
        guard let mask = ImageData.grayscaleImage(bytes: pixels, width: width, height: height) else { return nil }
        return ImageData.pngData(from: mask)
    }

    /// Rendering one-channel CI images directly to `.L8` is not reliable on every
    /// macOS GPU/virtualization combination. Rendering a CGImage first and reading
    /// its red channel is a little more work, but produces identical, deterministic
    /// mask bytes on Apple Silicon, Intel and software renderers.
    private static func grayscaleBytes(
        from image: CIImage,
        bounds: CGRect,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let rendered = context.createCGImage(image, from: bounds),
              let rgba = ImageData.rgbaBytes(from: rendered, width: width, height: height) else { return nil }
        var grayscale = [UInt8](repeating: 0, count: width * height)
        for index in grayscale.indices {
            grayscale[index] = rgba[index * 4]
        }
        return grayscale
    }

    private static func maskCoverageIsUsable(_ data: Data) -> Bool {
        guard let image = ImageData.cgImage(from: data),
              let bytes = ImageData.rgbaBytes(
                from: image,
                width: min(256, image.width),
                height: min(256, image.height)
              ) else { return false }
        var selected = 0
        var samples = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[offset] > 18 { selected += 1 }
            samples += 1
        }
        let coverage = Double(selected) / Double(max(1, samples))
        return coverage > 0.0008 && coverage < 0.998
    }

    static func faceMask(from imageData: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let image = ImageData.cgImage(from: imageData) else { throw AIEngineError.processingFailed }
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            guard let faces = request.results, !faces.isEmpty else { throw AIEngineError.noFace }

            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height)
            guard let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { throw AIEngineError.processingFailed }
            context.setFillColor(gray: 1, alpha: 1)
            for face in faces {
                let box = face.boundingBox
                let expanded = CGRect(
                    x: (box.minX - box.width * 0.12) * Double(width),
                    y: (box.minY - box.height * 0.18) * Double(height),
                    width: box.width * 1.24 * Double(width),
                    height: box.height * 1.36 * Double(height)
                )
                context.fillEllipse(in: expanded)
            }
            guard let raw = ImageData.grayscaleImage(bytes: pixels, width: width, height: height) else {
                throw AIEngineError.processingFailed
            }
            let input = CIImage(cgImage: raw)
            let radius = max(6, min(width, height) / 100)
            let softened = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: input.extent)
            guard let output = CIContext().createCGImage(softened, from: softened.extent),
                  let data = ImageData.pngData(from: output) else { throw AIEngineError.processingFailed }
            return data
        }.value
    }

    static func skyMask(from imageData: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let image = ImageData.cgImage(from: imageData),
                  let rgba = ImageData.rgbaBytes(from: image) else { throw AIEngineError.processingFailed }
            let width = image.width
            let height = image.height
            var mask = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                let vertical = max(0, 1 - Double(y) / (Double(height) * 0.72))
                guard vertical > 0 else { continue }
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let r = Double(rgba[offset]) / 255
                    let g = Double(rgba[offset + 1]) / 255
                    let b = Double(rgba[offset + 2]) / 255
                    let blueConfidence = max(0, b - max(r * 0.78, g * 0.82)) * 3.8
                    let brightNeutral = max(0, min(r, min(g, b)) - 0.62) * 0.55
                    let confidence = min(1, (blueConfidence + brightNeutral) * vertical)
                    mask[y * width + x] = UInt8(confidence * 255)
                }
            }
            guard let raw = ImageData.grayscaleImage(bytes: mask, width: width, height: height) else {
                throw AIEngineError.processingFailed
            }
            let input = CIImage(cgImage: raw)
            let softened = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 8])
                .cropped(to: input.extent)
            guard let output = CIContext().createCGImage(softened, from: softened.extent),
                  let data = ImageData.pngData(from: output) else { throw AIEngineError.processingFailed }
            return data
        }.value
    }

    static func recommendedAdjustments(for imageData: Data) async -> AdjustmentSettings {
        await Task.detached(priority: .utility) {
            guard let image = ImageData.cgImage(from: imageData),
                  let rgba = ImageData.rgbaBytes(from: image, width: min(256, image.width), height: min(256, image.height)) else {
                return AdjustmentSettings.autoEnhance
            }
            var luminance = 0.0
            var saturation = 0.0
            var count = 0.0
            for offset in stride(from: 0, to: rgba.count, by: 16) {
                let r = Double(rgba[offset]) / 255
                let g = Double(rgba[offset + 1]) / 255
                let b = Double(rgba[offset + 2]) / 255
                luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
                let maximum = max(r, max(g, b))
                let minimum = min(r, min(g, b))
                saturation += maximum == 0 ? 0 : (maximum - minimum) / maximum
                count += 1
            }
            let averageLuminance = luminance / max(1, count)
            let averageSaturation = saturation / max(1, count)
            var settings = AdjustmentSettings.autoEnhance
            settings.exposure = min(0.45, max(-0.25, (0.48 - averageLuminance) * 0.8))
            settings.vibrance = averageSaturation < 0.3 ? 0.28 : 0.12
            settings.saturation = averageSaturation > 0.65 ? 0.96 : 1.04
            return settings
        }.value
    }

    static func smartErase(imageData: Data, maskData: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let image = ImageData.cgImage(from: imageData),
                  let maskImage = ImageData.cgImage(from: maskData),
                  var pixels = ImageData.rgbaBytes(from: image),
                  let maskRGBA = ImageData.rgbaBytes(from: maskImage, width: image.width, height: image.height) else {
                throw AIEngineError.processingFailed
            }
            let width = image.width
            let height = image.height
            var unknown = [Bool](repeating: false, count: width * height)
            for index in 0..<unknown.count {
                unknown[index] = maskRGBA[index * 4] > 40
            }

            let neighborOffsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
            let maxPasses = min(192, max(width, height))
            for _ in 0..<maxPasses {
                var updates: [(Int, UInt8, UInt8, UInt8, UInt8)] = []
                updates.reserveCapacity(4096)
                for y in 1..<(height - 1) {
                    for x in 1..<(width - 1) {
                        let index = y * width + x
                        guard unknown[index] else { continue }
                        var totals = [Int](repeating: 0, count: 4)
                        var samples = 0
                        for (dx, dy) in neighborOffsets {
                            let neighbor = (y + dy) * width + (x + dx)
                            guard !unknown[neighbor] else { continue }
                            let offset = neighbor * 4
                            for channel in 0..<4 { totals[channel] += Int(pixels[offset + channel]) }
                            samples += 1
                        }
                        if samples >= 2 {
                            updates.append((
                                index,
                                UInt8(totals[0] / samples),
                                UInt8(totals[1] / samples),
                                UInt8(totals[2] / samples),
                                UInt8(totals[3] / samples)
                            ))
                        }
                    }
                }
                if updates.isEmpty { break }
                for update in updates {
                    let offset = update.0 * 4
                    pixels[offset] = update.1
                    pixels[offset + 1] = update.2
                    pixels[offset + 2] = update.3
                    pixels[offset + 3] = update.4
                    unknown[update.0] = false
                }
                if !unknown.contains(true) { break }
            }
            guard let result = ImageData.cgImage(rgba: pixels, width: width, height: height),
                  let data = ImageData.pngData(from: result) else { throw AIEngineError.processingFailed }
            return data
        }.value
    }

    static func upscale(imageData: Data, factor: Double = 2) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let cgImage = ImageData.cgImage(from: imageData) else { throw AIEngineError.processingFailed }
            let input = CIImage(cgImage: cgImage)
            let scaled = input.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: factor,
                kCIInputAspectRatioKey: 1
            ]).applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.35])
            let extent = CGRect(x: 0, y: 0, width: Double(cgImage.width) * factor, height: Double(cgImage.height) * factor)
            guard let image = CIContext().createCGImage(scaled, from: extent),
                  let data = ImageData.pngData(from: image) else { throw AIEngineError.processingFailed }
            return data
        }.value
    }
}
