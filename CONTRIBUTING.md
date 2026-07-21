# Contribuire a Easyshop

Grazie per voler migliorare Easyshop.

## Prima di iniziare

1. Cerca una issue esistente o aprine una descrivendo problema e risultato atteso.
2. Mantieni ogni modifica focalizzata e non inserire dipendenze senza motivarne licenza, dimensione e impatto sulla privacy.
3. Le funzioni AI devono produrre livelli o maschere separati e funzionare localmente per impostazione predefinita.
4. Le nuove operazioni di file devono documentare chiaramente cosa viene preservato e cosa viene rasterizzato.

## Verifica

Esegui `Scripts/run-tests.sh` e `Scripts/build-app.sh`. Per modifiche grafiche verifica almeno: documento vuoto, importazione, livelli, testo, maschera, annulla/ripeti, ridimensionamento e esportazione PNG/PSD.

## Stile

- Swift 6 e macOS 14+.
- Nessun `force unwrap` nei percorsi che leggono file dell’utente.
- Nomi chiari e controlli accessibili.
- UI progressiva: mostrare un’opzione soltanto nel contesto in cui serve.
