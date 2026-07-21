import AppKit
import Foundation
import ImageIO

@MainActor
enum RuntimeSmokeTest {
    private struct Check: Codable {
        let name: String
        let passed: Bool
        let detail: String
        let milliseconds: Int
    }

    private struct Report: Codable {
        let product: String
        let generatedAt: Date
        let passed: Bool
        let checks: [Check]
    }

    private enum Failure: Error, LocalizedError {
        case condition(String)
        var errorDescription: String? {
            switch self { case .condition(let detail): detail }
        }
    }

    static let reportURL = URL(fileURLWithPath: "/private/tmp/Easyshop-smoke-report.json")

    static func run(workspace: EditorWorkspace) async {
        var checks: [Check] = []
        var demoData: Data?

        await record("Apertura PNG", into: &checks) {
            guard let url = Bundle.main.url(forResource: "DemoPortrait", withExtension: "png")
                    ?? Bundle.module.url(forResource: "DemoPortrait", withExtension: "png") else {
                throw Failure.condition("Risorsa demo non trovata")
            }
            let data = try Data(contentsOf: url)
            let (document, _) = try ProjectIO.importImage(from: url)
            guard document.width > 1000, document.layers.count == 1 else {
                throw Failure.condition("Documento importato incompleto")
            }
            workspace.document = document
            workspace.showWelcome = false
            workspace.beforeImageData = data
            demoData = data
        }

        await record("Render composito", into: &checks) {
            guard let image = RenderEngine.composite(document: workspace.document),
                  image.width == workspace.document.width,
                  image.height == workspace.document.height else {
                throw Failure.condition("Core Image non ha prodotto il composito")
            }
        }

        await record("Livello testo + undo/redo", into: &checks) {
            let count = workspace.document.layers.count
            workspace.addTextLayer(content: "Titolo", at: CanvasPoint(CGPoint(x: 180, y: 160)))
            guard workspace.document.layers.count == count + 1,
                  workspace.document.selectedLayer?.kind == .text else {
                throw Failure.condition("Livello testo non creato")
            }
            workspace.undo()
            guard workspace.document.layers.count == count else {
                throw Failure.condition("Undo non ha rimosso il testo")
            }
            workspace.redo()
            guard workspace.document.layers.count == count + 1 else {
                throw Failure.condition("Redo non ha ripristinato il testo")
            }
        }

        await record("Selezione, bordo e maschera", into: &checks) {
            guard let raster = workspace.document.layers.first(where: { $0.kind == .raster }) else {
                throw Failure.condition("Livello raster assente")
            }
            workspace.document.selectedLayerID = raster.id
            workspace.selection = SelectionState(
                kind: .ellipse,
                points: [CanvasPoint(CGPoint(x: 120, y: 90)), CanvasPoint(CGPoint(x: 720, y: 820))],
                maskData: nil
            )
            workspace.finalizeManualSelection()
            guard await waitUntil({ workspace.selection?.outlineData != nil }) else {
                throw Failure.condition("La selezione non ha prodotto un bordo")
            }
            workspace.applyCurrentSelectionAsMask()
            guard raster.maskData != nil else {
                throw Failure.condition("Maschera non applicata al livello")
            }
        }

        await record("Pennello aggiungi/sottrai", into: &checks) {
            workspace.paintSelection(
                points: [CanvasPoint(CGPoint(x: 160, y: 160)), CanvasPoint(CGPoint(x: 300, y: 260))],
                add: true,
                radius: 24
            )
            guard await waitUntil({ workspace.statusMessage == "Area aggiunta alla selezione" }) else {
                throw Failure.condition("Pennello additivo non completato")
            }
            workspace.paintSelection(
                points: [CanvasPoint(CGPoint(x: 220, y: 210))],
                add: false,
                radius: 14
            )
            guard await waitUntil({ workspace.statusMessage == "Area sottratta dalla selezione" }) else {
                throw Failure.condition("Pennello sottrattivo non completato")
            }
        }

        await record("Regolazione luce", into: &checks) {
            guard let before = workspace.compositePNG() else {
                throw Failure.condition("Composito iniziale non disponibile")
            }
            var settings = AdjustmentSettings.identity
            settings.exposure = 0.65
            workspace.addAdjustmentLayer(name: "Esposizione", settings: settings)
            guard let after = workspace.compositePNG(), before != after else {
                throw Failure.condition("La regolazione non cambia il render")
            }
        }

        await record("Resize livelli e DPI", into: &checks) {
            let width = max(1, workspace.document.width / 2)
            let height = max(1, workspace.document.height / 2)
            workspace.resizeImage(width: width, height: height, dpi: 144, method: .lanczos)
            guard workspace.document.width == width,
                  workspace.document.height == height,
                  workspace.document.dpi == 144 else {
                throw Failure.condition("Dimensioni o DPI errati")
            }
        }

        await record("Progetto .easyshop", into: &checks) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Easyshop-smoke-\(UUID().uuidString).easyshop")
            defer { try? FileManager.default.removeItem(at: url) }
            try ProjectIO.saveProject(workspace.document, to: url)
            let reopened = try ProjectIO.openProject(from: url)
            guard reopened.layers.count == workspace.document.layers.count else {
                throw Failure.condition("Round-trip livelli non riuscito")
            }
        }

        for ext in ["png", "jpg", "tiff", "psd"] {
            await record("Export \(ext.uppercased())", into: &checks) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Easyshop-smoke-\(UUID().uuidString).\(ext)")
                defer { try? FileManager.default.removeItem(at: url) }
                try ProjectIO.export(workspace.document, to: url)
                let data = try Data(contentsOf: url)
                if ext == "psd" {
                    guard data.starts(with: Array("8BPS".utf8)) else {
                        throw Failure.condition("Firma PSD mancante")
                    }
                } else {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          CGImageSourceGetCount(source) > 0 else {
                        throw Failure.condition("File esportato non decodificabile")
                    }
                }
            }
        }

        await record("Vision ML soggetto con provenienza verificata", into: &checks) {
            guard let demoData else { throw Failure.condition("Immagine demo assente") }
            let result = try await AIEngine.subjectMask(from: demoData)
            guard result.provenance.isVisionML else {
                throw Failure.condition("Il risultato usa un fallback non-AI: \(result.provenance.rawValue)")
            }
            guard ImageData.cgImage(from: result.maskData) != nil else {
                throw Failure.condition("Vision non ha prodotto una maschera")
            }
        }

        await record("Flusso UI selezione soggetto", into: &checks) {
            workspace.clearSelection()
            workspace.selectSubject()
            guard await waitUntil(timeout: .seconds(15), { !workspace.isProcessing }) else {
                throw Failure.condition("La selezione UI non ha terminato")
            }
            guard let selection = workspace.selection,
                  selection.kind == .ai,
                  selection.maskData != nil,
                  selection.outlineData != nil else {
                throw Failure.condition("Il comando UI non ha pubblicato la selezione Vision")
            }
        }

        await record("Preview proxy", into: &checks) {
            let request = PreviewRenderRequest(
                document: workspace.document,
                revision: 1,
                viewportSize: CGSize(width: 1200, height: 800),
                backingScaleFactor: 1
            )
            guard let preview = await PreviewRenderService.shared.render(request),
                  preview.image.width <= 1200,
                  preview.image.height <= 800 else {
                throw Failure.condition("Proxy assente o fuori limite")
            }
        }

        let report = Report(
            product: "Easyshop",
            generatedAt: Date(),
            passed: checks.allSatisfy(\.passed),
            checks: checks
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }

    private static func record(
        _ name: String,
        into checks: inout [Check],
        operation: () async throws -> Void
    ) async {
        let start = ContinuousClock().now
        do {
            try await operation()
            checks.append(Check(
                name: name,
                passed: true,
                detail: "OK",
                milliseconds: durationMilliseconds(since: start)
            ))
        } catch {
            checks.append(Check(
                name: name,
                passed: false,
                detail: error.localizedDescription,
                milliseconds: durationMilliseconds(since: start)
            ))
        }
    }

    private static func waitUntil(
        timeout: Duration = .seconds(8),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: ContinuousClock().now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
