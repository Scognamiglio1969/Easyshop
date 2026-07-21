import SwiftUI

struct ResizeSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case image = "Immagine"
        case canvas = "Quadro"
        var id: String { rawValue }
    }

    enum UnitMode: String, CaseIterable, Identifiable {
        case pixels = "Pixel"
        case percent = "Percentuale"
        case centimeters = "Centimetri"
        case inches = "Pollici"
        var id: String { rawValue }
    }

    private enum DimensionField: Hashable { case width, height }

    @EnvironmentObject private var workspace: EditorWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .image
    @State private var unit: UnitMode = .pixels
    @State private var width = "1600"
    @State private var height = "1000"
    @State private var percent = 100.0
    @State private var dpi = "72"
    @State private var lockRatio = true
    @State private var method: ResizeMethod = .lanczos
    @State private var anchor: CanvasAnchor = .center
    @FocusState private var focusedDimension: DimensionField?

    private let presets: [(String, Int, Int)] = [
        ("Quadrato", 1080, 1080),
        ("Post", 1080, 1350),
        ("Story", 1080, 1920),
        ("Full HD", 1920, 1080),
        ("4K", 3840, 2160),
        ("A4 · 300 dpi", 2480, 3508)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dimensioni")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Ridimensiona senza perdere il controllo dei livelli.")
                        .font(.system(size: 11))
                        .foregroundStyle(EasyshopTheme.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 19)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(EasyshopTheme.muted)
            }
            .padding(20)

            Picker("Tipo", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if mode == .image { imageControls } else { canvasControls }
                    presetGrid
                }
                .padding(20)
            }

            Divider().overlay(EasyshopTheme.line)
            HStack {
                if workspace.selection != nil {
                    Button("Ritaglia alla selezione") {
                        workspace.cropToSelection()
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Annulla") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button(mode == .image ? "Ridimensiona" : "Applica quadro") { apply() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(16)
        }
        .frame(width: 520, height: 610)
        .background(EasyshopTheme.background)
        .onAppear {
            width = String(workspace.document.width)
            height = String(workspace.document.height)
            dpi = String(Int(workspace.document.dpi))
        }
    }

    private var imageControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("UNITÀ").sectionLabel()
                Spacer()
                Picker("Unità", selection: $unit) {
                    ForEach(UnitMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: unit) { _, newValue in convertDisplayedDimensions(to: newValue) }
            }
            if unit == .percent {
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text("Scala"); Spacer(); Text("\(Int(percent))% ").monospacedDigit().foregroundStyle(EasyshopTheme.muted) }
                    Slider(value: $percent, in: 5...800, step: 1)
                }
            } else {
                dimensionFields
                Toggle("Mantieni proporzioni", isOn: $lockRatio)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RISOLUZIONE").sectionLabel()
                    HStack {
                        TextField("72", text: $dpi).textFieldStyle(.roundedBorder)
                        Text("dpi").foregroundStyle(EasyshopTheme.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("RICAMPIONAMENTO").sectionLabel()
                    Picker("Metodo", selection: $method) {
                        ForEach(ResizeMethod.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    private var canvasControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            dimensionFields
            Text("ANCORAGGIO").sectionLabel()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 3), spacing: 6) {
                ForEach(CanvasAnchor.allCases) { item in
                    Button {
                        anchor = item
                    } label: {
                        Circle()
                            .fill(anchor == item ? AnyShapeStyle(EasyshopTheme.gradient) : AnyShapeStyle(Color.white.opacity(0.09)))
                            .frame(width: 9, height: 9)
                            .frame(width: 34, height: 30)
                            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            Text("Il punto scelto resta fermo mentre il quadro cresce o viene ritagliato.")
                .font(.system(size: 10))
                .foregroundStyle(EasyshopTheme.muted)
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    private var dimensionFields: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LARGHEZZA").sectionLabel()
                HStack {
                    TextField("1600", text: $width)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedDimension, equals: .width)
                        .onChange(of: width) { _, value in syncRatio(fromWidth: value) }
                    Text(unitSuffix).foregroundStyle(EasyshopTheme.muted)
                }
            }
            Image(systemName: lockRatio && mode == .image ? "link" : "link.badge.plus")
                .foregroundStyle(lockRatio && mode == .image ? EasyshopTheme.cyan : EasyshopTheme.muted)
            VStack(alignment: .leading, spacing: 6) {
                Text("ALTEZZA").sectionLabel()
                HStack {
                    TextField("1000", text: $height)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedDimension, equals: .height)
                        .onChange(of: height) { _, value in syncRatio(fromHeight: value) }
                    Text(unitSuffix).foregroundStyle(EasyshopTheme.muted)
                }
            }
        }
    }

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("PRESET VELOCI").sectionLabel()
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(presets, id: \.0) { preset in
                    Button {
                        width = String(preset.1)
                        height = String(preset.2)
                        if preset.0.contains("A4") { dpi = "300" }
                        unit = .pixels
                        focusedDimension = nil
                    } label: {
                        VStack(spacing: 3) {
                            Text(preset.0).font(.system(size: 11, weight: .semibold))
                            Text("\(preset.1) × \(preset.2)").font(.system(size: 9)).foregroundStyle(EasyshopTheme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button("Adatta entro 2048 px") {
                    let size = ResizeEngine.fitSize(width: workspace.document.width, height: workspace.document.height, maxWidth: 2048, maxHeight: 2048)
                    width = String(size.0); height = String(size.1); unit = .pixels
                }
                Button("50%") { percent = 50; unit = .percent }
                Button("200%") { percent = 200; unit = .percent }
            }
            .buttonStyle(.link)
            .font(.system(size: 10, weight: .medium))
        }
    }

    private func apply() {
        let targetWidth: Int
        let targetHeight: Int
        if mode == .image && unit == .percent {
            targetWidth = max(1, Int(Double(workspace.document.width) * percent / 100))
            targetHeight = max(1, Int(Double(workspace.document.height) * percent / 100))
        } else if unit == .centimeters || unit == .inches {
            let resolution = min(2400, max(1, Double(dpi) ?? workspace.document.dpi))
            let multiplier = unit == .centimeters ? resolution / 2.54 : resolution
            targetWidth = max(1, Int(((Double(width) ?? 0) * multiplier).rounded()))
            targetHeight = max(1, Int(((Double(height) ?? 0) * multiplier).rounded()))
        } else {
            targetWidth = max(1, Int(Double(width) ?? Double(workspace.document.width)))
            if mode == .image && lockRatio {
                targetHeight = max(1, Int(Double(height) ?? Double(workspace.document.height)))
            } else {
                targetHeight = max(1, Int(Double(height) ?? Double(workspace.document.height)))
            }
        }
        if mode == .image {
            workspace.resizeImage(width: targetWidth, height: targetHeight, dpi: Double(dpi) ?? workspace.document.dpi, method: method)
        } else {
            workspace.resizeCanvas(width: targetWidth, height: targetHeight, anchor: anchor)
        }
        dismiss()
    }

    private var unitSuffix: String {
        switch unit {
        case .pixels, .percent: "px"
        case .centimeters: "cm"
        case .inches: "in"
        }
    }

    private func syncRatio(fromWidth value: String) {
        guard mode == .image, lockRatio, focusedDimension == .width,
              let number = Double(value), number > 0 else { return }
        let ratio = Double(workspace.document.height) / Double(max(1, workspace.document.width))
        height = formattedDimension(number * ratio)
    }

    private func syncRatio(fromHeight value: String) {
        guard mode == .image, lockRatio, focusedDimension == .height,
              let number = Double(value), number > 0 else { return }
        let ratio = Double(workspace.document.width) / Double(max(1, workspace.document.height))
        width = formattedDimension(number * ratio)
    }

    private func convertDisplayedDimensions(to newUnit: UnitMode) {
        focusedDimension = nil
        let resolution = min(2400, max(1, Double(dpi) ?? workspace.document.dpi))
        switch newUnit {
        case .pixels, .percent:
            width = String(workspace.document.width)
            height = String(workspace.document.height)
        case .centimeters:
            width = formattedDimension(Double(workspace.document.width) / resolution * 2.54)
            height = formattedDimension(Double(workspace.document.height) / resolution * 2.54)
        case .inches:
            width = formattedDimension(Double(workspace.document.width) / resolution)
            height = formattedDimension(Double(workspace.document.height) / resolution)
        }
    }

    private func formattedDimension(_ value: Double) -> String {
        if unit == .pixels || unit == .percent { return String(max(1, Int(value.rounded()))) }
        return String(format: "%.2f", value)
    }
}

private extension View {
    func sectionLabel() -> some View {
        self.font(.system(size: 9, weight: .bold)).foregroundStyle(EasyshopTheme.muted).tracking(0.7)
    }
}
