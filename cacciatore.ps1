# Cacciatore di errori di prezzo nei negozi Shopify.
# Legge solo dati pubblici (products.json), con calma, e avvisa quando un prezzo crolla.
#   .\cacciatore.ps1            controllo normale
#   .\cacciatore.ps1 -Prova     invia solo una notifica di prova
#   .\cacciatore.ps1 -Simula    finge che un prezzo sia crollato, per vedere un avviso vero
param([switch]$Prova, [switch]$Simula, [string]$Negozio)

$ErrorActionPreference = 'Stop'
$dir    = $PSScriptRoot
$cfg    = Get-Content (Join-Path $dir 'impostazioni.json') -Raw | ConvertFrom-Json
$negozi = Get-Content (Join-Path $dir 'negozi.txt') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
$archivio = Join-Path $dir 'prezzi'
New-Item -ItemType Directory -Force $archivio | Out-Null
$logFile = Join-Path $dir 'avvisi.log'
$EUR = [char]0x20AC

function Scrivi-Log($t) {
    $riga = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $t"
    Write-Output $riga
    for ($i = 0; $i -lt 10; $i++) {   # piu negozi scrivono insieme: riprova se il file e' occupato
        try { Add-Content $logFile $riga -Encoding UTF8 -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds (100 + (Get-Random -Maximum 300)) }
    }
}

function Notifica-PC($titolo, $testo, $url) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $e = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
        $xml = "<toast activationType=`"protocol`" launch=`"$(& $e $url)`" scenario=`"reminder`"><visual><binding template=`"ToastGeneric`"><text>$(& $e $titolo)</text><text>$(& $e $testo)</text></binding></visual><actions><action content=`"Apri il prodotto`" activationType=`"protocol`" arguments=`"$(& $e $url)`"/></actions><audio src=`"ms-winsoundevent:Notification.Reminder`"/></toast>"
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($doc))
    } catch { Scrivi-Log "Notifica PC non riuscita: $($_.Exception.Message)" }
}

function Notifica-Telegram($testo) {
    $f = Join-Path $dir 'telegram.dat'
    if (-not (Test-Path $f)) { return }
    try {
        $s = Get-Content $f | ConvertTo-SecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
        $tok, $chat = $plain -split '\|', 2
        Invoke-RestMethod "https://api.telegram.org/bot$tok/sendMessage" -Method Post -Body @{ chat_id = $chat; text = $testo } -TimeoutSec 20 | Out-Null
    } catch { Scrivi-Log "Telegram non riuscito: $($_.Exception.Message)" }
}

function Avvisa($negozio, $titolo, $vecchio, $nuovo, $motivo, $url) {
    $testo = "$titolo`n$vecchio $EUR -> $nuovo $EUR ($motivo)"
    Scrivi-Log "AVVISO [$negozio] $titolo : $vecchio -> $nuovo ($motivo) $url"
    Notifica-Telegram ("ERRORE DI PREZZO? - $negozio`n$testo`n$url")
}

if ($Prova) {
    Avvisa 'prova' 'Notifica di prova del Cacciatore' 100 10 'test' 'https://www.google.com'
    return
}

# Giro normale: lancia un processo per negozio, al massimo N insieme, e aspetta che finiscano tutti.
if (-not $Negozio -and -not $Simula) {
    $max = if ($cfg.negozi_in_parallelo) { [int]$cfg.negozi_in_parallelo } else { 6 }
    $attivi = @()
    foreach ($d in $negozi) {
        while (@($attivi | Where-Object { -not $_.HasExited }).Count -ge $max) { Start-Sleep -Milliseconds 500 }
        $attivi += Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Negozio $d" -WindowStyle Hidden -PassThru
    }
    $attivi | ForEach-Object { $_.WaitForExit() }
    if ((Get-Item $logFile).Length -gt 1MB) { Get-Content $logFile -Tail 3000 | Set-Content $logFile -Encoding UTF8 }
    return
}
if ($Negozio) { $negozi = @($Negozio) }

$crollo   = [double]$cfg.crollo_percento / 100
$maxPag   = [int]$cfg.max_pagine
$pausa    = [int]$cfg.pausa_secondi_tra_pagine
$avvisiTot = 0

foreach ($d in $negozi) {
    $file = Join-Path $archivio (($d -replace '[^\w\.-]', '_') + '.json')
    $vecchi = @{}
    if (Test-Path $file) {
        (Get-Content $file -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $vecchi[$_.Name] = $_.Value }
    }
    # stato della rotazione (per i negozi grandi si legge un blocco di pagine diverso a ogni giro)
    $statoFile = Join-Path $archivio (($d -replace '[^\w\.-]', '_') + '.stato.json')
    $stato = if (Test-Path $statoFile) { Get-Content $statoFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{ pagina = 1; ciclo_completo = $false } }
    # negozio "in pausa" dopo un 403/429: lo lasciamo riposare invece di insistere
    if ($stato.PSObject.Properties['pausa_fino'] -and [datetime]$stato.pausa_fino -gt (Get-Date)) { continue }
    $primaVolta = -not $stato.ciclo_completo
    $pgInizio = [int]$stato.pagina
    $finito = $false

    # 1. leggi i prodotti, pagina per pagina
    $nuovi = @{}
    try {
        for ($pg = $pgInizio; $pg -lt $pgInizio + $maxPag; $pg++) {
            $r = Invoke-RestMethod "https://$d/products.json?limit=250&page=$pg" -UserAgent 'Mozilla/5.0' -TimeoutSec 30
            if (-not $r.products -or $r.products.Count -eq 0) { $finito = $true; break }
            foreach ($p in $r.products) {
                foreach ($v in $p.variants) {
                    $nome = if ($v.title -and $v.title -ne 'Default Title') { "$($p.title) - $($v.title)" } else { $p.title }
                    $nuovi["$($v.id)"] = [pscustomobject]@{
                        p = [double]$v.price
                        c = if ($v.compare_at_price) { [double]$v.compare_at_price } else { 0 }
                        a = [bool]$v.available
                        t = $nome
                        u = "https://$d/products/$($p.handle)?variant=$($v.id)"
                    }
                }
            }
            if ($r.products.Count -lt 250) { $finito = $true; break }
            Start-Sleep $pausa
        }
    } catch {
        if ($pg -gt 1 -and $_.Exception.Message -match '\(400\)') {
            $finito = $true   # Shopify non va oltre un certo numero di pagine: ricomincia dalla prima
        } elseif ($_.Exception.Message -match '403|429|Forbidden|Too Many') {
            $stato | Add-Member -Force pausa_fino ((Get-Date).AddHours(6).ToString('s'))
            $stato | ConvertTo-Json | Out-File $statoFile -Encoding utf8
            Scrivi-Log "[$d] troppe richieste o accesso negato: negozio in pausa per 6 ore"
            continue
        } else {
            Scrivi-Log "[$d] lettura non riuscita: $($_.Exception.Message)"
            continue
        }
    }

    if ($Simula -and -not $primaVolta) {
        # finge che il primo prodotto disponibile prima costasse 10 volte tanto
        $k = ($nuovi.Keys | Where-Object { $nuovi[$_].a -and $vecchi.ContainsKey($_) } | Select-Object -First 1)
        if ($k) { $vecchi[$k].p = $nuovi[$k].p * 10; Scrivi-Log "[$d] SIMULAZIONE su: $($nuovi[$k].t)" }
    }

    # 2. confronta con la volta precedente
    $avvisiNegozio = 0
    foreach ($k in $nuovi.Keys) {
        $n = $nuovi[$k]
        if (-not $n.a -or $n.p -le 0) { continue }   # non disponibile o prezzo segnaposto 0,00
        $motivo = $null; $vecchio = $null
        if ($vecchi.ContainsKey($k)) {
            $o = $vecchi[$k]
            if ($o.p -gt 0 -and $o.p -lt 50000 -and $n.p -lt $o.p) {   # ignora prezzi segnaposto assurdi (es. 9999999)
                $rapp = $n.p / $o.p
                if ($rapp -ge 0.095 -and $rapp -le 0.105 -and $o.p -ge 20) { $motivo = 'sembra mancare uno zero' }
                elseif ($rapp -le (1 - $crollo)) { $motivo = "crollo del $([math]::Round((1 - $rapp) * 100))%" }
                elseif ($n.p -lt 1 -and $o.p -ge 10) { $motivo = 'prezzo quasi zero' }
                $vecchio = $o.p
            }
        } elseif (-not $primaVolta -and $n.c -gt 0 -and $n.p -le $n.c * (1 - $crollo)) {
            $motivo = "nuovo prodotto a -$([math]::Round((1 - $n.p / $n.c) * 100))% sul prezzo pieno"
            $vecchio = $n.c
        }
        if ($motivo -and $avvisiNegozio -lt [int]$cfg.max_avvisi_per_negozio) {
            Avvisa $d $n.t $vecchio $n.p $motivo $n.u
            $avvisiNegozio++; $avvisiTot++
        }
    }

    # 3. aggiorna la foto dei prezzi (unisce le pagine lette ora con quelle lette nei giri precedenti)
    if (-not $Simula) {
        foreach ($k in $nuovi.Keys) { $vecchi[$k] = $nuovi[$k] }
        $vecchi | ConvertTo-Json -Depth 3 -Compress | Out-File $file -Encoding utf8
        $stato.pagina = if ($finito) { 1 } else { $pgInizio + $maxPag }
        if ($finito) { $stato.ciclo_completo = $true }
        $stato | ConvertTo-Json | Out-File $statoFile -Encoding utf8
    }
    $disp = @($nuovi.Values | Where-Object a).Count
    $pagine = "pagine $pgInizio-$($pg)" + $(if ($finito) { ' (fine catalogo)' } else { '' })
    if ($primaVolta) { Scrivi-Log "[$d] prima lettura: $($nuovi.Count) prezzi ($disp disponibili), $pagine, totale in archivio $($vecchi.Count)" }
    else { Scrivi-Log "[$d] controllati $($nuovi.Count) prezzi ($disp disponibili), $pagine, avvisi: $avvisiNegozio" }
}

# tieni il log piccolo
if ((Get-Item $logFile).Length -gt 1MB) { Get-Content $logFile -Tail 3000 | Set-Content $logFile -Encoding UTF8 }
