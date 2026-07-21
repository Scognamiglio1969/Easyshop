import Foundation

enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): "Test fallito: \(message)" }
    }
}

@main
struct EasyshopSelfTest {
    @MainActor
    static func main() throws {
        var text = TextSettings()
        text.content = "Titolo"
        let document = EditorDocument(
            name: "Demo",
            width: 1200,
            height: 800,
            layers: [
                EditorLayer(name: "Foto", kind: .raster, rasterData: Data([1, 2, 3])),
                EditorLayer(name: "Titolo", kind: .text, text: text),
                EditorLayer(name: "Colore", kind: .adjustment, adjustment: .autoEnhance)
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(document.record())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectRecord.self, from: encoded)
        try expect(decoded.width == 1200 && decoded.layers.count == 3, "round-trip progetto")
        try expect(decoded.layers[1].text.content == "Titolo", "testo editabile")

        let selection = SelectionState(
            kind: .rectangle,
            points: [CanvasPoint(CGPoint(x: 10, y: 10)), CanvasPoint(CGPoint(x: 80, y: 60))],
            maskData: nil
        )
        let mask = SelectionEngine.maskData(for: selection, width: 100, height: 80, feather: 0)
        try expect(mask?.starts(with: [0x89, 0x50, 0x4e, 0x47]) == true, "maschera PNG")
        if let mask {
            let refined = SelectionEngine.refinedMaskData(mask, width: 100, height: 80, feather: 2, expansion: 3, inverted: false)
            try expect(refined != nil, "rifinitura maschera")
            let outline = refined.flatMap { SelectionEngine.outlineData(from: $0, width: 100, height: 80) }
            try expect(outline != nil, "contorno selezione")

            let safeDocument = EditorDocument(
                name: "Autosave",
                width: 100,
                height: 80,
                layers: [EditorLayer(name: "Raster", kind: .raster, rasterData: mask)]
            )
            let safeProject = try ProjectIO.encodedProjectData(for: safeDocument)
            let reopened = try ProjectIO.decodeProjectData(safeProject)
            try expect(reopened.layers.first?.rasterData == mask, "autosave con base64 valido")
        }

        let stroke = [
            CanvasPoint(CGPoint(x: 25, y: 40)),
            CanvasPoint(CGPoint(x: 75, y: 40))
        ]
        guard let painted = SelectionEngine.paintMask(
            baseData: nil,
            points: stroke,
            radius: 12,
            add: true,
            width: 100,
            height: 80
        ), let paintedImage = ImageData.cgImage(from: painted),
           let paintedBytes = ImageData.rgbaBytes(from: paintedImage, width: 100, height: 80) else {
            throw SelfTestFailure.failed("pennello selezione additivo")
        }
        let paintedCount = stride(from: 0, to: paintedBytes.count, by: 4).reduce(0) {
            $0 + (paintedBytes[$1] > 24 ? 1 : 0)
        }
        try expect(paintedCount > 500, "pennello aggiunge area")
        let paintedSnapshot = painted
        guard let erased = SelectionEngine.paintMask(
            baseData: painted,
            points: [CanvasPoint(CGPoint(x: 50, y: 40))],
            radius: 15,
            add: false,
            width: 100,
            height: 80
        ), let erasedImage = ImageData.cgImage(from: erased),
           let erasedBytes = ImageData.rgbaBytes(from: erasedImage, width: 100, height: 80) else {
            throw SelfTestFailure.failed("pennello selezione sottrattivo")
        }
        let erasedCount = stride(from: 0, to: erasedBytes.count, by: 4).reduce(0) {
            $0 + (erasedBytes[$1] > 24 ? 1 : 0)
        }
        try expect(erasedCount < paintedCount, "pennello sottrae area")
        try expect(painted == paintedSnapshot, "maschera sorgente immutabile")

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let demoURL = root.appendingPathComponent("Sources/EasyshopApp/Resources/DemoPortrait.png")
        let demoData = try Data(contentsOf: demoURL)
        guard let demoImage = ImageData.cgImage(from: demoData),
              let fallback = AIEngine.classicalForegroundMask(image: demoImage, pointX: nil, pointY: nil),
              let fallbackImage = ImageData.cgImage(from: fallback),
              let fallbackBytes = ImageData.rgbaBytes(from: fallbackImage, width: 256, height: 256) else {
            throw SelfTestFailure.failed("fallback selezione leggibile")
        }
        let selectedPixels = stride(from: 0, to: fallbackBytes.count, by: 4).reduce(0) {
            $0 + (fallbackBytes[$1] > 24 ? 1 : 0)
        }
        let fallbackCoverage = Double(selectedPixels) / Double(256 * 256)
        try expect(fallbackCoverage > 0.01 && fallbackCoverage < 0.95, "fallback selezione non vuoto/non pieno")
        let fallbackResult = SubjectMaskResult(maskData: fallback, provenance: .classicalForeground)
        try expect(!fallbackResult.provenance.isVisionML && fallbackResult.selectionKind != .ai, "fallback classico non etichettato AI")
        try expect(AdjustmentSettings.identity.contrast == 1, "regolazioni neutrali")
        let fitted = ResizeEngine.fitSize(width: 6000, height: 4000, maxWidth: 2048, maxHeight: 2048)
        try expect(fitted.0 == 2048 && fitted.1 == 1365, "adattamento proporzionale")

        guard let resizeSource = mask else {
            throw SelfTestFailure.failed("sorgente resize")
        }
        let editableDocument = EditorDocument(
            name: "Resize",
            width: 100,
            height: 80,
            layers: [EditorLayer(name: "Foto", kind: .raster, rasterData: resizeSource)]
        )
        try ResizeEngine.resizeImage(
            document: editableDocument,
            width: 50,
            height: 40,
            dpi: 144,
            method: .lanczos
        )
        try expect(editableDocument.width == 50 && editableDocument.height == 40, "resize transazionale valido")

        let lockedData = resizeSource
        let lockedDocument = EditorDocument(
            name: "Locked",
            width: 100,
            height: 80,
            layers: [EditorLayer(name: "Protetto", kind: .raster, rasterData: lockedData, isLocked: true)]
        )
        do {
            try ResizeEngine.resizeImage(
                document: lockedDocument,
                width: 50,
                height: 40,
                dpi: 72,
                method: .bilinear
            )
            throw SelfTestFailure.failed("resize livello protetto non rifiutato")
        } catch is ResizeEngineError {
            // Expected: rejection happens before mutation.
        }
        try expect(lockedDocument.width == 100 && lockedDocument.height == 80, "resize protetto conserva tela")
        try expect(lockedDocument.layers.first?.rasterData == lockedData, "resize protetto conserva pixel")

        do {
            try ResizeEngine.validateTarget(width: 100_000, height: 100_000)
            throw SelfTestFailure.failed("limite tela non applicato")
        } catch is ProjectIOError {
            // Expected safety rejection.
        }

        print("Easyshop self-test: 18 controlli superati")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SelfTestFailure.failed(message) }
    }
}
