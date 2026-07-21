# Architettura

Easyshop è un’app macOS nativa SwiftUI/AppKit con rendering Core Image.

## Flusso principale

1. `ProjectIO` importa una sorgente in uno o più `EditorLayer`.
2. `EditorDocument` conserva ordine, testo, maschere, trasformazioni e regolazioni.
3. `RenderEngine` compone dal basso verso l’alto e applica le regolazioni soltanto al composito sottostante.
4. `AIEngine` restituisce dati immagine o maschere; `EditorWorkspace` li inserisce come nuovi livelli.
5. Il progetto `.easyshop` serializza il documento in JSON portabile con immagini PNG incorporate.
6. `PSDWriter` crea un PSD 8-bit con anteprima composita e livelli raster per l’interoperabilità.

## Principi

- Non distruttivo per impostazione predefinita.
- Offline-first.
- Nessun formato viene dichiarato “senza perdite” quando non può conservare i concetti del documento.
- Dipendenze esterne opzionali e isolate.
- UI guidata dal contesto, non dalla quantità di funzioni.

## Motore AI

Vision gestisce segmentazione foreground e rilevamento volto. Le regolazioni localizzate vengono salvate come adjustment layer con maschera. L’interfaccia `AIEngine` permette di sostituire i fallback locali con modelli Core ML scaricabili, mantenendo invariati documento e UI.
