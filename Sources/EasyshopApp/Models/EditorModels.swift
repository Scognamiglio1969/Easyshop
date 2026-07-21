import AppKit
import Combine
import Foundation

enum EditorTool: String, CaseIterable, Identifiable {
    case move = "Sposta"
    case rectangle = "Rettangolo"
    case ellipse = "Ellisse"
    case lasso = "Lazo"
    case smart = "Soggetto"
    case brushAdd = "Aggiungi alla selezione"
    case brushSubtract = "Sottrai dalla selezione"
    case text = "Testo"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .rectangle: "rectangle.dashed"
        case .ellipse: "circle.dashed"
        case .lasso: "lasso"
        case .smart: "sparkles"
        case .brushAdd: "paintbrush.pointed.fill"
        case .brushSubtract: "eraser.fill"
        case .text: "textformat"
        }
    }
}

enum LayerKind: String, Codable, CaseIterable {
    case raster
    case text
    case adjustment

    var label: String {
        switch self {
        case .raster: "Immagine"
        case .text: "Testo"
        case .adjustment: "Regolazione"
        }
    }

    var symbol: String {
        switch self {
        case .raster: "photo"
        case .text: "textformat"
        case .adjustment: "slider.horizontal.3"
        }
    }
}

enum BlendMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case multiply
    case screen
    case overlay
    case softLight
    case darken
    case lighten

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: "Normale"
        case .multiply: "Moltiplica"
        case .screen: "Scolora"
        case .overlay: "Sovrapponi"
        case .softLight: "Luce soffusa"
        case .darken: "Scurisci"
        case .lighten: "Schiarisci"
        }
    }
}

enum AdjustmentScope: String, Codable, CaseIterable, Identifiable {
    case entireImage
    case subject
    case background
    case face
    case sky

    var id: String { rawValue }

    var label: String {
        switch self {
        case .entireImage: "Tutta l’immagine"
        case .subject: "Soggetto"
        case .background: "Sfondo"
        case .face: "Volto"
        case .sky: "Cielo"
        }
    }
}

enum ResizeMethod: String, Codable, CaseIterable, Identifiable {
    case lanczos
    case bicubic
    case bilinear
    case nearest

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lanczos: "Lanczos — fotografia"
        case .bicubic: "Bicubico — generale"
        case .bilinear: "Bilineare — veloce"
        case .nearest: "Pixel perfetti — grafica"
        }
    }
}

enum CanvasAnchor: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    var horizontal: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .top, .center, .bottom: 0
        case .topRight, .right, .bottomRight: 1
        }
    }

    var vertical: Int {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .left, .center, .right: 0
        case .bottomLeft, .bottom, .bottomRight: 1
        }
    }
}

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)

    var nsColor: NSColor {
        NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .white
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
        alpha = rgb.alphaComponent
    }
}

struct LayerTransform: Codable, Hashable {
    var x: Double = 0
    var y: Double = 0
    var scaleX: Double = 1
    var scaleY: Double = 1
    var rotationDegrees: Double = 0
}

struct TextSettings: Codable, Hashable {
    var content: String = "Testo"
    var fontName: String = "Helvetica Neue"
    var fontSize: Double = 64
    var color: RGBAColor = .white
    var alignment: Int = 0
    var tracking: Double = 0
    var width: Double = 600
}

struct AdjustmentSettings: Codable, Hashable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var highlights: Double = 1
    var shadows: Double = 0
    var saturation: Double = 1
    var vibrance: Double = 0
    var hue: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var gamma: Double = 1
    var blackPoint: Double = 0
    var curveShadows: Double = 0
    var curveMidtones: Double = 0
    var curveHighlights: Double = 0
    var whitePoint: Double = 1
    var redBalance: Double = 1
    var greenBalance: Double = 1
    var blueBalance: Double = 1
    var clarity: Double = 0
    var sharpness: Double = 0
    var noiseReduction: Double = 0

    static let identity = AdjustmentSettings()

    static let autoEnhance = AdjustmentSettings(
        exposure: 0.12,
        brightness: 0.02,
        contrast: 1.08,
        highlights: 0.88,
        shadows: 0.22,
        saturation: 1.04,
        vibrance: 0.22,
        hue: 0,
        temperature: 120,
        tint: 0,
        gamma: 1,
        sharpness: 0.35,
        noiseReduction: 0.02
    )
}

@MainActor
final class EditorLayer: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var kind: LayerKind
    @Published var isVisible: Bool
    @Published var opacity: Double
    @Published var blendMode: BlendMode
    @Published var transform: LayerTransform
    @Published var text: TextSettings
    @Published var adjustment: AdjustmentSettings
    @Published var adjustmentScope: AdjustmentScope
    @Published var rasterData: Data?
    @Published var maskData: Data?
    @Published var isLocked: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kind: LayerKind,
        isVisible: Bool = true,
        opacity: Double = 1,
        blendMode: BlendMode = .normal,
        transform: LayerTransform = LayerTransform(),
        text: TextSettings = TextSettings(),
        adjustment: AdjustmentSettings = .identity,
        adjustmentScope: AdjustmentScope = .entireImage,
        rasterData: Data? = nil,
        maskData: Data? = nil,
        isLocked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.transform = transform
        self.text = text
        self.adjustment = adjustment
        self.adjustmentScope = adjustmentScope
        self.rasterData = rasterData
        self.maskData = maskData
        self.isLocked = isLocked
    }

    func record() -> LayerRecord {
        LayerRecord(
            id: id,
            name: name,
            kind: kind,
            isVisible: isVisible,
            opacity: opacity,
            blendMode: blendMode,
            transform: transform,
            text: text,
            adjustment: adjustment,
            adjustmentScope: adjustmentScope,
            rasterData: rasterData,
            maskData: maskData,
            isLocked: isLocked
        )
    }

    convenience init(record: LayerRecord) {
        self.init(
            id: record.id,
            name: record.name,
            kind: record.kind,
            isVisible: record.isVisible,
            opacity: record.opacity,
            blendMode: record.blendMode,
            transform: record.transform,
            text: record.text,
            adjustment: record.adjustment,
            adjustmentScope: record.adjustmentScope,
            rasterData: record.rasterData,
            maskData: record.maskData,
            isLocked: record.isLocked
        )
    }
}

struct LayerRecord: Codable {
    var id: UUID
    var name: String
    var kind: LayerKind
    var isVisible: Bool
    var opacity: Double
    var blendMode: BlendMode
    var transform: LayerTransform
    var text: TextSettings
    var adjustment: AdjustmentSettings
    var adjustmentScope: AdjustmentScope
    var rasterData: Data?
    var maskData: Data?
    var isLocked: Bool
}

struct ProjectRecord: Codable {
    static let currentVersion = 1

    var formatVersion: Int = currentVersion
    var name: String
    var width: Int
    var height: Int
    var dpi: Double?
    var createdAt: Date
    var modifiedAt: Date
    var sourceFormat: String?
    var layers: [LayerRecord]
}

@MainActor
final class EditorDocument: ObservableObject {
    @Published var name: String
    @Published var width: Int
    @Published var height: Int
    @Published var dpi: Double
    @Published var layers: [EditorLayer]
    @Published var selectedLayerID: UUID?
    @Published var sourceFormat: String?
    var createdAt: Date
    var fileURL: URL?

    init(
        name: String = "Senza titolo",
        width: Int = 1600,
        height: Int = 1000,
        dpi: Double = 72,
        layers: [EditorLayer] = [],
        sourceFormat: String? = nil,
        createdAt: Date = Date(),
        fileURL: URL? = nil
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.dpi = dpi
        self.layers = layers
        self.selectedLayerID = layers.last?.id
        self.sourceFormat = sourceFormat
        self.createdAt = createdAt
        self.fileURL = fileURL
    }

    var selectedLayer: EditorLayer? {
        guard let selectedLayerID else { return nil }
        return layers.first { $0.id == selectedLayerID }
    }

    func record() -> ProjectRecord {
        ProjectRecord(
            name: name,
            width: width,
            height: height,
            dpi: dpi,
            createdAt: createdAt,
            modifiedAt: Date(),
            sourceFormat: sourceFormat,
            layers: layers.map { $0.record() }
        )
    }

    static func from(record: ProjectRecord, url: URL? = nil) -> EditorDocument {
        EditorDocument(
            name: record.name,
            width: record.width,
            height: record.height,
            dpi: record.dpi ?? 72,
            layers: record.layers.map(EditorLayer.init(record:)),
            sourceFormat: record.sourceFormat,
            createdAt: record.createdAt,
            fileURL: url
        )
    }
}

enum SelectionKind: String {
    case rectangle
    case ellipse
    case lasso
    case ai
}

struct CanvasPoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct SelectionState {
    var kind: SelectionKind
    var points: [CanvasPoint]
    var maskData: Data?
    var sourceMaskData: Data?
    var outlineData: Data?
    var feather: Double
    var expansion: Double
    var isInverted: Bool

    init(
        kind: SelectionKind,
        points: [CanvasPoint],
        maskData: Data?,
        sourceMaskData: Data? = nil,
        outlineData: Data? = nil,
        feather: Double = 1.5,
        expansion: Double = 0,
        isInverted: Bool = false
    ) {
        self.kind = kind
        self.points = points
        self.maskData = maskData
        self.sourceMaskData = sourceMaskData ?? maskData
        self.outlineData = outlineData
        self.feather = feather
        self.expansion = expansion
        self.isInverted = isInverted
    }

    /// True when the gesture contains enough geometry to describe a usable
    /// vector selection. AI and painted selections are instead backed by masks.
    var hasUsableVectorPath: Bool {
        switch kind {
        case .rectangle, .ellipse:
            guard points.count >= 2 else { return false }
            return abs(points[0].x - points[1].x) >= 1 && abs(points[0].y - points[1].y) >= 1
        case .lasso:
            guard points.count >= 3 else { return false }
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            return (xs.max() ?? 0) - (xs.min() ?? 0) >= 1
                && (ys.max() ?? 0) - (ys.min() ?? 0) >= 1
        case .ai:
            return false
        }
    }

    var isUsable: Bool {
        maskData != nil || sourceMaskData != nil || hasUsableVectorPath
    }
}

struct CompatibilityNotice: Identifiable, Hashable {
    enum Severity: String {
        case info
        case warning
        case success
    }

    let id = UUID()
    var severity: Severity
    var title: String
    var detail: String
}

struct HistorySnapshot {
    var title: String
    var record: ProjectRecord
}
