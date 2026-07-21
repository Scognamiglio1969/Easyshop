import CoreGraphics
import Foundation

/// Minimal, dependency-free PSD exporter. It writes 8-bit RGBA raster layers and
/// a merged preview. Text, masks and adjustments remain fully editable in the
/// native .easyshop project and are rasterized only for PSD interoperability.
@MainActor
enum PSDWriter {
    struct RasterizedLayer {
        var name: String
        var image: CGImage
        var opacity: UInt8
        var visible: Bool
        var blendKey: String
    }

    static func write(document: EditorDocument, composite: CGImage, to url: URL) throws {
        let width = document.width
        let height = document.height
        var rasterized: [RasterizedLayer] = []

        for (index, layer) in document.layers.enumerated() {
            if layer.kind == .adjustment {
                if let cumulative = RenderEngine.composite(document: document, through: index) {
                    rasterized.append(RasterizedLayer(
                        name: "\(layer.name) — rasterizzata",
                        image: cumulative,
                        opacity: 255,
                        visible: layer.isVisible,
                        blendKey: "norm"
                    ))
                }
            } else if let ci = RenderEngine.renderedLayer(layer, canvasSize: CGSize(width: width, height: height)),
                      let image = RenderEngine.makeCGImage(ci, from: CGRect(x: 0, y: 0, width: width, height: height)) {
                rasterized.append(RasterizedLayer(
                    name: layer.kind == .text ? "\(layer.name) — testo rasterizzato" : layer.name,
                    image: image,
                    opacity: 255,
                    visible: layer.isVisible,
                    blendKey: psdBlendKey(layer.blendMode)
                ))
            }
        }
        if rasterized.isEmpty {
            rasterized = [RasterizedLayer(name: "Easyshop Composite", image: composite, opacity: 255, visible: true, blendKey: "norm")]
        }

        var data = Data()
        data.appendASCII("8BPS")
        data.appendBE(UInt16(1))
        data.append(Data(repeating: 0, count: 6))
        data.appendBE(UInt16(4))
        data.appendBE(UInt32(height))
        data.appendBE(UInt32(width))
        data.appendBE(UInt16(8))
        data.appendBE(UInt16(3))
        data.appendBE(UInt32(0)) // Color mode data
        data.appendBE(UInt32(0)) // Image resources

        var layerInfo = Data()
        layerInfo.appendBE(Int16(rasterized.count))
        let pixelCount = width * height
        let channelLength = UInt32(2 + pixelCount)

        // Photoshop stores layer records top-to-bottom; Easyshop stores bottom-to-top.
        for layer in rasterized.reversed() {
            layerInfo.appendBE(Int32(0))
            layerInfo.appendBE(Int32(0))
            layerInfo.appendBE(Int32(height))
            layerInfo.appendBE(Int32(width))
            layerInfo.appendBE(UInt16(4))
            for channelID: Int16 in [0, 1, 2, -1] {
                layerInfo.appendBE(channelID)
                layerInfo.appendBE(channelLength)
            }
            layerInfo.appendASCII("8BIM")
            layerInfo.appendASCII(layer.blendKey)
            layerInfo.append(layer.opacity)
            layerInfo.append(0) // clipping
            layerInfo.append(layer.visible ? 0 : 2) // invisible flag
            layerInfo.append(0)

            var extra = Data()
            extra.appendBE(UInt32(0)) // mask
            extra.appendBE(UInt32(0)) // blending ranges
            let nameBytes = Array(layer.name.utf8.prefix(255))
            extra.append(UInt8(nameBytes.count))
            extra.append(contentsOf: nameBytes)
            while extra.count % 4 != 0 { extra.append(0) }
            layerInfo.appendBE(UInt32(extra.count))
            layerInfo.append(extra)
        }

        for layer in rasterized.reversed() {
            guard let bytes = ImageData.rgbaBytes(from: layer.image, width: width, height: height) else {
                throw ProjectIOError.encodingFailed
            }
            for channel in [0, 1, 2, 3] {
                layerInfo.appendBE(UInt16(0)) // raw compression
                for pixel in 0..<pixelCount {
                    layerInfo.append(bytes[pixel * 4 + channel])
                }
            }
        }
        if layerInfo.count % 2 != 0 { layerInfo.append(0) }

        var layerAndMask = Data()
        layerAndMask.appendBE(UInt32(layerInfo.count))
        layerAndMask.append(layerInfo)
        layerAndMask.appendBE(UInt32(0)) // global layer mask
        data.appendBE(UInt32(layerAndMask.count))
        data.append(layerAndMask)

        guard let compositeBytes = ImageData.rgbaBytes(from: composite, width: width, height: height) else {
            throw ProjectIOError.encodingFailed
        }
        data.appendBE(UInt16(0))
        for channel in [0, 1, 2, 3] {
            for pixel in 0..<pixelCount {
                data.append(compositeBytes[pixel * 4 + channel])
            }
        }
        try data.write(to: url, options: .atomic)
    }

    private static func psdBlendKey(_ mode: BlendMode) -> String {
        switch mode {
        case .normal: "norm"
        case .multiply: "mul "
        case .screen: "scrn"
        case .overlay: "over"
        case .softLight: "sLit"
        case .darken: "dark"
        case .lighten: "lite"
        }
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
