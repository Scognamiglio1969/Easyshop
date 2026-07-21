import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class EditorWorkspace: ObservableObject {
    @Published var document = EditorDocument()
    @Published var activeTool: EditorTool = .move
    @Published var selection: SelectionState?
    @Published var renderRevision = 0
    @Published var isProcessing = false
    @Published var processingLabel = ""
    @Published var statusMessage = "Apri un’immagine o crea un nuovo documento"
    @Published var notices: [CompatibilityNotice] = []
    @Published var showWelcome = true
    @Published var inspectorTab = 0
    @Published var exportQuality = 0.92
    @Published var showResizeSheet = false
    @Published var focusMode = false
    @Published var compareBefore = false
    @Published var beforeImageData: Data?
    @Published private(set) var isDirty = false

    private(set) var history: [HistorySnapshot] = []
    private var redoHistory: [HistorySnapshot] = []
    private var cancellables: Set<AnyCancellable> = []
    private var aiTask: Task<Void, Never>?
    private var selectionWorkTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var lastAIRequest: (key: String, startedAt: ContinuousClock.Instant)?
    private var lastInteractiveRefresh = Date.distantPast
    private let recoveryEnabled: Bool
    private var mutationGeneration: UInt64 = 0
    private var recoveredGeneration: UInt64 = 0

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        recoveryEnabled = !arguments.contains("--smoke-test")
        observeDocument()
        if arguments.contains("--smoke-test") {
            showWelcome = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(350))
                await RuntimeSmokeTest.run(workspace: self)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        let isDemo = arguments.contains("--demo") || arguments.contains("--demo-ai")
        if isDemo {
            loadBundledDemo()
            if ProcessInfo.processInfo.arguments.contains("--demo-ai") {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.2))
                    self?.selectSubject()
                }
            }
        } else {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.offerRecoveryIfAvailable()
            }
        }
    }

    var hasImage: Bool { !document.layers.isEmpty }

    func newDocument(width: Int = 1600, height: Int = 1000) {
        guard confirmDiscardIfNeeded() else { return }
        let background = makeSolidLayer(width: width, height: height, color: .white)
        document = EditorDocument(name: "Senza titolo", width: width, height: height, layers: [background])
        showWelcome = false
        notices = []
        history = []
        redoHistory = []
        observeDocument()
        beforeImageData = compositePNG()
        touch("Documento creato")
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Apri in Easyshop"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: ProjectIO.projectExtension) ?? .data,
            .image,
            .pdf,
            UTType("com.adobe.photoshop-image") ?? .image,
            UTType("com.adobe.photoshop-large-document") ?? .image
        ]
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        guard confirmDiscardIfNeeded() else { return }
        do {
            let result = try ProjectIO.importImage(from: url)
            document = result.0
            notices = result.1
            showWelcome = false
            history = []
            redoHistory = []
            observeDocument()
            beforeImageData = compositePNG()
            touch("Aperto \(url.lastPathComponent)")
            isDirty = false
        } catch {
            presentError(error)
        }
    }

    func importAsLayer(_ url: URL) {
        do {
            let (imported, importNotices) = try ProjectIO.importImage(from: url)
            guard !imported.layers.isEmpty else { throw ProjectIOError.unreadableImage }
            if !hasImage {
                document = imported
                showWelcome = false
                history = []
                redoHistory = []
                observeDocument()
                beforeImageData = imported.layers.first?.rasterData
            } else {
                let combinedCount = document.layers.count + imported.layers.count
                guard combinedCount <= ProjectSafetyLimits.maximumLayerCount else {
                    throw ProjectIOError.tooManyLayers(
                        actual: combinedCount,
                        maximum: ProjectSafetyLimits.maximumLayerCount
                    )
                }
                checkpoint("Importa livelli")
                document.layers.append(contentsOf: imported.layers)
                document.selectedLayerID = imported.layers.last?.id
            }
            notices.insert(contentsOf: importNotices, at: 0)
            touch("Importato \(url.lastPathComponent) come livello")
        } catch {
            presentError(error)
        }
    }

    func save() {
        if let url = document.fileURL, url.pathExtension.lowercased() == ProjectIO.projectExtension {
            do {
                try ProjectIO.saveProject(document, to: url)
                statusMessage = "Progetto salvato"
                didSaveProject()
            } catch { presentError(error) }
        } else {
            saveAsPanel()
        }
    }

    func saveAsPanel() {
        let panel = NSSavePanel()
        panel.title = "Salva progetto Easyshop"
        panel.nameFieldStringValue = "\(document.name).easyshop"
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectIO.projectExtension) ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ProjectIO.saveProject(document, to: url)
                statusMessage = "Progetto salvato"
                didSaveProject()
            } catch { presentError(error) }
        }
    }

    func exportPanel() {
        guard hasImage else { return }
        let panel = NSSavePanel()
        panel.title = "Esporta immagine"
        panel.nameFieldStringValue = "\(document.name).png"
        let destinationTypes = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
            .compactMap(UTType.init)
        panel.allowedContentTypes = Array(Set(destinationTypes + [
            .png, .jpeg, .tiff, .heic, .bmp, .gif, .pdf,
            UTType("public.avif") ?? .image,
            UTType("com.adobe.photoshop-image") ?? .image,
            UTType("com.ilm.openexr-image") ?? .image
        ]))
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ProjectIO.export(document, to: url, quality: exportQuality)
                statusMessage = "Esportato \(url.lastPathComponent)"
                if url.pathExtension.lowercased() == "psd" {
                    notices.insert(CompatibilityNotice(
                        severity: .info,
                        title: "PSD esportato",
                        detail: "Livelli raster preservati; testo e regolazioni sono rasterizzati per garantire l’aspetto. Il progetto .easyshop resta la copia completamente editabile."
                    ), at: 0)
                }
            } catch { presentError(error) }
        }
    }

    func addRasterLayer(data: Data, name: String = "Nuovo livello") {
        checkpoint("Aggiungi livello")
        let layer = EditorLayer(name: name, kind: .raster, rasterData: data)
        document.layers.append(layer)
        document.selectedLayerID = layer.id
        touch("Livello aggiunto")
    }

    func addTextLayer(content: String = "Scrivi qui", at point: CanvasPoint? = nil) {
        checkpoint("Aggiungi testo")
        var text = TextSettings()
        text.content = content
        let layer = EditorLayer(
            name: content.isEmpty ? "Testo" : String(content.prefix(24)),
            kind: .text,
            transform: LayerTransform(
                x: point?.x ?? Double(document.width) * 0.15,
                y: point?.y ?? Double(document.height) * 0.2
            ),
            text: text
        )
        document.layers.append(layer)
        document.selectedLayerID = layer.id
        activeTool = .text
        inspectorTab = 1
        touch(point == nil ? "Livello testo creato" : "Testo creato nel punto indicato")
    }

    func addAdjustmentLayer(
        name: String = "Regolazione",
        settings: AdjustmentSettings = .identity,
        scope: AdjustmentScope = .entireImage,
        maskData: Data? = nil
    ) {
        checkpoint("Aggiungi regolazione")
        let layer = EditorLayer(
            name: name,
            kind: .adjustment,
            adjustment: settings,
            adjustmentScope: scope,
            maskData: maskData
        )
        document.layers.append(layer)
        document.selectedLayerID = layer.id
        inspectorTab = 1
        touch("Regolazione aggiunta")
    }

    func duplicateSelectedLayer() {
        guard let source = document.selectedLayer else { return }
        checkpoint("Duplica livello")
        let copy = EditorLayer(record: source.record())
        copy.name = "\(source.name) copia"
        let layer = EditorLayer(
            name: copy.name,
            kind: copy.kind,
            isVisible: copy.isVisible,
            opacity: copy.opacity,
            blendMode: copy.blendMode,
            transform: copy.transform,
            text: copy.text,
            adjustment: copy.adjustment,
            adjustmentScope: copy.adjustmentScope,
            rasterData: copy.rasterData,
            maskData: copy.maskData,
            // A duplicate is a new editable object even when its source is locked.
            isLocked: false
        )
        document.layers.append(layer)
        document.selectedLayerID = layer.id
        touch("Livello duplicato")
    }

    func deleteSelectedLayer() {
        guard let layer = document.selectedLayer else { return }
        guard !layer.isLocked else {
            statusMessage = "“\(layer.name)” è protetto — sbloccalo prima di eliminarlo"
            return
        }
        guard let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        checkpoint("Elimina livello")
        document.layers.remove(at: index)
        document.selectedLayerID = document.layers.last?.id
        touch("Livello eliminato")
    }

    func moveSelectedLayer(by offset: Int) {
        guard let layer = document.selectedLayer else { return }
        guard !layer.isLocked else {
            statusMessage = "“\(layer.name)” è protetto — sbloccalo prima di spostarlo"
            return
        }
        guard let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let destination = index + offset
        guard document.layers.indices.contains(destination) else { return }
        checkpoint("Riordina livelli")
        document.layers.swapAt(index, destination)
        touch("Livelli riordinati")
    }

    func applyCurrentSelectionAsMask() {
        guard let layer = document.selectedLayer, let selection else { return }
        guard !layer.isLocked else {
            statusMessage = "“\(layer.name)” è protetto — sbloccalo prima di applicare la maschera"
            return
        }
        let mask = resolvedMask(for: selection)
        guard let mask else { return }
        checkpoint("Applica maschera")
        layer.maskData = mask
        touch("Maschera applicata a \(layer.name)")
    }

    /// Rebuilds the selection from its untouched source mask every time. Slider
    /// changes are therefore reversible and never repeatedly blur or erode an edge.
    func refineSelection(feather: Double, expansion: Double) {
        guard var current = selection else { return }
        let cleanSource = current.sourceMaskData
            ?? current.maskData
            ?? SelectionEngine.maskData(
                for: current,
                width: document.width,
                height: document.height,
                feather: 0
            )
        guard let cleanSource else {
            statusMessage = "La selezione non contiene ancora un’area rifinibile"
            return
        }
        current.sourceMaskData = cleanSource
        current.feather = min(40, max(0, feather))
        current.expansion = min(36, max(-36, expansion))
        // Publish the controls immediately, but render the expensive full-size
        // mask away from the main actor. Rapid slider changes cancel stale work.
        selection = current
        let width = document.width
        let height = document.height
        let requestedFeather = current.feather
        let requestedExpansion = current.expansion
        let requestedInversion = current.isInverted
        selectionWorkTask?.cancel()
        statusMessage = "Rifinisco il bordo…"
        selectionWorkTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let refined = SelectionEngine.refinedMaskData(
                    cleanSource,
                    width: width,
                    height: height,
                    feather: requestedFeather,
                    expansion: requestedExpansion,
                    inverted: requestedInversion
                )
                let outline = refined.flatMap {
                    SelectionEngine.outlineData(from: $0, width: width, height: height)
                }
                return (refined, outline)
            }.value
            guard let self,
                  !Task.isCancelled,
                  var latest = self.selection,
                  latest.feather == requestedFeather,
                  latest.expansion == requestedExpansion,
                  latest.isInverted == requestedInversion,
                  let refined = result.0 else { return }
            latest.maskData = refined
            latest.outlineData = result.1
            self.selection = latest
            self.refresh("Bordo rifinito — \(Int(requestedExpansion)) px, sfumatura \(Int(requestedFeather)) px")
        }
    }

    func invertSelection() {
        guard var current = selection else { return }
        let cleanSource = current.sourceMaskData
            ?? current.maskData
            ?? SelectionEngine.maskData(
                for: current,
                width: document.width,
                height: document.height,
                feather: 0
            )
        guard let cleanSource else { return }
        current.sourceMaskData = cleanSource
        current.isInverted.toggle()
        selection = current
        refineSelection(feather: current.feather, expansion: current.expansion)
    }

    /// Refines the visible selection directly on the canvas. Painting always
    /// starts from the currently displayed mask so an inverted selection stays
    /// visually predictable; the painted result becomes the new clean source
    /// for later feather/expand operations.
    func paintSelection(points: [CanvasPoint], add: Bool, radius: Double) {
        guard !points.isEmpty else { return }
        guard add || selection?.isUsable == true else {
            statusMessage = "Non c’è ancora una selezione da sottrarre"
            return
        }
        let current = selection
        let width = document.width
        let height = document.height
        let feather = current?.feather ?? 0
        let expansion = current?.expansion ?? 0
        let immediateBase = current?.maskData ?? current?.sourceMaskData
        let vectorSelection = current
        selectionWorkTask?.cancel()
        statusMessage = add ? "Aggiungo alla selezione…" : "Sottraggo dalla selezione…"
        selectionWorkTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let base = immediateBase ?? vectorSelection.flatMap {
                    SelectionEngine.maskData(for: $0, width: width, height: height, feather: 0)
                }
                guard let painted = SelectionEngine.paintMask(
                    baseData: base,
                    points: points,
                    radius: radius,
                    add: add,
                    width: width,
                    height: height
                ) else { return Optional<(Data, Data, Data?)>.none }
                let refined = SelectionEngine.refinedMaskData(
                    painted,
                    width: width,
                    height: height,
                    feather: feather,
                    expansion: expansion,
                    inverted: false
                ) ?? painted
                let outline = SelectionEngine.outlineData(from: refined, width: width, height: height)
                return (painted, refined, outline)
            }.value
            guard let self, !Task.isCancelled, let result else { return }
            self.selection = SelectionState(
                kind: .lasso,
                points: [],
                maskData: result.1,
                sourceMaskData: result.0,
                outlineData: result.2,
                feather: feather,
                expansion: expansion,
                isInverted: false
            )
            self.refresh(add ? "Area aggiunta alla selezione" : "Area sottratta dalla selezione")
        }
    }

    /// Commits rectangle, ellipse and lasso gestures to a real full-resolution
    /// mask. The vector path remains visible while the mask is built, so the UI
    /// never freezes on a large photograph.
    func finalizeManualSelection() {
        guard let current = selection, current.hasUsableVectorPath else {
            selection = nil
            refresh("Trascina sull’immagine per creare una selezione")
            return
        }
        let width = document.width
        let height = document.height
        let feather = current.feather
        selectionWorkTask?.cancel()
        statusMessage = "Creo la selezione…"
        selectionWorkTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                guard let source = SelectionEngine.maskData(
                    for: current,
                    width: width,
                    height: height,
                    feather: 0
                ) else { return Optional<(Data, Data, Data?)>.none }
                let refined = SelectionEngine.refinedMaskData(
                    source,
                    width: width,
                    height: height,
                    feather: feather,
                    expansion: 0,
                    inverted: false
                ) ?? source
                let outline = SelectionEngine.outlineData(from: refined, width: width, height: height)
                return (source, refined, outline)
            }.value
            guard let self, !Task.isCancelled, let result else { return }
            self.selection = SelectionState(
                kind: current.kind,
                points: current.points,
                maskData: result.1,
                sourceMaskData: result.0,
                outlineData: result.2,
                feather: feather
            )
            self.refresh("Selezione pronta")
        }
    }

    func clearSelection() {
        selectionWorkTask?.cancel()
        selection = nil
        refresh("Selezione rimossa")
    }

    func selectSubject(at point: CanvasPoint? = nil) {
        runAI(label: point == nil ? "Riconosco i soggetti…" : "Aggancio il soggetto indicato…", key: "select-subject") { [weak self] in
            guard let self, let imageData = await self.processingCompositePNG() else { throw AIEngineError.processingFailed }
            let result = try await AIEngine.subjectMask(from: imageData, selectedPoint: point)
            let sourceMask = result.maskData
            try Task.checkCancellation()
            let feather = 0.8
            let mask = SelectionEngine.refinedMaskData(
                sourceMask,
                width: self.document.width,
                height: self.document.height,
                feather: feather,
                expansion: 0,
                inverted: false
            ) ?? sourceMask
            let outline = SelectionEngine.outlineData(
                from: mask,
                width: self.document.width,
                height: self.document.height
            )
            self.selection = SelectionState(
                kind: result.selectionKind,
                points: point.map { [$0] } ?? [],
                maskData: mask,
                sourceMaskData: sourceMask,
                outlineData: outline,
                feather: feather
            )
            self.activeTool = result.provenance.isVisionML ? .smart : .brushAdd
            let target = point == nil ? "Soggetti agganciati" : "Soggetto agganciato dal punto indicato"
            self.refresh("\(target) con \(result.provenance.userFacingLabel) — bordo modificabile")
        }
    }

    func removeBackground() {
        guard automaticVisibilityChangeIsAllowed() else { return }
        runAI(label: "Rimuovo lo sfondo…", key: "remove-background") { [weak self] in
            guard let self, let imageData = await self.processingCompositePNG() else { throw AIEngineError.processingFailed }
            let result = try await AIEngine.subjectMask(from: imageData)
            let sourceMask = result.maskData
            try Task.checkCancellation()
            let mask = SelectionEngine.refinedMaskData(
                sourceMask,
                width: self.document.width,
                height: self.document.height,
                feather: 0.8,
                expansion: 0,
                inverted: false
            ) ?? sourceMask
            guard self.automaticVisibilityChangeIsAllowed() else { return }
            self.checkpoint("Rimuovi sfondo")
            let layer = EditorLayer(name: "Soggetto · \(result.provenance.userFacingLabel)", kind: .raster, rasterData: imageData, maskData: mask)
            self.document.layers.forEach { $0.isVisible = false }
            self.document.layers.append(layer)
            self.document.selectedLayerID = layer.id
            self.selection = SelectionState(
                kind: result.selectionKind,
                points: [],
                maskData: mask,
                sourceMaskData: sourceMask,
                outlineData: SelectionEngine.outlineData(from: mask, width: self.document.width, height: self.document.height),
                feather: 0.8
            )
            self.touch("Sfondo rimosso con \(result.provenance.userFacingLabel) su un nuovo livello")
        }
    }

    func separateSubjectAndBackground() {
        guard automaticVisibilityChangeIsAllowed() else { return }
        runAI(label: "Separo soggetto e sfondo…", key: "separate-subject") { [weak self] in
            guard let self, let imageData = await self.processingCompositePNG() else { throw AIEngineError.processingFailed }
            let result = try await AIEngine.subjectMask(from: imageData)
            let mask = result.maskData
            try Task.checkCancellation()
            let backgroundMask = ImageData.invertedMaskData(mask)
            guard let backgroundMask else { throw AIEngineError.processingFailed }
            guard self.automaticVisibilityChangeIsAllowed() else { return }
            self.checkpoint("Separa soggetto e sfondo")
            self.document.layers.forEach { $0.isVisible = false }
            let background = EditorLayer(name: "Sfondo · \(result.provenance.userFacingLabel)", kind: .raster, rasterData: imageData, maskData: backgroundMask)
            let subject = EditorLayer(name: "Soggetto · \(result.provenance.userFacingLabel)", kind: .raster, rasterData: imageData, maskData: mask)
            self.document.layers.append(contentsOf: [background, subject])
            self.document.selectedLayerID = subject.id
            self.touch("Soggetto e sfondo separati con \(result.provenance.userFacingLabel)")
        }
    }

    func autoEnhance() {
        runAI(label: "Analizzo luce e colore…", key: "auto-enhance") { [weak self] in
            guard let self, let imageData = await self.processingCompositePNG() else { throw AIEngineError.processingFailed }
            let settings = await AIEngine.recommendedAdjustments(for: imageData)
            try Task.checkCancellation()
            self.addAdjustmentLayer(name: "Miglioramento automatico", settings: settings)
            self.touch("Miglioramento automatico aggiunto e modificabile")
        }
    }

    func localizedCorrection(_ scope: AdjustmentScope) {
        runAI(label: "Creo la maschera \(scope.label.lowercased())…", key: "localized-\(scope.rawValue)") { [weak self] in
            guard let self, let imageData = await self.processingCompositePNG() else { throw AIEngineError.processingFailed }
            let mask: Data
            let provenanceLabel: String
            switch scope {
            case .face:
                mask = try await AIEngine.faceMask(from: imageData)
                provenanceLabel = "Vision ML"
            case .sky:
                mask = try await AIEngine.skyMask(from: imageData)
                provenanceLabel = "euristico non‑AI"
            case .subject:
                let result = try await AIEngine.subjectMask(from: imageData)
                mask = result.maskData
                provenanceLabel = result.provenance.userFacingLabel
            case .background:
                let result = try await AIEngine.subjectMask(from: imageData)
                mask = ImageData.invertedMaskData(result.maskData) ?? Data()
                provenanceLabel = result.provenance.userFacingLabel
            case .entireImage:
                mask = Data()
                provenanceLabel = "regolazione locale non‑AI"
            }
            try Task.checkCancellation()
            var settings = AdjustmentSettings.identity
            if scope == .face {
                settings.shadows = 0.16
                settings.vibrance = 0.08
                settings.sharpness = 0.12
            } else if scope == .sky {
                settings.highlights = 0.82
                settings.vibrance = 0.28
                settings.saturation = 1.06
            } else {
                settings.exposure = 0.08
                settings.vibrance = 0.18
                settings.sharpness = 0.18
            }
            self.addAdjustmentLayer(name: "Correzione \(scope.label) · \(provenanceLabel)", settings: settings, scope: scope, maskData: mask.isEmpty ? nil : mask)
            self.statusMessage = "Correzione \(scope.label.lowercased()) creata con \(provenanceLabel)"
        }
    }

    func smartErase() {
        guard let selection else {
            presentError(AIEngineError.missingSelection)
            return
        }
        runAI(label: "Ricostruisco l’area selezionata…", key: "smart-erase") { [weak self] in
            guard let self, let imageData = await self.processingCompositePNG() else { throw AIEngineError.processingFailed }
            guard let mask = self.resolvedMask(for: selection) else {
                throw AIEngineError.missingSelection
            }
            let result = try await AIEngine.smartErase(imageData: imageData, maskData: mask)
            try Task.checkCancellation()
            self.checkpoint("Riempimento rapido Beta")
            let layer = EditorLayer(name: "Riempimento rapido · Beta · algoritmo locale", kind: .raster, rasterData: result)
            self.document.layers.append(layer)
            self.document.selectedLayerID = layer.id
            self.selection = nil
            self.touch("Riempimento rapido creato su un nuovo livello · algoritmo locale Beta")
        }
    }

    func upscale() {
        guard automaticVisibilityChangeIsAllowed() else { return }
        do {
            try ResizeEngine.validateTarget(width: document.width * 2, height: document.height * 2)
        } catch {
            presentError(error)
            return
        }
        runAI(label: "Aumento la risoluzione…", key: "upscale") { [weak self] in
            guard let self, let imageData = await self.processingCompositePNG() else { throw AIEngineError.processingFailed }
            let result = try await AIEngine.upscale(imageData: imageData)
            try Task.checkCancellation()
            guard self.automaticVisibilityChangeIsAllowed() else { return }
            self.checkpoint("Upscale preciso 2×")
            self.document.layers.forEach { $0.isVisible = false }
            self.document.width *= 2
            self.document.height *= 2
            let layer = EditorLayer(name: "Upscale preciso 2× · Lanczos", kind: .raster, rasterData: result)
            self.document.layers.append(layer)
            self.document.selectedLayerID = layer.id
            self.touch("Risoluzione raddoppiata su un nuovo livello")
        }
    }

    func restore() {
        var settings = AdjustmentSettings.identity
        settings.noiseReduction = 0.08
        settings.sharpness = 0.42
        settings.contrast = 1.06
        settings.shadows = 0.12
        settings.vibrance = 0.12
        addAdjustmentLayer(name: "Restauro rapido · filtri locali", settings: settings)
        statusMessage = "Restauro rapido aggiunto come regolazione non distruttiva · non AI"
    }

    func resizeImage(width: Int, height: Int, dpi: Double, method: ResizeMethod) {
        guard width > 0, height > 0 else { return }
        guard width != document.width || height != document.height || dpi != document.dpi else {
            statusMessage = "Le dimensioni sono già \(width) × \(height) px"
            return
        }
        let historyCount = history.count
        let redoBackup = redoHistory
        checkpoint("Ridimensiona immagine")
        do {
            try ResizeEngine.resizeImage(document: document, width: width, height: height, dpi: dpi, method: method)
            selection = nil
            touch("Immagine ridimensionata a \(width) × \(height) px")
        } catch {
            if history.count > historyCount { history.removeLast() }
            redoHistory = redoBackup
            presentError(error)
        }
    }

    func resizeCanvas(width: Int, height: Int, anchor: CanvasAnchor) {
        guard width > 0, height > 0 else { return }
        guard width != document.width || height != document.height else {
            statusMessage = "Il quadro è già \(width) × \(height) px"
            return
        }
        let historyCount = history.count
        let redoBackup = redoHistory
        checkpoint("Dimensione quadro")
        do {
            try ResizeEngine.resizeCanvas(document: document, width: width, height: height, anchor: anchor)
            selection = nil
            touch("Quadro impostato a \(width) × \(height) px")
        } catch {
            if history.count > historyCount { history.removeLast() }
            redoHistory = redoBackup
            presentError(error)
        }
    }

    func cropToSelection() {
        guard let selection else {
            statusMessage = "Crea prima una selezione da ritagliare"
            return
        }
        guard ResizeEngine.cropBounds(for: selection, width: document.width, height: document.height) != nil else {
            statusMessage = "La selezione non contiene un’area ritagliabile"
            return
        }
        let historyCount = history.count
        let redoBackup = redoHistory
        checkpoint("Ritaglia alla selezione")
        do {
            if try ResizeEngine.crop(document: document, selection: selection) {
                self.selection = nil
                touch("Documento ritagliato alla selezione")
            } else {
                if history.count > historyCount { history.removeLast() }
                redoHistory = redoBackup
                statusMessage = "La selezione non contiene un’area ritagliabile"
            }
        } catch {
            if history.count > historyCount { history.removeLast() }
            redoHistory = redoBackup
            presentError(error)
        }
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        redoHistory.append(HistorySnapshot(title: previous.title, record: document.record()))
        restore(previous)
        statusMessage = "Annullato: \(previous.title)"
    }

    func redo() {
        guard let next = redoHistory.popLast() else { return }
        history.append(HistorySnapshot(title: next.title, record: document.record()))
        restore(next)
        statusMessage = "Ripristinato: \(next.title)"
    }

    func checkpoint(_ title: String) {
        guard !document.layers.isEmpty || history.isEmpty else { return }
        history.append(HistorySnapshot(title: title, record: document.record()))
        if history.count > 30 { history.removeFirst() }
        redoHistory.removeAll()
    }

    func touch(_ message: String? = nil) {
        if let message { statusMessage = message }
        document.objectWillChange.send()
        isDirty = true
        mutationGeneration &+= 1
        scheduleRecovery()
    }

    /// Lightweight refresh for direct manipulation. It caps expensive canvas
    /// renders at roughly 30 fps and defers autosave until the gesture commits.
    func interactiveTouch() {
        isDirty = true
        mutationGeneration &+= 1
        scheduleRecovery()
        let now = Date()
        guard now.timeIntervalSince(lastInteractiveRefresh) >= 1.0 / 30.0 else { return }
        lastInteractiveRefresh = now
        document.objectWillChange.send()
    }

    /// Refreshes transient editor state (selection, tool feedback) without
    /// marking the project as modified or scheduling a disk autosave.
    func refresh(_ message: String? = nil) {
        if let message { statusMessage = message }
    }

    func compositePNG() -> Data? {
        RenderEngine.composite(document: document).flatMap(ImageData.pngData(from:))
    }

    /// Captures immutable layer snapshots on the main actor, then performs the
    /// expensive full-resolution composite and PNG encoding on a dedicated
    /// background renderer. AI/local processing awaits this without freezing
    /// the progress overlay or window interactions.
    private func processingCompositePNG() async -> Data? {
        guard hasImage else { return nil }
        let width = max(1, document.width)
        let height = max(1, document.height)
        let request = PreviewRenderRequest(
            document: document,
            revision: UInt64(truncatingIfNeeded: renderRevision),
            viewportSize: CGSize(width: width, height: height),
            backingScaleFactor: 1,
            maximumPixelDimension: max(width, height)
        )
        return await PreviewRenderService.processing.renderPNG(request)
    }

    private func observeDocument() {
        cancellables.removeAll()
        document.objectWillChange
            .sink { [weak self] _ in self?.renderRevision &+= 1 }
            .store(in: &cancellables)
    }

    private func restore(_ snapshot: HistorySnapshot) {
        let url = document.fileURL
        document = EditorDocument.from(record: snapshot.record, url: url)
        observeDocument()
        touch()
    }

    private func scheduleRecovery() {
        guard recoveryEnabled, hasImage else { return }
        guard recoveryTask == nil else { return }
        recoveryTask = Task { @MainActor [weak self] in
            do {
                // Throttle instead of debounce: a long drag or slider movement
                // cannot postpone crash recovery forever.
                try await Task.sleep(for: .milliseconds(750))
                if let self, !Task.isCancelled, self.isDirty {
                    _ = try RecoveryService.autosave(self.document)
                    self.recoveredGeneration = self.mutationGeneration
                }
            } catch is CancellationError {
                // Normal when a real save or an orderly termination takes over.
            } catch {
                self?.statusMessage = "Recupero automatico non disponibile: \(error.localizedDescription)"
            }
            guard let self else { return }
            self.recoveryTask = nil
            if self.isDirty, self.recoveredGeneration < self.mutationGeneration {
                self.scheduleRecovery()
            }
        }
    }

    private func didSaveProject() {
        isDirty = false
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveredGeneration = mutationGeneration
        try? RecoveryService.deleteRecovery()
    }

    /// Flushes the newest state synchronously before a window or the app exits.
    /// Recovery remains separate from Save/Save As and never overwrites user files.
    @discardableResult
    func synchronizeRecoveryBeforeClosing() -> Bool {
        guard recoveryEnabled, isDirty, hasImage else { return true }
        if recoveredGeneration >= mutationGeneration, RecoveryService.hasRecovery {
            return true
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        do {
            _ = try RecoveryService.autosave(document)
            recoveredGeneration = mutationGeneration
            return true
        } catch {
            statusMessage = "Impossibile creare il recupero: \(error.localizedDescription)"
            return false
        }
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard isDirty, hasImage else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Salvare le modifiche a “\(document.name)” ?"
        alert.informativeText = "Le modifiche non salvate possono essere recuperate automaticamente, ma è più sicuro salvare il progetto."
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Non salvare")
        alert.addButton(withTitle: "Annulla")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !isDirty
        case .alertSecondButtonReturn:
            recoveryTask?.cancel()
            recoveryTask = nil
            try? RecoveryService.deleteRecovery()
            isDirty = false
            return true
        default:
            return false
        }
    }

    private func offerRecoveryIfAvailable() {
        guard RecoveryService.hasRecovery,
              let info = try? RecoveryService.recoveryInfo() else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Riprendere “\(info.documentName)” ?"
        alert.informativeText = "Easyshop ha trovato un recupero automatico del \(info.modifiedAt.formatted(date: .abbreviated, time: .shortened))."
        alert.addButton(withTitle: "Riprendi")
        alert.addButton(withTitle: "Scarta")
        alert.addButton(withTitle: "Più tardi")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                guard let recovered = try RecoveryService.recoverLatest() else { return }
                document = recovered
                showWelcome = false
                notices = [CompatibilityNotice(
                    severity: .success,
                    title: "Lavoro recuperato",
                    detail: "Salvalo come progetto .easyshop per conservarlo definitivamente."
                )]
                history = []
                redoHistory = []
                observeDocument()
                beforeImageData = compositePNG()
                isDirty = true
                renderRevision &+= 1
                statusMessage = "Recupero automatico ripristinato"
            } catch {
                presentError(error)
            }
        case .alertSecondButtonReturn:
            try? RecoveryService.deleteRecovery()
        default:
            break
        }
    }

    private func runAI(
        label: String,
        key: String = "generic",
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isProcessing else { return }
        let clock = ContinuousClock()
        let now = clock.now
        if let lastAIRequest,
           lastAIRequest.key == key,
           lastAIRequest.startedAt.duration(to: now) < .milliseconds(700) {
            return
        }
        lastAIRequest = (key, now)
        isProcessing = true
        processingLabel = label
        aiTask?.cancel()
        aiTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isProcessing = false
                self.processingLabel = ""
                self.aiTask = nil
            }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch is CancellationError {
                self.statusMessage = "Operazione annullata"
            } catch {
                self.presentError(error)
            }
        }
    }

    private func resolvedMask(for selection: SelectionState) -> Data? {
        if let mask = selection.maskData { return mask }
        guard let source = selection.sourceMaskData
            ?? SelectionEngine.maskData(
                for: selection,
                width: document.width,
                height: document.height,
                feather: 0
            ) else { return nil }
        return SelectionEngine.refinedMaskData(
            source,
            width: document.width,
            height: document.height,
            feather: selection.feather,
            expansion: selection.expansion,
            inverted: selection.isInverted
        ) ?? source
    }

    /// Automatic operations that isolate a result by hiding the existing stack
    /// must never bypass a layer lock. Failing before any processing also avoids
    /// spending time on an edit that cannot be committed safely.
    private func automaticVisibilityChangeIsAllowed() -> Bool {
        guard let locked = document.layers.first(where: { $0.isLocked && $0.isVisible }) else {
            return true
        }
        presentError(ResizeEngineError.lockedLayer(locked.name))
        return false
    }

    private func presentError(_ error: Error) {
        statusMessage = error.localizedDescription
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Easyshop"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func makeSolidLayer(width: Int, height: Int, color: NSColor) -> EditorLayer {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return EditorLayer(name: "Sfondo", kind: .raster) }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = context.makeImage().flatMap(ImageData.pngData(from:))
        return EditorLayer(name: "Sfondo", kind: .raster, rasterData: data, isLocked: true)
    }

    private func loadBundledDemo() {
        guard let url = Bundle.main.url(forResource: "DemoPortrait", withExtension: "png")
                ?? Bundle.module.url(forResource: "DemoPortrait", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let image = ImageData.cgImage(from: data) else { return }

        var color = AdjustmentSettings.identity
        color.highlights = 0.86
        color.shadows = 0.16
        color.vibrance = 0.22
        color.temperature = 90
        color.sharpness = 0.14
        var title = TextSettings()
        title.content = "CREA. VELOCE."
        title.fontName = "Avenir Next Heavy"
        title.fontSize = 54
        title.tracking = 2.5
        title.width = 520

        let photo = EditorLayer(name: "Ritratto originale", kind: .raster, rasterData: data)
        let grade = EditorLayer(name: "Color grading", kind: .adjustment, opacity: 0.88, adjustment: color)
        let text = EditorLayer(
            name: "Titolo campagna",
            kind: .text,
            transform: LayerTransform(x: Double(image.width) * 0.60, y: Double(image.height) * 0.16),
            text: title
        )
        document = EditorDocument(
            name: "Tour Easyshop",
            width: image.width,
            height: image.height,
            layers: [photo, grade, text],
            sourceFormat: "PNG"
        )
        showWelcome = false
        document.selectedLayerID = grade.id
        history = []
        redoHistory = []
        observeDocument()
        beforeImageData = data
        statusMessage = "Demo pronta — prova “seleziona soggetto”"
    }
}
