import SwiftUI

@MainActor
final class EasyshopApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: EditorWorkspace?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace?.synchronizeRecoveryBeforeClosing() != false else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Il recupero non è stato salvato"
            alert.informativeText = "Per evitare di perdere le ultime modifiche, Easyshop consiglia di annullare l’uscita e salvare il progetto."
            alert.addButton(withTitle: "Annulla uscita")
            alert.addButton(withTitle: "Esci comunque")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct EasyshopApp: App {
    @NSApplicationDelegateAdaptor(EasyshopApplicationDelegate.self) private var appDelegate
    @StateObject private var workspace = EditorWorkspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.workspace = workspace }
                .onDisappear { workspace.synchronizeRecoveryBeforeClosing() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuovo documento") { workspace.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Apri…") { workspace.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Salva progetto") { workspace.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Salva progetto con nome…") { workspace.saveAsPanel() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Esporta…") { workspace.exportPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Annulla") { workspace.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Ripeti") { workspace.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Livello") {
                Button("Nuovo livello testo") { workspace.addTextLayer() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Nuovo livello regolazione") { workspace.addAdjustmentLayer() }
                Button("Duplica livello") { workspace.duplicateSelectedLayer() }
                    .keyboardShortcut("j", modifiers: .command)
                Button("Elimina livello") { workspace.deleteSelectedLayer() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandMenu("Soggetto") {
                Button("Seleziona soggetto") { workspace.selectSubject() }
                Button("Rimuovi sfondo") { workspace.removeBackground() }
                Button("Separa soggetto e sfondo") { workspace.separateSubjectAndBackground() }
                Divider()
                Button("Correggi volto · Vision ML") { workspace.localizedCorrection(.face) }
                Button("Correggi soggetto") { workspace.localizedCorrection(.subject) }
            }
            CommandMenu("Strumenti locali") {
                Button("Miglioramento rapido · non AI") { workspace.autoEnhance() }
                Button("Correggi cielo · euristico") { workspace.localizedCorrection(.sky) }
                Divider()
                Button("Upscale preciso 2× · Lanczos") { workspace.upscale() }
                Button("Restauro rapido · non AI") { workspace.restore() }
            }
            CommandMenu("Immagine") {
                Button("Ridimensiona immagine o quadro…") { workspace.showResizeSheet = true }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Ritaglia alla selezione") { workspace.cropToSelection() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
            CommandMenu("Vista") {
                Toggle("Modalità Focus", isOn: $workspace.focusMode)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Toggle("Confronta prima/dopo", isOn: $workspace.compareBefore)
                    .keyboardShortcut("\\", modifiers: .command)
            }
        }
    }
}
