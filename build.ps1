# build.ps1 - V vs HL vs Lighter vs Trade.xyz
$ErrorActionPreference = "Stop"
$t0 = Get-Date
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  EXEC COST: V + HL + Lighter + Trade.xyz" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# 1. VARIATIONAL
Write-Host "`n[1/4] Variational..." -ForegroundColor Yellow
$vResp = Invoke-RestMethod -Uri 'https://omni-client-api.prod.ap-northeast-1.variational.io/metadata/stats' -TimeoutSec 20
$vMap = @{}
foreach ($i in $vResp.listings) {
    $b = 0; $a = 0
    if ($i.quotes.base) { $b = [double]$i.quotes.base.bid; $a = [double]$i.quotes.base.ask }
    $hs = 0
    if ($b -gt 0 -and $a -gt 0) { $hs = [math]::Round(($a - $b) / ($b + $a) * 100, 6) }
    $vMap[$i.ticker.ToUpper()] = @{ name = $i.ticker; halfSpread = $hs; bid = $b; ask = $a; vol = [double]$i.volume_24h; mark = [double]$i.mark_price; fee = 0; execCost = $hs }
}
Write-Host "  $($vMap.Count) tokens"

# 2. HYPERLIQUID
Write-Host "`n[2/4] Hyperliquid..." -ForegroundColor Yellow
$hlMeta = Invoke-RestMethod -Uri 'https://api.hyperliquid.xyz/info' -Method Post -Body '{"type":"meta"}' -ContentType 'application/json' -TimeoutSec 15
$hlMids = Invoke-RestMethod -Uri 'https://api.hyperliquid.xyz/info' -Method Post -Body '{"type":"allMids"}' -ContentType 'application/json' -TimeoutSec 15
$HL_FEE = 0.045
$hlMap = @{}
foreach ($u in $hlMeta.universe) {
    if (-not $u.isDelisted) {
        $m = 0
        if ($hlMids.$($u.name)) { $m = [double]$hlMids.$($u.name) }
        $hlMap[$u.name.ToUpper()] = @{ name = $u.name; mid = $m; fee = $HL_FEE }
    }
}
Write-Host "  $($hlMap.Count) tokens"

# 3. LIGHTER
Write-Host "`n[3/4] Lighter..." -ForegroundColor Yellow
$lResp = Invoke-RestMethod -Uri 'https://mainnet.zklighter.elliot.ai/api/v1/orderBookDetails' -TimeoutSec 20
$lMap = @{}
foreach ($i in $lResp.order_book_details) {
    if ($i.market_type -eq 'perp' -and $i.status -eq 'active') {
        $mp = [double]$i.mark_price; $ip = [double]$i.index_price
        $avg = ($mp + $ip) / 2
        $es = 0
        if ($avg -gt 0) { $es = [math]::Round([math]::Abs($mp - $ip) / $avg * 100, 6) }
        $tf = [double]$i.taker_fee * 100
        $lMap[$i.symbol.ToUpper()] = @{ name = $i.symbol; halfSpread = $es; fee = $tf; execCost = [math]::Round($es + $tf, 6); mark = $mp; index = $ip }
    }
}
Write-Host "  $($lMap.Count) perps"

# 4. TRADE.XYZ
Write-Host "`n[4/4] Trade.xyz..." -ForegroundColor Yellow
$xyzMeta = Invoke-RestMethod -Uri 'https://api.hyperliquid.xyz/info' -Method Post -Body '{"type":"meta","dex":"xyz"}' -ContentType 'application/json' -TimeoutSec 15
$TX_FEE = $HL_FEE
$txNames = @()
foreach ($u in $xyzMeta.universe) {
    if (-not $u.isDelisted) {
        $n = $u.name -replace '^xyz:', ''
        $txNames += $n
    }
}
Write-Host "  $($txNames.Count) markets"

# BUILD REGISTRY
Write-Host "`n=== Building registry... ===" -ForegroundColor Cyan
$all = @{}
foreach ($k in $vMap.Keys) { if (-not $all[$k]) { $all[$k] = @{} }; $all[$k].v = $vMap[$k] }
foreach ($k in $hlMap.Keys) { if (-not $all[$k]) { $all[$k] = @{} }; $all[$k].hl = $hlMap[$k] }
foreach ($k in $lMap.Keys) { if (-not $all[$k]) { $all[$k] = @{} }; $all[$k].li = $lMap[$k] }
foreach ($n in $txNames) { $k = $n.ToUpper(); if (-not $all[$k]) { $all[$k] = @{} }; $all[$k].tx = $true }

$filtered = @{}
foreach ($kv in $all.GetEnumerator()) {
    $c = 0
    if ($kv.Value.v) { $c++ }
    if ($kv.Value.hl) { $c++ }
    if ($kv.Value.li) { $c++ }
    if ($kv.Value.tx) { $c++ }
    if ($c -ge 2) { $filtered[$kv.Key] = $kv.Value }
}
$txC = ($filtered.Values | Where-Object { $_.tx }).Count
Write-Host "  Tokens on >=2: $($filtered.Count) (Trade.xyz: $txC)"

# FETCH L2 BOOKS
Write-Host "`n=== Fetching L2 books (HL:80 + TX:50)... ===" -ForegroundColor Cyan
function Get-L2Book($coin, $timeout) {
    try {
        $body = "{`"type`":`"l2Book`",`"coin`":`"$coin`"}"
        $bk = Invoke-RestMethod -Uri 'https://api.hyperliquid.xyz/info' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $timeout
        $bb = 0; $ba = 0
        $bids = $bk.levels[0]; $asks = $bk.levels[1]
        if ($bids -and $bids.Count) { $bb = [double]$bids[0].px }
        if ($asks -and $asks.Count) { $ba = [double]$asks[0].px }
        $mid = ($bb + $ba) / 2
        $hs = 0
        if ($mid -gt 0) { $hs = [math]::Round(($ba - $bb) / (2 * $mid) * 100, 6) }
        return @{ bid = $bb; ask = $ba; spread = $hs }
    } catch { return @{ bid = 0; ask = 0; spread = 0 } }
}

$books = @{}
$n = 0
$sorted = ($filtered.GetEnumerator() | Sort-Object { $vol = 0; if ($_.Value.v) { $vol = $_.Value.v.vol }; -$vol })
foreach ($kv in $sorted) {
    if ($n -ge 80) { break }
    if (-not $kv.Value.hl) { continue }
    $n++
    $bk = Get-L2Book $kv.Key 8
    $books[$kv.Key] = @{ bid = $bk.bid; ask = $bk.ask; spread = $bk.spread; exec = [math]::Round($bk.spread + $HL_FEE, 6) }
    if ($n % 20 -eq 0) { Write-Host "  HL: $n/80" }
}
Write-Host "  HL books: $($books.Count)"

$txBooks = @{}
$tn = 0
foreach ($kv in $sorted) {
    if ($tn -ge 50) { break }
    if (-not $kv.Value.tx) { continue }
    $tn++
    $bk = Get-L2Book "xyz:$($kv.Key)" 8
    $txBooks[$kv.Key] = @{ bid = $bk.bid; ask = $bk.ask; spread = $bk.spread; exec = [math]::Round($bk.spread + $TX_FEE, 6) }
    if ($tn % 20 -eq 0) { Write-Host "  TX: $tn/50" }
}
Write-Host "  TX books: $($txBooks.Count)"

# BUILD OUTPUT
Write-Host "`n=== Building data.json... ===" -ForegroundColor Cyan
$final = @()
foreach ($kv in $filtered.GetEnumerator()) {
    $tk = $kv.Key; $d = $kv.Value
    $b = $books[$tk]; $tb = $txBooks[$tk]
    $onV = ($d.v -ne $null); $onHL = ($d.hl -ne $null); $onL = ($d.li -ne $null); $onTX = ($d.tx -ne $null)
    $np = 0; if ($onV) { $np++ }; if ($onHL) { $np++ }; if ($onL) { $np++ }; if ($onTX) { $np++ }

    $vExec = if ($onV) { $d.v.execCost } else { $null }
    $hlExec = if ($onHL) { if ($b) { $b.exec } else { $HL_FEE } } else { $null }
    $hasHLBook = ($b -ne $null)
    $lExec = if ($onL) { $d.li.execCost } else { $null }
    $txExec = if ($onTX) { if ($tb) { $tb.exec } else { $TX_FEE } } else { $null }
    $hasTXBook = ($tb -ne $null)

    $best = "-"; $bestCost = 999
    if ($onV -and $vExec -lt $bestCost) { $best = "Variational"; $bestCost = $vExec }
    if ($onHL -and $hlExec -ne $null -and $hlExec -lt $bestCost) { $best = "Hyperliquid"; $bestCost = $hlExec }
    if ($onL -and $lExec -ne $null -and $lExec -lt $bestCost) { $best = "Lighter"; $bestCost = $lExec }
    if ($onTX -and $txExec -ne $null -and $txExec -lt $bestCost) { $best = "Trade.xyz"; $bestCost = $txExec }

    $pf = @()
    if ($onV) { $pf += "V" }; if ($onHL) { $pf += "HL" }; if ($onL) { $pf += "L" }; if ($onTX) { $pf += "TX" }

    $final += [ordered]@{
        ticker = $tk
        on_v = $onV; on_hl = $onHL; on_l = $onL; on_tradexyz = $onTX
        platforms = ($pf -join "+"); num_platforms = $np
        v_exec = $vExec; v_fee = 0; v_vol = if ($d.v) { $d.v.vol } else { 0 }
        hl_exec = $hlExec; hl_fee = $HL_FEE; has_hl_book = $hasHLBook
        l_exec = $lExec; l_fee = if ($d.li) { $d.li.fee } else { $null }
        tx_exec = $txExec; tx_fee = $TX_FEE; has_tx_book = $hasTXBook
        best = $best
    }
}

$final | ConvertTo-Json -Depth 4 | Out-File -FilePath "$PSScriptRoot\data.json" -Encoding UTF8

$elapsed = (Get-Date) - $t0
$vB = ($final | Where-Object { $_.best -eq 'Variational' }).Count
$hlB = ($final | Where-Object { $_.best -eq 'Hyperliquid' }).Count
$lB = ($final | Where-Object { $_.best -eq 'Lighter' }).Count
$txB = ($final | Where-Object { $_.best -eq 'Trade.xyz' }).Count
Write-Host "`n=== DONE: $($final.Count) tokens in $([math]::Round($elapsed.TotalSeconds,1))s ===" -ForegroundColor Green
Write-Host "Best: V=$vB HL=$hlB L=$lB TX=$txB" -ForegroundColor Green
