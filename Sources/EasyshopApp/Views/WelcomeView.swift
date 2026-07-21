import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var workspace: EditorWorkspace

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(EasyshopTheme.gradient)
                    .frame(width: 92, height: 92)
                    .shadow(color: EasyshopTheme.violet.opacity(0.38), radius: 26, y: 12)
                Image(systemName: "square.3.layers.3d.top.filled")
                    .font(.system(size: 40, weight: .bold))
            }
            VStack(spacing: 8) {
                Text("Crea senza attrito.")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Livelli, colore e Vision ML on-device in un editor progettato per lavori veloci.")
                    .font(.system(size: 15))
                    .foregroundStyle(EasyshopTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            HStack(spacing: 10) {
                Button("Apri immagine…") { workspace.openPanel() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Nuovo documento") { workspace.newDocument() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            HStack(spacing: 22) {
                FeatureChip(symbol: "square.3.layers.3d", title: "Livelli")
                FeatureChip(symbol: "slider.horizontal.3", title: "Colore")
                FeatureChip(symbol: "sparkles", title: "Vision ML locale")
                FeatureChip(symbol: "textformat", title: "Testo")
            }
        }
        .padding(50)
        .frame(maxWidth: 720)
        .glassPanel(radius: 28)
        .padding(40)
    }
}

private struct FeatureChip: View {
    var symbol: String
    var title: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(EasyshopTheme.cyan)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(EasyshopTheme.muted)
        }
    }
}
