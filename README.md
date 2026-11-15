# Cacciatore errori di prezzo

Monitor personale di prezzi: legge i cataloghi pubblici (`products.json`) di alcuni negozi Shopify,
con calma (poche pagine per volta, pause, 6 ore di riposo se un negozio chiede di rallentare),
e avvisa su Telegram quando un prezzo crolla improvvisamente.

- `cacciatore.ps1` – controllo dei prezzi (ogni 30 minuti)
- `scopri_negozi.ps1` – ricerca di nuovi negozi in euro
- `negozi.txt` – elenco dei negozi
