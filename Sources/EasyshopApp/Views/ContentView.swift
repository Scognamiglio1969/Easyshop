import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inspectorVisible = false
    @SceneStorage("easyshop.toolRailX") private var toolRailX = 54.0
    @SceneStorage("easyshop.toolRailY") private var toolRailY = 0.50
    @SceneStorage("easyshop.inspectorRight") private var inspectorRight = 187.0
    @SceneStorage("easyshop.inspectorY") private var inspectorY = 0.50
    @State private var toolDragOrigin: CGPoint?
    @State private var inspectorDragOrigin: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                EasyshopTheme.background.ignoresSafeArea()
                CanvasSurface()

                if workspace.showWelcome || !workspace.hasImage {
                    WelcomeView()
                        .padding(.top, 64)
                }

                if !workspace.focusMode {
                    ToolRail(
                        onDrag: { moveToolRail($0, in: proxy.size) },
                        onDragEnded: { finishToolRailDrag($0, in: proxy.size) }
                    )
                        .position(toolRailPosition(in: proxy.size))
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    if inspectorVisible {
                        InspectorPanel(
                            onClose: {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.20)) {
                                    inspectorVisible = false
                                }
                            },
                            onDrag: { moveInspector($0, in: proxy.size) },
                            onDragEnded: { finishInspectorDrag($0, in: proxy.size) }
                        )
                            .frame(width: 342, height: max(410, proxy.size.height - 184))
                            .position(inspectorPosition(in: proxy.size))
                            .transition(.move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .trailing)))
                    } else {
                        InspectorLauncher {
                            workspace.inspectorTab = $0
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.06)) {
                                inspectorVisible = true
                            }
                        }
                        .position(x: proxy.size.width - 28, y: proxy.size.height / 2)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }

                TopBar()
                    .frame(maxWidth: min(900, proxy.size.width - 48))
                    .position(x: proxy.size.width / 2, y: 40)

                if workspace.isProcessing {
                    ProcessingOverlay()
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        }
        .tint(EasyshopTheme.cyan)
        .foregroundStyle(EasyshopTheme.ink)
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: workspace.focusMode)
        .sheet(isPresented: $workspace.showResizeSheet) {
            ResizeSheet()
                .environmentObject(workspace)
        }
        .onOpenURL { workspace.open($0) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            workspace.importAsLayer(first)
            return true
        }
        .onExitCommand {
            if inspectorVisible {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { inspectorVisible = false }
            } else if workspace.selection != nil {
                workspace.clearSelection()
            }
        }
    }

    private func toolRailPosition(in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(34, toolRailX), max(34, size.width - 34)),
            y: min(max(104, size.height * toolRailY), max(104, size.height - 104))
        )
    }

    private func moveToolRail(_ translation: CGSize, in size: CGSize) {
        let origin = toolDragOrigin ?? toolRailPosition(in: size)
        toolDragOrigin = origin
        let next = CGPoint(
            x: min(max(34, origin.x + translation.width), max(34, size.width - 34)),
            y: min(max(104, origin.y + translation.height), max(104, size.height - 104))
        )
        toolRailX = next.x
        toolRailY = next.y / max(1, size.height)
    }

    private func finishToolRailDrag(_ translation: CGSize, in size: CGSize) {
        moveToolRail(translation, in: size)
        toolDragOrigin = nil
    }

    private func inspectorPosition(in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(183, size.width - inspectorRight), max(183, size.width - 183)),
            y: min(max(112, size.height * inspectorY), max(112, size.height - 112))
        )
    }

    private func moveInspector(_ translation: CGSize, in size: CGSize) {
        let origin = inspectorDragOrigin ?? inspectorPosition(in: size)
        inspectorDragOrigin = origin
        let next = CGPoint(
            x: min(max(183, origin.x + translation.width), max(183, size.width - 183)),
            y: min(max(112, origin.y + translation.height), max(112, size.height - 112))
        )
        inspectorRight = size.width - next.x
        inspectorY = next.y / max(1, size.height)
    }

    private func finishInspectorDrag(_ translation: CGSize, in size: CGSize) {
        moveInspector(translation, in: size)
        inspectorDragOrigin = nil
    }
}

private struct TopBar: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 10) {
                AppMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Easyshop")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("CREATE LIGHTLY")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(1.3)
                        .foregroundStyle(EasyshopTheme.cyan)
                }
            }
            .accessibilityElement(children: .combine)
            .padding(.trailing, 7)

            Capsule().fill(EasyshopTheme.line).frame(width: 1, height: 28)
            SymbolButton(symbol: "folder.fill", help: "Apri") { workspace.openPanel() }
            SymbolButton(symbol: "square.and.arrow.down.fill", help: "Salva progetto") { workspace.save() }

            Spacer(minLength: 10)
            if workspace.hasImage {
                HStack(spacing: 9) {
                    ZStack {
                        Circle().fill(EasyshopTheme.lime.opacity(0.16))
                        Circle().fill(EasyshopTheme.lime).frame(width: 6, height: 6)
                    }
                    .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.document.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        Text("\(workspace.document.width) × \(workspace.document.height)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(EasyshopTheme.secondaryInk)
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 38)
                .background(Color.black.opacity(0.24), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.09)))
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 10)

            SymbolButton(symbol: "arrow.uturn.backward", help: "Annulla") { workspace.undo() }
            SymbolButton(symbol: "arrow.uturn.forward", help: "Ripeti") { workspace.redo() }
            SymbolButton(
                symbol: workspace.compareBefore ? "circle.lefthalf.filled.inverse" : "circle.lefthalf.filled",
                help: "Prima / dopo",
                active: workspace.compareBefore
            ) {
                workspace.compareBefore.toggle()
                workspace.touch(workspace.compareBefore ? "Vista originale" : "Vista modificata")
            }
            Button {
                workspace.exportPanel()
            } label: {
                Label("Esporta", systemImage: "arrow.up.forward")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!workspace.hasImage)
            .accessibilityLabel("Esporta immagine")
        }
        .padding(.horizontal, 11)
        .frame(height: 60)
        .floatingCapsule()
    }
}

private struct AppMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.08))
            Circle()
                .stroke(EasyshopTheme.aurora, lineWidth: 2.5)
                .padding(2)
            Circle()
                .fill(EasyshopTheme.gradient)
                .padding(6)
            SafeSymbol(name: "square.3.layers.3d.top.filled", fallback: "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color.white)
        }
        .frame(width: 38, height: 38)
        .shadow(color: EasyshopTheme.cyan.opacity(0.24), radius: 8)
        .accessibilityHidden(true)
    }
}

private struct ToolRail: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @State private var hoveredTool: EditorTool?
    @State private var expanded = false
    @State private var pinned = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onDrag: (CGSize) -> Void
    var onDragEnded: (CGSize) -> Void

    var body: some View {
        Group {
            if expanded {
                expandedRail
                    .transition(.scale(scale: 0.92, anchor: .leading).combined(with: .opacity))
            } else {
                collapsedHandle
                    .transition(.scale(scale: 0.92, anchor: .leading).combined(with: .opacity))
            }
        }
        .onHover { inside in
            if inside {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { expanded = true }
            } else if !pinned {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded = false }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: expanded)
    }

    private var expandedRail: some View {
        VStack(spacing: 6) {
            HStack(spacing: 1) {
                Button {
                    pinned.toggle()
                    if !pinned { expanded = false }
                } label: {
                    SafeSymbol(name: pinned ? "pin.fill" : "chevron.left", fallback: "chevron.left")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(pinned ? EasyshopTheme.cyan : EasyshopTheme.secondaryInk)
                        .frame(width: 25, height: 24)
                }
                .buttonStyle(.plain)
                .help(pinned ? "Rilascia strumenti" : "Nascondi strumenti")
                .accessibilityLabel(pinned ? "Rilascia strumenti" : "Nascondi strumenti")

                SafeSymbol(name: "circle.grid.2x2.fill", fallback: "circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(EasyshopTheme.secondaryInk)
                    .frame(width: 25, height: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { pinned = true; onDrag($0.translation) }
                            .onEnded { onDragEnded($0.translation) }
                    )
                    .help("Trascina la palette")
                    .accessibilityLabel("Maniglia per spostare la palette")
            }

            ForEach(EditorTool.allCases) { tool in
                DockToolButton(
                    tool: tool,
                    active: workspace.activeTool == tool,
                    showLabel: hoveredTool == tool
                ) {
                    workspace.activeTool = tool
                    if tool == .smart {
                        // One click creates a selection. A later click on the
                        // photograph can still target a specific instance.
                        workspace.selectSubject()
                    }
                }
                .onHover { inside in
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.16)) {
                        hoveredTool = inside ? tool : nil
                    }
                }
            }

            Capsule().fill(EasyshopTheme.line).frame(width: 34, height: 1).padding(.vertical, 2)
            SymbolButton(symbol: "slider.horizontal.3", help: "Nuova regolazione") {
                workspace.addAdjustmentLayer()
            }
            SymbolButton(symbol: "theatermasks.fill", help: "Applica come maschera") {
                workspace.applyCurrentSelectionAsMask()
            }
            SymbolButton(symbol: "xmark.circle", help: "Deseleziona") {
                workspace.clearSelection()
            }

            Capsule().fill(EasyshopTheme.line).frame(width: 34, height: 1).padding(.vertical, 2)
            SymbolButton(symbol: "wand.and.stars", help: "Miglioramento rapido") {
                workspace.autoEnhance()
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 8)
        .frame(width: 62)
        .glassPanel(radius: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Strumenti di modifica")
    }

    private var collapsedHandle: some View {
        HStack(spacing: 0) {
            Button {
                pinned = true
                expanded = true
                if workspace.activeTool == .smart {
                    workspace.selectSubject()
                }
            } label: {
                VStack(spacing: 7) {
                    SafeSymbol(name: workspace.activeTool.symbol, fallback: "cursorarrow")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white)
                    Circle()
                        .fill(EasyshopTheme.cyan)
                        .frame(width: 5, height: 5)
                        .shadow(color: EasyshopTheme.cyan.opacity(0.55), radius: 4)
                }
                .frame(width: 40, height: 55)
                .background(EasyshopTheme.gradient.opacity(0.22), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Apri strumenti · \(workspace.activeTool.rawValue)")
            .accessibilityLabel("Apri strumenti. Strumento attivo: \(workspace.activeTool.rawValue)")

            SafeSymbol(name: "circle.grid.2x2.fill", fallback: "circle.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(EasyshopTheme.secondaryInk)
                .frame(width: 15, height: 55)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { onDrag($0.translation) }
                        .onEnded { onDragEnded($0.translation) }
                )
                .help("Trascina la palette")
        }
        .glassPanel(radius: 17)
    }
}

/// A three-button edge island keeps the inspector one click away while giving
/// the photograph the whole stage when the user is not tuning parameters.
private struct InspectorLauncher: View {
    var open: (Int) -> Void

    var body: some View {
        VStack(spacing: 5) {
            edgeButton("square.3.layers.3d.top.filled", label: "Livelli", tab: 0)
            edgeButton("slider.horizontal.3", label: "Proprietà", tab: 1)
            edgeButton("sparkles", label: "AI", tab: 2)
        }
        .padding(7)
        .glassPanel(radius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Apri pannelli")
    }

    private func edgeButton(_ symbol: String, label: String, tab: Int) -> some View {
        Button { open(tab) } label: {
            SafeSymbol(name: symbol, fallback: "circle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 35, height: 35)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel("Apri \(label)")
    }
}

private struct DockToolButton: View {
    let tool: EditorTool
    let active: Bool
    let showLabel: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SafeSymbol(name: tool.symbol, fallback: fallbackSymbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(active ? Color.white : EasyshopTheme.ink)
                    .frame(width: 40, height: 40)
                    .background(active ? AnyShapeStyle(EasyshopTheme.gradient) : AnyShapeStyle(Color.white.opacity(showLabel ? 0.14 : 0.075)), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(active ? Color.white.opacity(0.34) : Color.white.opacity(showLabel ? 0.24 : 0.10), lineWidth: 1)
                    }
                    .shadow(color: active ? EasyshopTheme.cyan.opacity(0.30) : .clear, radius: 9)
                if showLabel {
                    Text(tool.rawValue)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                        .fixedSize()
                        .padding(.trailing, 14)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.vertical, 2)
            .background(showLabel ? AnyShapeStyle(Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.98)) : AnyShapeStyle(Color.clear), in: Capsule())
            .overlay {
                if showLabel {
                    Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 42, height: 44, alignment: .leading)
        .zIndex(showLabel ? 10 : 0)
        .help(tool.rawValue)
        .accessibilityLabel(tool.rawValue)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var fallbackSymbol: String {
        switch tool {
        case .move: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .lasso: "pencil.tip"
        case .smart: "wand.and.stars"
        case .brushAdd: "paintbrush.fill"
        case .brushSubtract: "minus.circle.fill"
        case .text: "textformat"
        }
    }
}

private struct ProcessingOverlay: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(EasyshopTheme.aurora, lineWidth: 3)
                    .frame(width: 50, height: 50)
                    .scaleEffect(breathe ? 1.08 : 0.88)
                    .opacity(breathe ? 0.4 : 1)
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(EasyshopTheme.gradient)
            }
            Text(workspace.processingLabel)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
            Text("Risultato non distruttivo · livello o maschera separati")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(EasyshopTheme.secondaryInk)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .glassPanel(radius: 22)
        .onAppear {
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
