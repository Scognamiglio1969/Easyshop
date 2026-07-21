import SwiftUI

struct InspectorPanel: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    var onClose: () -> Void = {}
    var onDrag: (CGSize) -> Void = { _ in }
    var onDragEnded: (CGSize) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(EasyshopTheme.gradient.opacity(0.18))
                    SafeSymbol(name: panelSymbol, fallback: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(EasyshopTheme.cyan)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(panelTitle)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text(panelSubtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(EasyshopTheme.secondaryInk)
                        .lineLimit(1)
                }
                Spacer()
                SafeSymbol(name: "circle.grid.2x2.fill", fallback: "circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(EasyshopTheme.secondaryInk)
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { onDrag($0.translation) }
                            .onEnded { onDragEnded($0.translation) }
                    )
                    .help("Trascina il pannello")
                    .accessibilityLabel("Maniglia per spostare il pannello")
                SymbolButton(symbol: "xmark", help: "Chiudi pannello", action: onClose)
            }
            .padding(.horizontal, 13)
            .padding(.top, 12)
            .padding(.bottom, 9)

            HStack(spacing: 6) {
                PanelTab(symbol: "square.3.layers.3d.top.filled", label: "Livelli", value: 0)
                PanelTab(symbol: "slider.horizontal.3", label: "Regola", value: 1)
                PanelTab(symbol: "sparkles", label: "AI", value: 2)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 11)

            Divider().overlay(EasyshopTheme.line)
            Group {
                switch workspace.inspectorTab {
                case 0: LayersPanel()
                case 1: PropertiesPanel()
                default: ActionsPanel()
                }
            }
        }
        .glassPanel(radius: 22)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pannello \(panelTitle)")
    }

    private var panelTitle: String {
        switch workspace.inspectorTab {
        case 0: "Livelli"
        case 1: "Regolazioni"
        default: "AI e azioni"
        }
    }

    private var panelSubtitle: String {
        switch workspace.inspectorTab {
        case 0: "Composizione non distruttiva"
        case 1: workspace.document.selectedLayer?.name ?? "Seleziona un livello"
        default: "Vision ML e strumenti locali separati"
        }
    }

    private var panelSymbol: String {
        switch workspace.inspectorTab {
        case 0: "square.3.layers.3d.top.filled"
        case 1: "slider.horizontal.3"
        default: "sparkles"
        }
    }
}

private struct PanelTab: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    var symbol: String
    var label: String
    var value: Int

    private var active: Bool { workspace.inspectorTab == value }

    var body: some View {
        Button { workspace.inspectorTab = value } label: {
            HStack(spacing: 6) {
                SafeSymbol(name: symbol, fallback: "circle.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundStyle(active ? Color.white : EasyshopTheme.secondaryInk)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(active ? AnyShapeStyle(EasyshopTheme.gradient) : AnyShapeStyle(Color.white.opacity(0.065)), in: Capsule())
            .overlay(Capsule().stroke(active ? Color.white.opacity(0.28) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct LayersPanel: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(workspace.document.layers.enumerated().reversed()), id: \.element.id) { _, layer in
                        LayerRow(layer: layer, selected: workspace.document.selectedLayerID == layer.id) {
                            workspace.document.selectedLayerID = layer.id
                            workspace.touch()
                        }
                    }
                }
                .padding(12)
            }
            Divider().overlay(EasyshopTheme.line)
            HStack(spacing: 5) {
                SymbolButton(symbol: "plus.square.on.square.fill", help: "Duplica") { workspace.duplicateSelectedLayer() }
                SymbolButton(symbol: "textformat", help: "Testo") { workspace.addTextLayer() }
                SymbolButton(symbol: "slider.horizontal.3", help: "Regolazione") { workspace.addAdjustmentLayer() }
                Spacer()
                SymbolButton(symbol: "arrow.down.circle", help: "Abbassa") { workspace.moveSelectedLayer(by: -1) }
                SymbolButton(symbol: "arrow.up.circle", help: "Alza") { workspace.moveSelectedLayer(by: 1) }
                SymbolButton(symbol: "trash.fill", help: "Elimina") { workspace.deleteSelectedLayer() }
            }
            .padding(10)
        }
    }
}

private struct LayerRow: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @ObservedObject var layer: EditorLayer
    var selected: Bool
    var select: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            visibilityButton
            kindBadge
            layerDescription
            Spacer()
            if layer.isLocked {
                Image(systemName: "lock.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(EasyshopTheme.secondaryInk)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 54)
        .background(selected ? EasyshopTheme.violet.opacity(0.18) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(selected ? EasyshopTheme.cyan.opacity(0.68) : Color.white.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(layer.name), \(layer.kind.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var visibilityButton: some View {
        let label = layer.isVisible ? "Nascondi \(layer.name)" : "Mostra \(layer.name)"
        return Button {
            workspace.checkpoint("Visibilità livello")
            layer.isVisible.toggle()
            workspace.touch(layer.isVisible ? "Livello visibile" : "Livello nascosto")
        } label: {
            Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(layer.isVisible ? Color.white : EasyshopTheme.secondaryInk)
                .frame(width: 24, height: 32)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var kindBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(layer.kind == .adjustment ? AnyShapeStyle(EasyshopTheme.gradient.opacity(0.18)) : AnyShapeStyle(Color.white.opacity(0.08)))
            SafeSymbol(name: layer.kind.symbol, fallback: "square.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(layer.kind == .adjustment ? EasyshopTheme.cyan : Color.white)
        }
        .frame(width: 38, height: 34)
    }

    private var layerDescription: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(layer.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(layer.kind.label)
                if layer.maskData != nil {
                    Text("• Maschera").foregroundStyle(EasyshopTheme.cyan)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(EasyshopTheme.secondaryInk)
        }
    }
}

private struct PropertiesPanel: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        Group {
            if let layer = workspace.document.selectedLayer {
                LayerProperties(layer: layer)
            } else {
                ContentUnavailableView("Nessun livello", systemImage: "square.3.layers.3d", description: Text("Seleziona un livello per modificarlo."))
            }
        }
    }
}

private struct LayerProperties: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @ObservedObject var layer: EditorLayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorSection("Livello") {
                    TextField("Nome", text: binding(\.name))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .disabled(layer.isLocked)
                        .onTapGesture { workspace.checkpoint("Rinomina livello") }
                    LabeledSlider(
                        title: "Opacità",
                        value: binding(\.opacity),
                        range: 0...1,
                        format: { "\(Int($0 * 100))%" },
                        onEditingChanged: { if $0 { workspace.checkpoint("Modifica opacità") } }
                    )
                        .disabled(layer.isLocked)
                    Picker("Fusione", selection: binding(\.blendMode)) {
                        ForEach(BlendMode.allCases) { Text($0.label).tag($0) }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .onTapGesture { workspace.checkpoint("Modalità di fusione") }
                    Toggle(isOn: binding(\.isLocked)) {
                        Label(layer.isLocked ? "Livello protetto" : "Proteggi livello", systemImage: layer.isLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }
                    .onTapGesture { workspace.checkpoint("Protezione livello") }
                }

                Group {
                    if layer.kind == .text {
                        TextInspector(layer: layer)
                    } else if layer.kind == .adjustment {
                        AdjustmentInspector(layer: layer)
                    } else {
                        TransformInspector(layer: layer)
                    }
                }
                .disabled(layer.isLocked)
                .opacity(layer.isLocked ? 0.46 : 1)

                if layer.maskData != nil {
                    InspectorSection("Maschera") {
                        HStack {
                            Label("Maschera applicata", systemImage: "rectangle.portrait.on.rectangle.portrait")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Button("Rimuovi") {
                                layer.maskData = nil
                                workspace.touch("Maschera rimossa")
                            }
                            .buttonStyle(.link)
                            .disabled(layer.isLocked)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<EditorLayer, T>) -> Binding<T> {
        Binding(
            get: { layer[keyPath: keyPath] },
            set: {
                layer[keyPath: keyPath] = $0
                workspace.touch()
            }
        )
    }
}

private struct TextInspector: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @ObservedObject var layer: EditorLayer

    var body: some View {
        InspectorSection("Testo") {
            TextEditor(text: textBinding(\.content))
                .font(.system(size: 13))
                .foregroundStyle(Color.white)
                .frame(minHeight: 66)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .onTapGesture { workspace.checkpoint("Modifica testo") }
            TextField("Font", text: textBinding(\.fontName))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .onTapGesture { workspace.checkpoint("Cambia font") }
            LabeledSlider(title: "Dimensione", value: textBinding(\.fontSize), range: 8...240, format: { "\(Int($0)) px" }, onEditingChanged: history("Dimensione testo"))
            LabeledSlider(title: "Spaziatura", value: textBinding(\.tracking), range: -4...30, format: { String(format: "%.1f", $0) }, onEditingChanged: history("Spaziatura testo"))
            ColorPicker("Colore", selection: colorBinding, supportsOpacity: true)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .onTapGesture { workspace.checkpoint("Colore testo") }
        }
        InspectorSection("Posizione") {
            LabeledSlider(title: "X", value: transformBinding(\.x), range: 0...Double(workspace.document.width), format: { "\(Int($0))" }, onEditingChanged: history("Posizione testo"))
            LabeledSlider(title: "Y", value: transformBinding(\.y), range: 0...Double(workspace.document.height), format: { "\(Int($0))" }, onEditingChanged: history("Posizione testo"))
            LabeledSlider(title: "Rotazione", value: transformBinding(\.rotationDegrees), range: -180...180, format: { "\(Int($0))°" }, onEditingChanged: history("Rotazione testo"))
        }
    }

    private func textBinding<T>(_ keyPath: WritableKeyPath<TextSettings, T>) -> Binding<T> {
        Binding(
            get: { layer.text[keyPath: keyPath] },
            set: {
                var text = layer.text
                text[keyPath: keyPath] = $0
                layer.text = text
                workspace.touch()
            }
        )
    }

    private func transformBinding<T>(_ keyPath: WritableKeyPath<LayerTransform, T>) -> Binding<T> {
        Binding(
            get: { layer.transform[keyPath: keyPath] },
            set: {
                var transform = layer.transform
                transform[keyPath: keyPath] = $0
                layer.transform = transform
                workspace.touch()
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: layer.text.color.nsColor) },
            set: {
                var text = layer.text
                text.color = RGBAColor(NSColor($0))
                layer.text = text
                workspace.touch()
            }
        )
    }

    private func history(_ title: String) -> (Bool) -> Void {
        { editing in if editing { workspace.checkpoint(title) } }
    }
}

private struct AdjustmentInspector: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @ObservedObject var layer: EditorLayer

    var body: some View {
        InspectorSection("Luce") {
            adjustmentSlider("Esposizione", \.exposure, -3...3)
            adjustmentSlider("Luminosità", \.brightness, -1...1)
            adjustmentSlider("Contrasto", \.contrast, 0.25...2)
            adjustmentSlider("Luci", \.highlights, 0...1)
            adjustmentSlider("Ombre", \.shadows, -1...1)
            adjustmentSlider("Gamma", \.gamma, 0.2...3)
        }
        InspectorSection("Livelli e curve") {
            adjustmentSlider("Punto nero", \.blackPoint, 0...0.35)
            adjustmentSlider("Curve · Ombre", \.curveShadows, -0.25...0.25)
            adjustmentSlider("Curve · Mezzitoni", \.curveMidtones, -0.25...0.25)
            adjustmentSlider("Curve · Luci", \.curveHighlights, -0.25...0.25)
            adjustmentSlider("Punto bianco", \.whitePoint, 0.65...1)
        }
        InspectorSection("Colore") {
            adjustmentSlider("Saturazione", \.saturation, 0...2)
            adjustmentSlider("Vividezza", \.vibrance, -1...1)
            adjustmentSlider("Tonalità", \.hue, -180...180, suffix: "°")
            adjustmentSlider("Temperatura", \.temperature, -1800...1800)
            adjustmentSlider("Tinta", \.tint, -150...150)
        }
        InspectorSection("Bilanciamento canali") {
            adjustmentSlider("Rosso", \.redBalance, 0.5...1.5)
            adjustmentSlider("Verde", \.greenBalance, 0.5...1.5)
            adjustmentSlider("Blu", \.blueBalance, 0.5...1.5)
        }
        InspectorSection("Dettaglio") {
            adjustmentSlider("Chiarezza", \.clarity, 0...2)
            adjustmentSlider("Nitidezza", \.sharpness, 0...2)
            adjustmentSlider("Riduzione rumore", \.noiseReduction, 0...0.2)
        }
    }

    private func adjustmentSlider(_ title: String, _ keyPath: WritableKeyPath<AdjustmentSettings, Double>, _ range: ClosedRange<Double>, suffix: String = "") -> some View {
        LabeledSlider(
            title: title,
            value: Binding(
                get: { layer.adjustment[keyPath: keyPath] },
                set: {
                    var adjustment = layer.adjustment
                    adjustment[keyPath: keyPath] = $0
                    layer.adjustment = adjustment
                    workspace.touch()
                }
            ),
            range: range,
            format: { String(format: "%.2f", $0) + suffix },
            onEditingChanged: { if $0 { workspace.checkpoint("Regola \(title)") } }
        )
    }
}

private struct TransformInspector: View {
    @EnvironmentObject private var workspace: EditorWorkspace
    @ObservedObject var layer: EditorLayer

    var body: some View {
        InspectorSection("Trasformazione") {
            transformSlider("X", \.x, -Double(workspace.document.width)...Double(workspace.document.width))
            transformSlider("Y", \.y, -Double(workspace.document.height)...Double(workspace.document.height))
            transformSlider("Scala X", \.scaleX, 0.05...5)
            transformSlider("Scala Y", \.scaleY, 0.05...5)
            transformSlider("Rotazione", \.rotationDegrees, -180...180, suffix: "°")
        }
        if workspace.selection != nil {
            Button {
                workspace.applyCurrentSelectionAsMask()
            } label: {
                Label("Applica selezione come maschera", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func transformSlider(_ title: String, _ keyPath: WritableKeyPath<LayerTransform, Double>, _ range: ClosedRange<Double>, suffix: String = "") -> some View {
        LabeledSlider(
            title: title,
            value: Binding(
                get: { layer.transform[keyPath: keyPath] },
                set: {
                    var transform = layer.transform
                    transform[keyPath: keyPath] = $0
                    layer.transform = transform
                    workspace.touch()
                }
            ),
            range: range,
            format: { String(format: "%.2f", $0) + suffix },
            onEditingChanged: { if $0 { workspace.checkpoint("Trasforma livello") } }
        )
    }
}

private struct ActionsPanel: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("SOGGETTO · PROVENIENZA VISIBILE", systemImage: "sparkles")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(EasyshopTheme.gradient)
                    Text("Vision ML quando disponibile; il fallback locale non‑AI viene sempre dichiarato. Risultati su livelli o maschere separati.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(EasyshopTheme.secondaryInk)
                }
                AIAction(symbol: "person.crop.rectangle", title: "Seleziona soggetto", detail: "Vision ML o fallback non‑AI dichiarato") { workspace.selectSubject() }
                AIAction(symbol: "person.crop.rectangle.badge.minus", title: "Rimuovi sfondo", detail: "Provenienza dichiarata, livello separato") { workspace.removeBackground() }
                AIAction(symbol: "square.3.layers.3d", title: "Separa soggetto/sfondo", detail: "Provenienza dichiarata, due maschere inverse") { workspace.separateSubjectAndBackground() }
                AIAction(symbol: "face.smiling", title: "Correggi volto · ML", detail: "Vision rileva il volto; regolazione locale") { workspace.localizedCorrection(.face) }
                AIAction(symbol: "figure.stand", title: "Correggi soggetto", detail: "Vision ML o fallback non‑AI dichiarato") { workspace.localizedCorrection(.subject) }
                Divider().overlay(EasyshopTheme.line)
                Text("STRUMENTI LOCALI · NON AI")
                    .font(.system(size: 10, weight: .black))
                    .tracking(1.1)
                    .foregroundStyle(EasyshopTheme.secondaryInk)
                AIAction(symbol: "wand.and.stars", title: "Miglioramento rapido", detail: "Analisi statistica di luce e colore") { workspace.autoEnhance() }
                AIAction(symbol: "cloud.sun", title: "Correggi cielo", detail: "Maschera cromatica euristica") { workspace.localizedCorrection(.sky) }
                AIAction(symbol: "arrow.up.left.and.arrow.down.right", title: "Upscale preciso 2×", detail: "Ricampionamento Lanczos + nitidezza") { workspace.upscale() }
                AIAction(symbol: "photo.badge.checkmark", title: "Restauro rapido", detail: "Preset locale di rumore, contrasto e nitidezza") { workspace.restore() }
            }
            .padding(14)
        }
    }
}

private struct AIAction: View {
    var symbol: String
    var title: String
    var detail: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(hovered ? AnyShapeStyle(EasyshopTheme.gradient) : AnyShapeStyle(EasyshopTheme.gradient.opacity(0.17)))
                    Image(systemName: symbol)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(hovered ? Color.white : EasyshopTheme.cyan)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(EasyshopTheme.secondaryInk)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hovered ? EasyshopTheme.cyan : EasyshopTheme.secondaryInk)
            }
            .padding(10)
            .background(Color.white.opacity(hovered ? 0.095 : 0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(hovered ? 0.17 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel("\(title). \(detail)")
    }
}

private struct InspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(EasyshopTheme.secondaryInk)
                .tracking(1.0)
            content
        }
        .padding(13)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.065), Color.white.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.07)))
    }
}

private struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(EasyshopTheme.cyan)
            }
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .tint(EasyshopTheme.cyan)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
    }
}
