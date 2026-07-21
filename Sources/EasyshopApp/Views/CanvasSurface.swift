import SwiftUI

struct CanvasSurface: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero
    @State private var dragStart: CanvasPoint?
    @State private var moveStartTransform: LayerTransform?
    @State private var canvasPanMode = false
    @State private var selectionStroke: [CanvasPoint] = []
    @State private var selectionBrushRadius: Double = 28
    @State private var previewImage: CGImage?
    @SceneStorage("easyshop.selectionBarX") private var selectionBarX = 0.50
    @SceneStorage("easyshop.selectionBarY") private var selectionBarY = 0.84
    @State private var selectionBarDragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size
            let documentSize = CGSize(width: workspace.document.width, height: workspace.document.height)
            let fit = min(
                (available.width - 150) / max(1, documentSize.width),
                (available.height - 155) / max(1, documentSize.height)
            )
            let scale = max(0.01, fit * zoom)
            let displaySize = CGSize(width: documentSize.width * scale, height: documentSize.height * scale)
            let origin = CGPoint(
                x: (available.width - displaySize.width) / 2 + pan.width,
                y: (available.height - displaySize.height) / 2 + pan.height
            )

            ZStack(alignment: .topLeading) {
                CanvasBackdrop()

                if let image = displayedImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .overlay {
                            Rectangle()
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
                        }
                        .position(
                            x: origin.x + displaySize.width / 2,
                            y: origin.y + displaySize.height / 2
                        )
                        .shadow(color: .black.opacity(0.62), radius: 38, y: 22)
                        .id(workspace.renderRevision)
                }

                SelectionOverlay(
                    selection: workspace.selection,
                    displaySize: displaySize,
                    origin: origin,
                    documentSize: documentSize
                )

                if !selectionStroke.isEmpty {
                    BrushStrokeOverlay(
                        points: selectionStroke,
                        add: workspace.activeTool == .brushAdd,
                        radius: selectionBrushRadius,
                        displaySize: displaySize,
                        origin: origin,
                        documentSize: documentSize
                    )
                }

                if let notice = workspace.notices.first {
                    NoticeBanner(notice: notice) {
                        workspace.notices.removeAll { $0.id == notice.id }
                    }
                    .frame(maxWidth: 520)
                    .position(x: available.width / 2, y: 102)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if workspace.selection != nil {
                    ContextActionBar(
                        onDrag: { moveSelectionBar($0, in: available) },
                        onDragEnded: { finishSelectionBarDrag($0, in: available) }
                    )
                        .position(selectionBarPosition(in: available))
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.94)))
                }

                ZoomBadge(
                    zoom: zoom,
                    panMode: canvasPanMode,
                    reset: {
                        zoom = 1
                        lastZoom = 1
                        pan = .zero
                        lastPan = .zero
                    },
                    togglePan: { canvasPanMode.toggle() }
                )
                .position(x: 105, y: available.height - 33)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(origin: origin, scale: scale))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        zoom = min(8, max(0.12, lastZoom * value))
                    }
                    .onEnded { _ in lastZoom = zoom }
            )
            .animation(.snappy(duration: 0.28), value: workspace.selection != nil)
            .task(id: CanvasRenderKey(
                revision: workspace.renderRevision,
                viewportWidth: Int(available.width.rounded()),
                viewportHeight: Int(available.height.rounded()),
                compareBefore: workspace.compareBefore
            )) {
                await refreshPreview(viewportSize: available)
            }
        }
    }

    private var displayedImage: CGImage? {
        if workspace.compareBefore,
           let before = ImageData.cgImage(from: workspace.beforeImageData) {
            return before
        }
        return previewImage
    }

    @MainActor
    private func refreshPreview(viewportSize: CGSize) async {
        guard workspace.hasImage else {
            previewImage = nil
            return
        }
        if workspace.compareBefore {
            previewImage = ImageData.cgImage(from: workspace.beforeImageData)
            return
        }

        let revision = workspace.renderRevision
        let request = PreviewRenderRequest(
            document: workspace.document,
            revision: UInt64(truncatingIfNeeded: revision),
            viewportSize: viewportSize
        )
        guard let result = await PreviewRenderService.shared.render(request),
              !Task.isCancelled,
              revision == workspace.renderRevision,
              !workspace.compareBefore else { return }
        previewImage = result.image
    }

    private func dragGesture(origin: CGPoint, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: workspace.activeTool == .move ? 2 : 0)
            .onChanged { value in
                if canvasPanMode {
                    pan = CGSize(
                        width: lastPan.width + value.translation.width,
                        height: lastPan.height + value.translation.height
                    )
                    return
                }

                guard workspace.hasImage else { return }
                let point = documentPoint(value.location, origin: origin, scale: scale)
                let beganGesture = dragStart == nil
                if beganGesture { dragStart = point }

                switch workspace.activeTool {
                case .move:
                    guard let layer = workspace.document.selectedLayer else { return }
                    guard !layer.isLocked else {
                        if beganGesture { workspace.refresh("Il livello è protetto — sbloccalo per spostarlo") }
                        return
                    }
                    guard layer.kind != .adjustment else {
                        if beganGesture { workspace.refresh("Le regolazioni non hanno una posizione sul canvas") }
                        return
                    }
                    if moveStartTransform == nil {
                        moveStartTransform = layer.transform
                        workspace.checkpoint("Sposta livello")
                    }
                    guard let start = moveStartTransform else { return }
                    var transform = start
                    transform.x = start.x + value.translation.width / scale
                    let verticalDelta = value.translation.height / scale
                    transform.y = start.y + (layer.kind == .text ? verticalDelta : -verticalDelta)
                    layer.transform = transform
                    workspace.interactiveTouch()
                case .rectangle:
                    workspace.selection = SelectionState(
                        kind: .rectangle,
                        points: [dragStart!, point],
                        maskData: nil
                    )
                case .ellipse:
                    workspace.selection = SelectionState(
                        kind: .ellipse,
                        points: [dragStart!, point],
                        maskData: nil
                    )
                case .lasso:
                    if beganGesture {
                        workspace.selection = SelectionState(kind: .lasso, points: [point], maskData: nil)
                    } else {
                        workspace.selection?.points.append(point)
                    }
                case .brushAdd, .brushSubtract:
                    if beganGesture { selectionStroke = [point] }
                    else { selectionStroke.append(point) }
                case .text:
                    if let layer = workspace.document.selectedLayer, layer.kind == .text {
                        if moveStartTransform == nil {
                            moveStartTransform = layer.transform
                            workspace.checkpoint("Posiziona testo")
                        }
                        layer.transform.x = point.x
                        layer.transform.y = point.y
                        workspace.interactiveTouch()
                    }
                case .smart:
                    break
                }
            }
            .onEnded { _ in
                if canvasPanMode {
                    lastPan = pan
                } else if workspace.activeTool == .move, moveStartTransform != nil {
                    workspace.touch("Livello spostato")
                } else if workspace.activeTool == .text {
                    if moveStartTransform != nil {
                        workspace.touch("Testo posizionato")
                    } else if let point = dragStart {
                        workspace.addTextLayer(at: point)
                    }
                } else if workspace.activeTool == .smart, let point = dragStart {
                    workspace.selectSubject(at: point)
                } else if workspace.activeTool == .brushAdd || workspace.activeTool == .brushSubtract {
                    workspace.paintSelection(
                        points: selectionStroke,
                        add: workspace.activeTool == .brushAdd,
                        radius: selectionBrushRadius
                    )
                } else if workspace.activeTool == .rectangle || workspace.activeTool == .ellipse || workspace.activeTool == .lasso {
                    workspace.finalizeManualSelection()
                }
                dragStart = nil
                moveStartTransform = nil
                selectionStroke = []
            }
    }

    private func documentPoint(_ location: CGPoint, origin: CGPoint, scale: CGFloat) -> CanvasPoint {
        CanvasPoint(CGPoint(
            x: min(Double(workspace.document.width), max(0, (location.x - origin.x) / scale)),
            y: min(Double(workspace.document.height), max(0, (location.y - origin.y) / scale))
        ))
    }

    private func selectionBarPosition(in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(280, size.width * selectionBarX), max(280, size.width - 280)),
            y: min(max(105, size.height * selectionBarY), max(105, size.height - 72))
        )
    }

    private func moveSelectionBar(_ translation: CGSize, in size: CGSize) {
        let origin = selectionBarDragOrigin ?? selectionBarPosition(in: size)
        selectionBarDragOrigin = origin
        let next = CGPoint(
            x: min(max(280, origin.x + translation.width), max(280, size.width - 280)),
            y: min(max(105, origin.y + translation.height), max(105, size.height - 72))
        )
        selectionBarX = next.x / max(1, size.width)
        selectionBarY = next.y / max(1, size.height)
    }

    private func finishSelectionBarDrag(_ translation: CGSize, in size: CGSize) {
        moveSelectionBar(translation, in: size)
        selectionBarDragOrigin = nil
    }
}

private struct CanvasRenderKey: Hashable {
    let revision: Int
    let viewportWidth: Int
    let viewportHeight: Int
    let compareBefore: Bool
}

private struct BrushStrokeOverlay: View {
    let points: [CanvasPoint]
    let add: Bool
    let radius: Double
    let displaySize: CGSize
    let origin: CGPoint
    let documentSize: CGSize

    var body: some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: mapped(first))
            if points.count == 1 {
                path.addLine(to: mapped(first))
            } else {
                points.dropFirst().forEach { path.addLine(to: mapped($0)) }
            }
        }
        .stroke(
            add ? EasyshopTheme.cyan : EasyshopTheme.coral,
            style: StrokeStyle(
                lineWidth: max(2, radius * 2 * displaySize.width / max(1, documentSize.width)),
                lineCap: .round,
                lineJoin: .round
            )
        )
        .opacity(0.55)
        .shadow(color: add ? EasyshopTheme.cyan.opacity(0.8) : EasyshopTheme.coral.opacity(0.8), radius: 7)
        .allowsHitTesting(false)
    }

    private func mapped(_ point: CanvasPoint) -> CGPoint {
        CGPoint(
            x: origin.x + point.x / max(1, documentSize.width) * displaySize.width,
            y: origin.y + point.y / max(1, documentSize.height) * displaySize.height
        )
    }
}

private struct ContextActionBar: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @State private var showRefine = false
    var onDrag: (CGSize) -> Void
    var onDragEnded: (CGSize) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(EasyshopTheme.muted)
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { onDrag($0.translation) }
                        .onEnded { onDragEnded($0.translation) }
                )
                .help("Trascina le azioni della selezione")
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(EasyshopTheme.gradient)
                    Image(systemName: workspace.selection?.kind == .ai ? "sparkles" : "scope")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(workspace.selection?.kind == .ai ? "SOGGETTO · VISION ML" : "SELEZIONE")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.7)
                    Text("Pronta · non distruttiva")
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(EasyshopTheme.muted)
                }
            }
            .padding(.horizontal, 7)

            Capsule().fill(EasyshopTheme.line).frame(width: 1, height: 25)
            Button {
                showRefine.toggle()
            } label: {
                Label("Bordi", systemImage: "slider.horizontal.below.square.filled.and.square")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(showRefine ? AnyShapeStyle(EasyshopTheme.gradient) : AnyShapeStyle(Color.white.opacity(0.055)), in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showRefine, arrowEdge: .bottom) {
                SelectionRefinePanel()
                    .environmentObject(workspace)
            }
            contextButton("Maschera", symbol: "rectangle.portrait.on.rectangle.portrait") {
                workspace.applyCurrentSelectionAsMask()
            }
            contextButton("Ritaglia", symbol: "crop") {
                workspace.cropToSelection()
            }
            contextButton("Chiudi", symbol: "xmark") {
                workspace.clearSelection()
            }
        }
        .padding(6)
        .floatingCapsule()
    }

    private func contextButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.055), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SelectionRefinePanel: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RIFINISCI IL BORDO")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                    Text("Sempre reversibile")
                        .font(.system(size: 9))
                        .foregroundStyle(EasyshopTheme.muted)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .foregroundStyle(EasyshopTheme.gradient)
            }
            refineSlider(
                "Sfumatura",
                value: Binding(
                    get: { workspace.selection?.feather ?? 0 },
                    set: { workspace.refineSelection(feather: $0, expansion: workspace.selection?.expansion ?? 0) }
                ),
                range: 0...24,
                suffix: "px"
            )
            refineSlider(
                "Espandi / contrai",
                value: Binding(
                    get: { workspace.selection?.expansion ?? 0 },
                    set: { workspace.refineSelection(feather: workspace.selection?.feather ?? 0, expansion: $0) }
                ),
                range: -24...24,
                suffix: "px"
            )
            Button {
                workspace.invertSelection()
            } label: {
                Label(
                    workspace.selection?.isInverted == true ? "Torna al soggetto" : "Inverti: seleziona sfondo",
                    systemImage: "circle.lefthalf.filled.inverse"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(16)
        .frame(width: 270)
        .background(EasyshopTheme.panel)
    }

    private func refineSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.system(size: 10.5, weight: .medium))
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(EasyshopTheme.cyan)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}

private struct CanvasBackdrop: View {
    var body: some View {
        ZStack {
            EasyshopTheme.canvas
            EasyshopTheme.ambient
                .scaleEffect(x: 1.7, y: 1.0)
                .offset(y: -80)
            Canvas { context, size in
                let step: CGFloat = 32
                var dots = Path()
                stride(from: CGFloat(0), through: size.width, by: step).forEach { x in
                    stride(from: CGFloat(0), through: size.height, by: step).forEach { y in
                        dots.addEllipse(in: CGRect(x: x - 0.55, y: y - 0.55, width: 1.1, height: 1.1))
                    }
                }
                context.fill(dots, with: .color(Color.white.opacity(0.055)))
            }
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.24)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }
}

private struct SelectionOverlay: View {
    var selection: SelectionState?
    var displaySize: CGSize
    var origin: CGPoint
    var documentSize: CGSize
    @State private var pulse = false
    @State private var march = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let selection, let mask = selection.maskData.flatMap(ImageData.cgImage(from:)) {
                Image(decorative: mask, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .colorMultiply(EasyshopTheme.violet)
                    .opacity(pulse ? 0.11 : 0.19)
                    .blendMode(.screen)
                    .position(imageCenter)

                if let outline = selection.outlineData.flatMap(ImageData.cgImage(from:)) {
                    Image(decorative: outline, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .colorMultiply(EasyshopTheme.violet)
                        .blur(radius: pulse ? 8 : 4)
                        .opacity(pulse ? 0.62 : 0.32)
                        .blendMode(.screen)
                        .position(imageCenter)

                    Image(decorative: outline, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .colorMultiply(EasyshopTheme.cyan)
                        .opacity(pulse ? 1 : 0.84)
                        .shadow(color: EasyshopTheme.cyan.opacity(0.88), radius: pulse ? 5 : 2)
                        .position(imageCenter)
                } else {
                    Image(decorative: mask, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displaySize.width, height: displaySize.height)
                        .colorMultiply(EasyshopTheme.cyan)
                        .blur(radius: pulse ? 5 : 2)
                        .opacity(pulse ? 0.30 : 0.18)
                        .blendMode(.screen)
                        .position(imageCenter)
                }
            }

            if let selection, selection.maskData == nil, selection.points.count >= 2 {
                selectionPath(selection)
                    .fill(EasyshopTheme.violet.opacity(pulse ? 0.08 : 0.14))
                selectionPath(selection)
                    .stroke(
                        EasyshopTheme.gradient,
                        style: StrokeStyle(
                            lineWidth: 1.8,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [7, 5],
                            dashPhase: march ? -24 : 0
                        )
                    )
                    .shadow(color: EasyshopTheme.cyan.opacity(0.75), radius: pulse ? 7 : 3)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                march = true
            }
        }
    }

    private var imageCenter: CGPoint {
        CGPoint(
            x: origin.x + displaySize.width / 2,
            y: origin.y + displaySize.height / 2
        )
    }

    private func mapped(_ point: CanvasPoint) -> CGPoint {
        CGPoint(
            x: origin.x + point.x / max(1, documentSize.width) * displaySize.width,
            y: origin.y + point.y / max(1, documentSize.height) * displaySize.height
        )
    }

    private func selectionPath(_ selection: SelectionState) -> Path {
        var path = Path()
        if selection.kind == .rectangle || selection.kind == .ellipse {
            let a = mapped(selection.points[0])
            let b = mapped(selection.points[1])
            let rect = CGRect(
                x: min(a.x, b.x),
                y: min(a.y, b.y),
                width: abs(a.x - b.x),
                height: abs(a.y - b.y)
            )
            if selection.kind == .ellipse {
                path.addEllipse(in: rect)
            } else {
                path.addRect(rect)
            }
        } else if let first = selection.points.first {
            path.move(to: mapped(first))
            for point in selection.points.dropFirst() {
                path.addLine(to: mapped(point))
            }
            path.closeSubpath()
        }
        return path
    }
}

private struct NoticeBanner: View {
    var notice: CompatibilityNotice
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.severity == .warning ? EasyshopTheme.coral : EasyshopTheme.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(notice.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(EasyshopTheme.muted)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .glassPanel(radius: 15)
    }
}

private struct ZoomBadge: View {
    var zoom: CGFloat
    var panMode: Bool
    var reset: () -> Void
    var togglePan: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: togglePan) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(panMode ? .white : EasyshopTheme.muted)
                    .frame(width: 26, height: 25)
                    .background(panMode ? AnyShapeStyle(EasyshopTheme.gradient) : AnyShapeStyle(Color.clear), in: Circle())
            }
            .buttonStyle(.plain)
            .help(panMode ? "Torna a modificare" : "Sposta il canvas")

            Button(action: reset) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(EasyshopTheme.cyan)
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
        }
        .padding(2)
        .floatingCapsule()
        .help("Reimposta zoom e posizione")
    }
}
