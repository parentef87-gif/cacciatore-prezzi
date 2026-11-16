# Scopre da solo nuovi negozi Shopify in euro e li aggiunge al Cacciatore.
# Idea: i negozi che gia' sorvegliamo vendono tanti marchi; spesso quei marchi hanno
# un proprio negozio Shopify. Per ogni marchio prova gli indirizzi piu' probabili.
#   .\scopri_negozi.ps1               giro normale (max marchi_per_giro marchi nuovi)
#   .\scopri_negozi.ps1 -Marchi 50    prova solo 50 marchi
#   .\scopri_negozi.ps1 -Forza        parte subito, ignorando la frequenza programmata
# Frequenza: dal 16/11/2026 lavora a ogni giro (ogni ora; "scoperta_ogni_ore" in impostazioni.json per cambiarlo).
# I marchi gia' provati con gli indirizzi vecchi riprovano solo gli indirizzi nuovi (marchi_provati_v2.txt).
param([int]$Marchi = 0, [switch]$Forza)

$ErrorActionPreference = 'SilentlyContinue'
$dir      = $PSScriptRoot
$negFile  = Join-Path $dir 'negozi.txt'
New-Item -ItemType Directory -Force (Join-Path $dir 'prezzi') | Out-Null   # su GitHub la cartella puo' non esserci
$provati  = Join-Path $dir 'marchi_provati.txt'                          # nel repository (non nella cache), cosi' non si perde
$ultimo   = Join-Path $dir 'prezzi\scoperta_ultimo_giro.txt'
$logFile  = Join-Path $dir 'scoperte.log'
$cfg      = Get-Content (Join-Path $dir 'impostazioni.json') -Raw | ConvertFrom-Json
if (-not $Marchi) { $Marchi = if ($cfg.marchi_per_giro) { [int]$cfg.marchi_per_giro } else { 150 } }
$UA = 'Mozilla/5.0'

# --- decide se e' il momento di lavorare ---
$inizio = [datetime]$cfg.scoperta_inizio
$giorno = [math]::Floor(((Get-Date) - $inizio).TotalDays) + 1
# 16/11/2026: l'utente vuole piu' ricerca -> lavora a ogni giro (ogni ora), senza rallentare coi giorni
$ogniOre = if ($cfg.scoperta_ogni_ore) { [int]$cfg.scoperta_ogni_ore } else { 1 }
if (-not $Forza -and (Test-Path $ultimo)) {
    $last = [datetime](Get-Content $ultimo -Raw).Trim()
    if (((Get-Date) - $last).TotalMinutes -lt ($ogniOre * 60 - 10)) { return }
}
(Get-Date -Format 's') | Out-File $ultimo -Encoding ascii

function Scrivi($t) { $r = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $t"; Write-Output $r; Add-Content $logFile $r -Encoding UTF8 }
function Host-Base($h) { ($h.ToLower() -replace '^www\.', '').TrimEnd('/') }
function Esiste($h) { try { [System.Net.Dns]::GetHostAddresses($h).Count -gt 0 } catch { $false } }
function Telegram($testo) {
    $f = Join-Path $dir 'telegram_report.dat'             # bot "Report Cacciatore"
    if (-not (Test-Path $f)) { $f = Join-Path $dir 'telegram.dat' }
    if (-not (Test-Path $f)) { return }
    try {
        $s = Get-Content $f | ConvertTo-SecureString
        $tok, $chat = ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))) -split '\|', 2
        Invoke-RestMethod "https://api.telegram.org/bot$tok/sendMessage" -Method Post -Body @{ chat_id = $chat; text = $testo } -TimeoutSec 20 | Out-Null
    } catch { Scrivi "Telegram non riuscito: $($_.Exception.Message)" }
}

# negozi gia' presenti (anche quelli commentati/scartati, per non riprovarli)
$righe = Get-Content $negFile
$noti = @{}
foreach ($r in $righe) { $m = [regex]::Match($r, '([a-z0-9\-]+\.)+[a-z]{2,}'); if ($m.Success) { $noti[(Host-Base $m.Value)] = $true } }
$giaProvati = @{}
if (Test-Path $provati) { Get-Content $provati | ForEach-Object { $giaProvati[$_] = $true } }
# indirizzi "nuovi" (16/11/2026): i marchi gia' provati con quelli vecchi riprovano SOLO questi
$provati2 = Join-Path $dir 'marchi_provati_v2.txt'
$giaProvati2 = @{}
if (Test-Path $provati2) { Get-Content $provati2 | ForEach-Object { $giaProvati2[$_] = $true } }

# 1. raccogli i marchi dai negozi sorvegliati (tutti, prime 3 pagine)
$tuttiAttivi = @($righe | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
$attivi = $tuttiAttivi | Get-Random -Count ([math]::Min($tuttiAttivi.Count, $(if ($cfg.negozi_per_marchi) { [int]$cfg.negozi_per_marchi } else { 20 })))
$pagineMarchi = if ($cfg.pagine_per_marchi) { [int]$cfg.pagine_per_marchi } else { 1 }
$marche = @{}
foreach ($d in $attivi) {
    for ($pg = 1; $pg -le $pagineMarchi; $pg++) {
        try {
            $r = Invoke-RestMethod "https://$d/products.json?limit=250&page=$pg" -UserAgent $UA -TimeoutSec 15
            foreach ($p in $r.products) { if ($p.vendor) { $marche[$p.vendor.Trim()] = $true } }
            if (@($r.products).Count -lt 250) { break }
        } catch { break }
        Start-Sleep -Milliseconds 300
    }
}

# 2. trasforma i marchi in "nomi da indirizzo" e scegli quelli non ancora provati
$scarta = 'nike|adidas|jordan|new balance|puma|asics|converse|vans|reebok|salomon|apple|samsung|sony|lego|disney|pokemon|nintendo|microsoft|gift|default|test|sample|generic|unknown'
$daProvare = foreach ($v in $marche.Keys) {
    $norm = $v.ToLower().Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    $slug = $norm -replace '[^a-z0-9]', ''
    if ($slug.Length -lt 3 -or $slug.Length -gt 25 -or $norm -match $scarta -or ($giaProvati[$slug] -and $giaProvati2[$slug])) { continue }
    [pscustomobject]@{ Marchio = $v; Slug = $slug; Trattino = ($norm -replace '[^a-z0-9]+', '-').Trim('-'); SoloNuovi = [bool]$giaProvati[$slug] }
}
# prima i marchi mai provati, poi quelli da riprovare solo con gli indirizzi nuovi
$daProvare = @($daProvare | Sort-Object Slug -Unique | Sort-Object SoloNuovi | Select-Object -First $Marchi)
Scrivi "Marchi raccolti: $($marche.Count). Da provare in questo giro: $($daProvare.Count)"

# 3. prova gli indirizzi piu' probabili per ogni marchio
$trovati = @()
$orologio = [Diagnostics.Stopwatch]::StartNew()
foreach ($m in $daProvare) {
    if ($orologio.Elapsed.TotalMinutes -gt 38) { Scrivi "Tempo massimo raggiunto: gli altri marchi al prossimo giro"; break }
    $nomi = @($m.Slug); if ($m.Trattino -ne $m.Slug) { $nomi += $m.Trattino }
    $vecchi = foreach ($s in $nomi) { "$s.com", "eu.$s.com", "$s.it", "$s.eu", "$s.de", "$s.fr", "$s.es", "$s.nl", "shop$s.com", "$s" + 'store.com' }
    $nuovi  = foreach ($s in $nomi) { "$s.at", "$s.be", "$s.pt", "$s.ie", "$s.fi", "shop.$s.com", "store.$s.com", "eu.$s.co", "$s-shop.com", "$s" + 'official.com', "$s.co", "it.$s.com", "de.$s.com" }
    $indirizzi = if ($m.SoloNuovi) { $nuovi } else { @($vecchi) + @($nuovi) }
    foreach ($ind in $indirizzi) {
        if (-not (Esiste $ind)) { continue }   # il sito non esiste: non perdere tempo
        try {
            $resp = Invoke-WebRequest "https://$ind/products.json?limit=250" -UserAgent $UA -UseBasicParsing -TimeoutSec 8 -MaximumRedirection 5
            $hostFinale = $resp.BaseResponse.ResponseUri.Host
            $j = $resp.Content | ConvertFrom-Json
            $p = @($j.products)
            if ($p.Count -lt 5) { continue }
            $base = Host-Base $hostFinale
            if ($noti[$base]) { break }
            $cur = (Invoke-RestMethod "https://$hostFinale/cart.js" -UserAgent $UA -TimeoutSec 8).currency
            if ($cur -ne 'EUR') { $noti[$base] = $true; break }
            $v = @($p | ForEach-Object { $_.variants })
            if (@($v | Where-Object { [double]$_.price -ge 50000 }).Count -gt 0) { $noti[$base] = $true; break }
            $trovati += [pscustomobject]@{ Host = $hostFinale; Marchio = $m.Marchio; Prodotti = $p.Count }
            $noti[$base] = $true
            Scrivi "NUOVO NEGOZIO: $hostFinale (marchio $($m.Marchio), $($p.Count)+ prodotti)"
            break
        } catch {}
    }
    if (-not $m.SoloNuovi) { Add-Content $provati $m.Slug -Encoding UTF8 }
    Add-Content $provati2 $m.Slug -Encoding UTF8
}

# 4. aggiungi i nuovi negozi alla lista del Cacciatore
if ($trovati.Count) {
    $blocco = @('', "# ===== Trovati in automatico il $(Get-Date -Format 'dd/MM/yyyy HH:mm') =====") + ($trovati | ForEach-Object { $_.Host })
    $testo = (Get-Content $negFile -Raw).TrimEnd()
    $idx = $testo.IndexOf('# Scartati (valuta non in euro)')
    if ($idx -ge 0) { $testo = $testo.Substring(0, $idx).TrimEnd() + "`r`n" + ($blocco -join "`r`n") + "`r`n`r`n" + $testo.Substring($idx) }
    else { $testo = $testo + "`r`n" + ($blocco -join "`r`n") }
    Set-Content $negFile $testo -Encoding UTF8
}
$tot = (Get-Content $negFile | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count
Scrivi "Fine giro: trovati $($trovati.Count) negozi nuovi. Negozi totali nel Cacciatore: $tot"

# report su Telegram
$prossimo = (Get-Date).AddHours($ogniOre).ToString('dd/MM HH:mm')
$elenco = if ($trovati.Count) { "`n" + (($trovati | ForEach-Object { "+ $($_.Host)" }) -join "`n") } else { '' }
$restano = [math]::Max(0, ($marche.Count - (Get-Content $provati -ErrorAction SilentlyContinue).Count))
Telegram ("Ricerca negozi (giorno $giorno, ogni $ogniOre h)`n" +
          "Marchi provati: $($daProvare.Count) - ancora da provare: circa $restano`n" +
          "Negozi nuovi trovati: $($trovati.Count)$elenco`n" +
          "Negozi sorvegliati in totale: $tot`n" +
          "Prossima ricerca: $prossimo" +
          $(if ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
              "`n`nPROMEMORIA: Windows ha installato aggiornamenti e chiede un riavvio. Quando usi il PC riavvialo e poi rientra con il tuo utente, cosi' il Cacciatore riparte." } else { '' }))
