import AppKit
import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProjectIOError: LocalizedError {
    case unsupportedFile
    case unreadableImage
    case encodingFailed
    case invalidProject
    case invalidProjectDetail(String)
    case projectTooLarge(actualBytes: Int64, maximumBytes: Int64)
    case sourceFileTooLarge(actualBytes: Int64, maximumBytes: Int64)
    case canvasTooLarge(width: Int, height: Int)
    case tooManyLayers(actual: Int, maximum: Int)
    case importedFramesTooLarge(actualBytes: Int64, maximumBytes: Int64)
    case embeddedDataTooLarge(layer: String, kind: String, actualBytes: Int64, maximumBytes: Int64)
    case embeddedDataTotalTooLarge(actualBytes: Int64, maximumBytes: Int64)
    case unavailableEncoder(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Formato non supportato da questa build."
        case .unreadableImage: "Non è stato possibile leggere l’immagine."
        case .encodingFailed: "Non è stato possibile creare il file."
        case .invalidProject: "Il progetto Easyshop non è valido."
        case .invalidProjectDetail(let detail): "Il progetto Easyshop non è valido: \(detail)"
        case .projectTooLarge(let actual, let maximum):
            "Il progetto occupa \(Self.formattedBytes(actual)), oltre il limite di sicurezza di \(Self.formattedBytes(maximum))."
        case .sourceFileTooLarge(let actual, let maximum):
            "Il file sorgente occupa \(Self.formattedBytes(actual)), oltre il limite di importazione di \(Self.formattedBytes(maximum))."
        case .canvasTooLarge(let width, let height):
            "La tela \(width) × \(height) px supera i limiti di sicurezza di Easyshop."
        case .tooManyLayers(let actual, let maximum):
            "Il progetto contiene \(actual) livelli. Il limite di sicurezza è \(maximum)."
        case .importedFramesTooLarge(let actual, let maximum):
            "Le pagine dell’immagine richiederebbero circa \(Self.formattedBytes(actual)) in memoria; il limite di sicurezza è \(Self.formattedBytes(maximum))."
        case .embeddedDataTooLarge(let layer, let kind, let actual, let maximum):
            "Nel livello “\(layer)” i dati \(kind) occupano \(Self.formattedBytes(actual)); il limite è \(Self.formattedBytes(maximum))."
        case .embeddedDataTotalTooLarge(let actual, let maximum):
            "I dati immagine incorporati occupano \(Self.formattedBytes(actual)); il limite di sicurezza è \(Self.formattedBytes(maximum))."
        case .unavailableEncoder(let format): "Questa versione di macOS non dispone di un encoder \(format). Scegli un altro formato."
        }
    }

    private static func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// Hard limits keep malformed or unexpectedly large project files from exhausting
/// memory during JSON/base64 decoding. They are intentionally generous for a fast
/// desktop photography workflow, while still placing a finite ceiling on input.
enum ProjectSafetyLimits {
    static let maximumProjectBytes: Int64 = 768 * 1_024 * 1_024
    static let maximumCanvasDimension = 32_768
    static let maximumCanvasPixels: Int64 = 268_435_456 // 256 megapixels
    static let maximumLayerCount = 256
    static let maximumRasterBytes: Int64 = 256 * 1_024 * 1_024
    static let maximumMaskBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumEmbeddedBytes: Int64 = 512 * 1_024 * 1_024
    static let maximumLayerNameLength = 512
    static let maximumDocumentNameLength = 512
    static let maximumTextLength = 1_000_000
    static let maximumSourceImageBytes: Int64 = 1_024 * 1_024 * 1_024
    static let maximumDecodedImportBytes: Int64 = 1_536 * 1_024 * 1_024
}

@MainActor
enum ProjectIO {
    static let projectExtension = "easyshop"

    static func saveProject(_ document: EditorDocument, to url: URL) throws {
        let data = try encodedProjectData(for: document)
        try data.write(to: url, options: .atomic)
        document.fileURL = url
        document.name = url.deletingPathExtension().lastPathComponent
    }

    static func openProject(from url: URL) throws -> EditorDocument {
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(fileSize) > ProjectSafetyLimits.maximumProjectBytes {
            throw ProjectIOError.projectTooLarge(
                actualBytes: Int64(fileSize),
                maximumBytes: ProjectSafetyLimits.maximumProjectBytes
            )
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decodeProjectData(data, sourceURL: url)
    }

    /// Encodes a validated native project without changing the document's file URL.
    /// Recovery autosaves use this path so they never impersonate a user save.
    static func encodedProjectData(for document: EditorDocument) throws -> Data {
        let record = document.record()
        try validate(record: record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw ProjectIOError.invalidProjectDetail("non è stato possibile codificare i dati del documento.")
        }
        try validateEncodedProjectSize(data)
        try preflightEmbeddedPayloads(in: data)
        return data
    }

    /// Decodes and validates untrusted project data. The byte-level preflight runs
    /// before JSONDecoder can allocate the embedded base64 image payloads.
    static func decodeProjectData(_ data: Data, sourceURL: URL? = nil) throws -> EditorDocument {
        try validateEncodedProjectSize(data)
        try preflightEmbeddedPayloads(in: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: ProjectRecord
        do {
            record = try decoder.decode(ProjectRecord.self, from: data)
        } catch {
            throw ProjectIOError.invalidProjectDetail("struttura JSON o dati incorporati danneggiati.")
        }
        guard (1...ProjectRecord.currentVersion).contains(record.formatVersion) else {
            throw ProjectIOError.invalidProjectDetail("versione del formato non supportata (\(record.formatVersion)).")
        }
        try validate(record: record)
        return EditorDocument.from(record: record, url: sourceURL)
    }

    private static func validateEncodedProjectSize(_ data: Data) throws {
        let actual = Int64(data.count)
        guard actual <= ProjectSafetyLimits.maximumProjectBytes else {
            throw ProjectIOError.projectTooLarge(
                actualBytes: actual,
                maximumBytes: ProjectSafetyLimits.maximumProjectBytes
            )
        }
    }

    private static func validate(record: ProjectRecord) throws {
        guard !record.name.isEmpty, record.name.count <= ProjectSafetyLimits.maximumDocumentNameLength else {
            throw ProjectIOError.invalidProjectDetail("il nome del documento è vuoto o troppo lungo.")
        }
        guard record.width > 0,
              record.height > 0,
              record.width <= ProjectSafetyLimits.maximumCanvasDimension,
              record.height <= ProjectSafetyLimits.maximumCanvasDimension else {
            throw ProjectIOError.canvasTooLarge(width: record.width, height: record.height)
        }
        let (pixelCount, overflow) = Int64(record.width).multipliedReportingOverflow(by: Int64(record.height))
        guard !overflow, pixelCount <= ProjectSafetyLimits.maximumCanvasPixels else {
            throw ProjectIOError.canvasTooLarge(width: record.width, height: record.height)
        }
        if let dpi = record.dpi, (!dpi.isFinite || dpi < 1 || dpi > 2_400) {
            throw ProjectIOError.invalidProjectDetail("la risoluzione DPI non è valida.")
        }
        guard record.layers.count <= ProjectSafetyLimits.maximumLayerCount else {
            throw ProjectIOError.tooManyLayers(
                actual: record.layers.count,
                maximum: ProjectSafetyLimits.maximumLayerCount
            )
        }

        var embeddedTotal: Int64 = 0
        for (index, layer) in record.layers.enumerated() {
            let displayName = layer.name.isEmpty ? "Livello \(index + 1)" : layer.name
            guard layer.name.count <= ProjectSafetyLimits.maximumLayerNameLength else {
                throw ProjectIOError.invalidProjectDetail("il nome del livello \(index + 1) è troppo lungo.")
            }
            guard layer.text.content.count <= ProjectSafetyLimits.maximumTextLength else {
                throw ProjectIOError.invalidProjectDetail("il testo nel livello “\(displayName)” è troppo lungo.")
            }
            guard layer.opacity.isFinite, (0...1).contains(layer.opacity) else {
                throw ProjectIOError.invalidProjectDetail("l’opacità del livello “\(displayName)” non è valida.")
            }

            try validateEmbeddedImage(
                layer.rasterData,
                layerName: displayName,
                kind: "raster",
                maximumBytes: ProjectSafetyLimits.maximumRasterBytes,
                total: &embeddedTotal
            )
            try validateEmbeddedImage(
                layer.maskData,
                layerName: displayName,
                kind: "maschera",
                maximumBytes: ProjectSafetyLimits.maximumMaskBytes,
                total: &embeddedTotal
            )
        }
        guard embeddedTotal <= ProjectSafetyLimits.maximumEmbeddedBytes else {
            throw ProjectIOError.embeddedDataTotalTooLarge(
                actualBytes: embeddedTotal,
                maximumBytes: ProjectSafetyLimits.maximumEmbeddedBytes
            )
        }
    }

    private static func validateEmbeddedImage(
        _ data: Data?,
        layerName: String,
        kind: String,
        maximumBytes: Int64,
        total: inout Int64
    ) throws {
        guard let data else { return }
        let byteCount = Int64(data.count)
        guard byteCount <= maximumBytes else {
            throw ProjectIOError.embeddedDataTooLarge(
                layer: layerName,
                kind: kind,
                actualBytes: byteCount,
                maximumBytes: maximumBytes
            )
        }
        let (newTotal, overflow) = total.addingReportingOverflow(byteCount)
        guard !overflow else {
            throw ProjectIOError.embeddedDataTotalTooLarge(
                actualBytes: .max,
                maximumBytes: ProjectSafetyLimits.maximumEmbeddedBytes
            )
        }
        total = newTotal

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            throw ProjectIOError.invalidProjectDetail("i dati \(kind) nel livello “\(layerName)” non sono un’immagine valida.")
        }
        let (pixels, pixelOverflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard width <= ProjectSafetyLimits.maximumCanvasDimension,
              height <= ProjectSafetyLimits.maximumCanvasDimension,
              !pixelOverflow,
              pixels <= ProjectSafetyLimits.maximumCanvasPixels else {
            throw ProjectIOError.invalidProjectDetail("l’immagine \(kind) nel livello “\(layerName)” ha dimensioni non sicure.")
        }
    }

    /// Counts the raw base64 payloads before JSON decoding. JSONDecoder's `Data`
    /// strategy allocates decoded buffers; this preflight stops oversized payloads
    /// before those allocations happen.
    private static func preflightEmbeddedPayloads(in data: Data) throws {
        let keys: [([UInt8], String, Int64)] = [
            (Array("\"rasterData\"".utf8), "raster", ProjectSafetyLimits.maximumRasterBytes),
            (Array("\"maskData\"".utf8), "maschera", ProjectSafetyLimits.maximumMaskBytes)
        ]
        var totalEncoded: Int64 = 0

        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty else { throw ProjectIOError.invalidProject }
            // Coding keys emitted by Easyshop are fixed ASCII. Refuse escaped object
            // keys so a hostile file cannot spell `rasterData` with Unicode escapes
            // and bypass the payload-length checks below.
            try rejectEscapedObjectKeys(in: bytes)
            var index = 0
            while index < bytes.count {
                var matched: ([UInt8], String, Int64)?
                for key in keys where index + key.0.count <= bytes.count {
                    var isMatch = true
                    for offset in key.0.indices where bytes[index + offset] != key.0[offset] {
                        isMatch = false
                        break
                    }
                    if isMatch {
                        matched = key
                        break
                    }
                }
                guard let (key, kind, maximumDecoded) = matched else {
                    index += 1
                    continue
                }

                var cursor = index + key.count
                while cursor < bytes.count, isJSONWhitespace(bytes[cursor]) { cursor += 1 }
                guard cursor < bytes.count, bytes[cursor] == 0x3A else {
                    index += key.count
                    continue
                }
                cursor += 1
                while cursor < bytes.count, isJSONWhitespace(bytes[cursor]) { cursor += 1 }
                if cursor + 4 <= bytes.count,
                   bytes[cursor] == 0x6E, bytes[cursor + 1] == 0x75,
                   bytes[cursor + 2] == 0x6C, bytes[cursor + 3] == 0x6C {
                    index = cursor + 4
                    continue
                }
                guard cursor < bytes.count, bytes[cursor] == 0x22 else {
                    throw ProjectIOError.invalidProjectDetail("il campo \(kind) incorporato non è valido.")
                }
                cursor += 1
                var payloadLength: Int64 = 0
                while cursor < bytes.count, bytes[cursor] != 0x22 {
                    if bytes[cursor] == 0x5C {
                        // Foundation may escape the slash in a base64 payload as
                        // `\/`. It still represents exactly one base64 character.
                        guard cursor + 1 < bytes.count, bytes[cursor + 1] == 0x2F else {
                            throw ProjectIOError.invalidProjectDetail("il campo \(kind) incorporato contiene una codifica non valida.")
                        }
                        payloadLength += 1
                        cursor += 2
                        continue
                    }
                    guard isBase64Byte(bytes[cursor]) else {
                        throw ProjectIOError.invalidProjectDetail("il campo \(kind) incorporato contiene caratteri non validi.")
                    }
                    payloadLength += 1
                    cursor += 1
                }
                guard cursor < bytes.count else {
                    throw ProjectIOError.invalidProjectDetail("il campo \(kind) incorporato è incompleto.")
                }
                let encodedCount = payloadLength
                let maximumEncoded = base64EncodedLimit(forDecodedBytes: maximumDecoded)
                guard encodedCount <= maximumEncoded else {
                    throw ProjectIOError.embeddedDataTooLarge(
                        layer: "sconosciuto",
                        kind: kind,
                        actualBytes: approximateDecodedBytes(forBase64Bytes: encodedCount),
                        maximumBytes: maximumDecoded
                    )
                }
                let (newTotal, overflow) = totalEncoded.addingReportingOverflow(encodedCount)
                guard !overflow else {
                    throw ProjectIOError.embeddedDataTotalTooLarge(
                        actualBytes: .max,
                        maximumBytes: ProjectSafetyLimits.maximumEmbeddedBytes
                    )
                }
                totalEncoded = newTotal
                index = cursor + 1
            }
        }

        let maximumTotalEncoded = base64EncodedLimit(forDecodedBytes: ProjectSafetyLimits.maximumEmbeddedBytes)
        guard totalEncoded <= maximumTotalEncoded else {
            throw ProjectIOError.embeddedDataTotalTooLarge(
                actualBytes: approximateDecodedBytes(forBase64Bytes: totalEncoded),
                maximumBytes: ProjectSafetyLimits.maximumEmbeddedBytes
            )
        }
    }

    private static func rejectEscapedObjectKeys(in bytes: UnsafeBufferPointer<UInt8>) throws {
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x22 else {
                index += 1
                continue
            }
            var cursor = index + 1
            var containsEscape = false
            while cursor < bytes.count {
                if bytes[cursor] == 0x5C {
                    containsEscape = true
                    cursor += 2
                    continue
                }
                if bytes[cursor] == 0x22 { break }
                cursor += 1
            }
            guard cursor < bytes.count else {
                throw ProjectIOError.invalidProjectDetail("una stringa JSON è incompleta.")
            }
            var following = cursor + 1
            while following < bytes.count, isJSONWhitespace(bytes[following]) { following += 1 }
            if containsEscape, following < bytes.count, bytes[following] == 0x3A {
                throw ProjectIOError.invalidProjectDetail("una chiave JSON usa una codifica non consentita.")
            }
            index = cursor + 1
        }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) ||
        (0x61...0x7A).contains(byte) ||
        (0x30...0x39).contains(byte) ||
        byte == 0x2B || byte == 0x2F || byte == 0x3D
    }

    private static func base64EncodedLimit(forDecodedBytes value: Int64) -> Int64 {
        ((value + 2) / 3) * 4
    }

    private static func approximateDecodedBytes(forBase64Bytes value: Int64) -> Int64 {
        (value / 4) * 3
    }

    static func importImage(from url: URL) throws -> (EditorDocument, [CompatibilityNotice]) {
        let ext = url.pathExtension.lowercased()
        if ext == projectExtension {
            return (try openProject(from: url), [])
        }
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(fileSize) > ProjectSafetyLimits.maximumSourceImageBytes {
            throw ProjectIOError.sourceFileTooLarge(
                actualBytes: Int64(fileSize),
                maximumBytes: ProjectSafetyLimits.maximumSourceImageBytes
            )
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ProjectIOError.unsupportedFile
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ProjectIOError.unreadableImage }
        guard count <= ProjectSafetyLimits.maximumLayerCount else {
            throw ProjectIOError.tooManyLayers(actual: count, maximum: ProjectSafetyLimits.maximumLayerCount)
        }

        // Read metadata with caching disabled before allocating decoded pixel
        // buffers. This catches decompression bombs in PSD/TIFF/JPEG/PNG sources.
        var preflightSizes: [(width: Int, height: Int)] = []
        preflightSizes.reserveCapacity(count)
        var decodedByteEstimate: Int64 = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                index,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) as? [CFString: Any],
            let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            rawWidth > 0,
            rawHeight > 0 else {
                throw ProjectIOError.unreadableImage
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let swapsAxes = [5, 6, 7, 8].contains(orientation)
            let width = swapsAxes ? rawHeight : rawWidth
            let height = swapsAxes ? rawWidth : rawHeight
            let (pixels, pixelOverflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
            guard width <= ProjectSafetyLimits.maximumCanvasDimension,
                  height <= ProjectSafetyLimits.maximumCanvasDimension,
                  !pixelOverflow,
                  pixels <= ProjectSafetyLimits.maximumCanvasPixels else {
                throw ProjectIOError.canvasTooLarge(width: width, height: height)
            }
            let (frameBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            let (newEstimate, totalOverflow) = decodedByteEstimate.addingReportingOverflow(frameBytes)
            guard !byteOverflow,
                  !totalOverflow,
                  newEstimate <= ProjectSafetyLimits.maximumDecodedImportBytes else {
                throw ProjectIOError.importedFramesTooLarge(
                    actualBytes: byteOverflow || totalOverflow ? .max : newEstimate,
                    maximumBytes: ProjectSafetyLimits.maximumDecodedImportBytes
                )
            }
            decodedByteEstimate = newEstimate
            preflightSizes.append((width, height))
        }

        var layers: [EditorLayer] = []
        layers.reserveCapacity(count)
        var first: CGImage?
        var embeddedBytes: Int64 = 0
        for index in 0..<count {
            guard let frame = decodedImage(from: source, index: index),
                  frame.width == preflightSizes[index].width,
                  frame.height == preflightSizes[index].height,
                  let png = ImageData.pngData(from: frame) else {
                throw ProjectIOError.unreadableImage
            }
            if index == 0 { first = frame }
            guard Int64(png.count) <= ProjectSafetyLimits.maximumRasterBytes else {
                throw ProjectIOError.embeddedDataTooLarge(
                    layer: "Immagine \(index + 1)",
                    kind: "raster",
                    actualBytes: Int64(png.count),
                    maximumBytes: ProjectSafetyLimits.maximumRasterBytes
                )
            }
            let (nextEmbedded, embeddedOverflow) = embeddedBytes.addingReportingOverflow(Int64(png.count))
            guard !embeddedOverflow, nextEmbedded <= ProjectSafetyLimits.maximumEmbeddedBytes else {
                throw ProjectIOError.embeddedDataTotalTooLarge(
                    actualBytes: embeddedOverflow ? .max : nextEmbedded,
                    maximumBytes: ProjectSafetyLimits.maximumEmbeddedBytes
                )
            }
            embeddedBytes = nextEmbedded
            let suffix = count > 1 ? " \(index + 1)" : ""
            layers.append(EditorLayer(name: "Immagine\(suffix)", kind: .raster, rasterData: png))
        }
        guard let first, !layers.isEmpty else { throw ProjectIOError.unreadableImage }

        let document = EditorDocument(
            name: url.deletingPathExtension().lastPathComponent,
            width: first.width,
            height: first.height,
            layers: layers,
            sourceFormat: ext.uppercased()
        )
        var notices: [CompatibilityNotice] = []
        if ext == "psd" || ext == "psb" {
            notices.append(CompatibilityNotice(
                severity: .warning,
                title: "PSD aperto in modalità compatibile",
                detail: "L’immagine composta è preservata. Livelli ed effetti Adobe non interpretabili rimangono disponibili nel file originale; salva come .easyshop per continuare senza perdite."
            ))
        } else if ext == "tif" || ext == "tiff" {
            notices.append(CompatibilityNotice(
                severity: .info,
                title: "TIFF importato",
                detail: count > 1 ? "Le \(count) pagine sono state importate come livelli separati." : "L’immagine è stata importata nel documento di lavoro a 8 bit per canale. Conserva l’originale per un eventuale workflow ad alta profondità."
            ))
        }
        return (document, notices)
    }

    private static func decodedImage(from source: CGImageSource, index: Int) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let rawOrientation = properties[kCGImagePropertyOrientation] as? UInt32,
              rawOrientation != 1,
              let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) else {
            return image
        }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        return CIContext().createCGImage(oriented, from: oriented.extent)
    }

    static func export(_ document: EditorDocument, to url: URL, quality: Double = 0.92) throws {
        guard let image = RenderEngine.composite(document: document) else { throw ProjectIOError.encodingFailed }
        let ext = url.pathExtension.lowercased()
        if ext == "psd" {
            try PSDWriter.write(document: document, composite: image, to: url)
            return
        }
        let type: UTType
        switch ext {
        case "jpg", "jpeg": type = .jpeg
        case "png": type = .png
        case "tif", "tiff": type = .tiff
        case "heic": type = .heic
        case "avif":
            guard let avif = UTType("public.avif") else { throw ProjectIOError.unavailableEncoder("AVIF") }
            type = avif
        case "bmp": type = .bmp
        case "gif": type = .gif
        case "pdf": type = .pdf
        case "exr":
            guard let exr = UTType("com.ilm.openexr-image") else { throw ProjectIOError.unavailableEncoder("EXR") }
            type = exr
        default:
            if let inferred = UTType(filenameExtension: ext) {
                type = inferred
            } else {
                throw ProjectIOError.unsupportedFile
            }
        }
        let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        guard writableTypes.contains(type.identifier) else {
            throw ProjectIOError.unavailableEncoder(type.localizedDescription ?? ext.uppercased())
        }
        let dpi = min(2400, max(1, document.dpi))
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        guard let data = ImageData.encode(image, type: type, quality: quality, properties: properties) else {
            throw ProjectIOError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }
}
