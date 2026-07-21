import AppKit
import Foundation
import ImageIO

// SwiftPM synthesizes this accessor for the application target. The standalone
// functional harness compiles the same workspace source without a resource bundle.
extension Bundle {
    static var module: Bundle { .main }
}

enum FunctionalFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): "Test funzionale fallito: \(message)" }
    }
}

@main
struct EasyshopFunctionalTest {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let demoURL = root.appendingPathComponent("Sources/EasyshopApp/Resources/DemoPortrait.png")
        let demoData = try Data(contentsOf: demoURL)
        let (imported, _) = try ProjectIO.importImage(from: demoURL)
        try expect(imported.layers.count == 1 && imported.width > 1000, "apertura PNG")
        try expect(RenderEngine.composite(document: imported) != nil, "render immagine importata")

        let workspace = EditorWorkspace()
        workspace.document = imported
        workspace.showWelcome = false
        workspace.beforeImageData = demoData

        let originalCount = workspace.document.layers.count
        workspace.addTextLayer(content: "Titolo prova")
        try expect(workspace.document.layers.count == originalCount + 1, "creazione livello testo")
        try expect(workspace.document.selectedLayer?.kind == .text, "selezione livello testo")
        workspace.undo()
        try expect(workspace.document.layers.count == originalCount, "undo creazione testo")
        workspace.redo()
        try expect(workspace.document.layers.count == originalCount + 1, "redo creazione testo")
        try expect(RenderEngine.composite(document: workspace.document) != nil, "render con testo")

        workspace.document.selectedLayerID = workspace.document.layers.first?.id
        workspace.selection = SelectionState(
            kind: .rectangle,
            points: [CanvasPoint(CGPoint(x: 80, y: 80)), CanvasPoint(CGPoint(x: 520, y: 620))],
            maskData: nil
        )
        workspace.applyCurrentSelectionAsMask()
        try expect(workspace.document.selectedLayer?.maskData != nil, "applicazione maschera manuale")
        try expect(RenderEngine.composite(document: workspace.document) != nil, "render con maschera")

        workspace.refineSelection(feather: 3, expansion: 2)
        let refined = await waitUntil { workspace.selection?.outlineData != nil }
        try expect(refined, "rifinitura bordo")
        workspace.paintSelection(
            points: [CanvasPoint(CGPoint(x: 120, y: 120)), CanvasPoint(CGPoint(x: 220, y: 220))],
            add: true,
            radius: 22
        )
        try expect(workspace.selection?.maskData != nil, "pennello aggiungi selezione")

        guard let beforeAdjustment = workspace.compositePNG() else {
            throw FunctionalFailure.failed("render iniziale")
        }
        var adjustment = AdjustmentSettings.identity
        adjustment.exposure = 0.7
        workspace.addAdjustmentLayer(name: "Esposizione", settings: adjustment)
        guard let afterAdjustment = workspace.compositePNG() else {
            throw FunctionalFailure.failed("render regolazione")
        }
        try expect(beforeAdjustment != afterAdjustment, "regolazione luce visibile")

        let halfWidth = max(1, workspace.document.width / 2)
        let halfHeight = max(1, workspace.document.height / 2)
        workspace.resizeImage(width: halfWidth, height: halfHeight, dpi: 144, method: .lanczos)
        try expect(workspace.document.width == halfWidth && workspace.document.height == halfHeight, "resize immagine")
        try expect(workspace.document.dpi == 144, "resize DPI")

        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Easyshop-functional-\(UUID().uuidString).easyshop")
        try ProjectIO.saveProject(workspace.document, to: projectURL)
        let reopened = try ProjectIO.openProject(from: projectURL)
        try expect(reopened.layers.count == workspace.document.layers.count, "salva e riapri progetto")

        for ext in ["png", "jpg", "tiff", "psd"] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Easyshop-functional-\(UUID().uuidString).\(ext)")
            try ProjectIO.export(workspace.document, to: url)
            let bytes = try Data(contentsOf: url)
            if ext == "psd" {
                try expect(bytes.starts(with: Array("8BPS".utf8)), "export PSD")
            } else {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    throw FunctionalFailure.failed("export \(ext)")
                }
                try expect(CGImageSourceGetCount(source) > 0, "export \(ext)")
            }
            try? FileManager.default.removeItem(at: url)
        }

        let aiResult = try await AIEngine.subjectMask(
            from: demoData,
            selectedPoint: CanvasPoint(CGPoint(x: Double(imported.width) * 0.42, y: Double(imported.height) * 0.50))
        )
        try expect(aiResult.provenance.isVisionML, "provenienza selezione realmente Vision ML")
        try expect(ImageData.cgImage(from: aiResult.maskData) != nil, "selezione soggetto Vision ML")

        let request = PreviewRenderRequest(
            document: workspace.document,
            revision: 1,
            viewportSize: CGSize(width: 1200, height: 800),
            backingScaleFactor: 1
        )
        guard let preview = await PreviewRenderService.shared.render(request) else {
            throw FunctionalFailure.failed("render proxy")
        }
        try expect(preview.image.width <= 1200 && preview.image.height <= 800, "preview limitata al viewport")

        try? FileManager.default.removeItem(at: projectURL)
        print("Easyshop functional test: 20 flussi verificati")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FunctionalFailure.failed(message) }
    }

    @MainActor
    static func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return condition()
    }
}
