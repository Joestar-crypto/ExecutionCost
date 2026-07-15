# build-spreads-v2.ps1 - Walk orderbook for real spread+slippage, not just top-of-book
$ErrorActionPreference = "Stop"
$t0 = Get-Date
Write-Host "=== BUILD SPREADS V2: Orderbook walking for real slippage ===" -ForegroundColor Cyan

$dataPath = "C:\Users\Administrator\Desktop\Exec cost\data.json"
$data = Get-Content $dataPath -Raw | ConvertFrom-Json

function Get-L2($coin, $timeout) {
    try {
        $body = "{`"type`":`"l2Book`",`"coin`":`"$coin`"}"
        return Invoke-RestMethod -Uri 'https://api.hyperliquid.xyz/info' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $timeout
    } catch { return $null }
}

function Walk-Book($levels, $mid, $notional, $fee) {
    # levels = asks array (px, sz), walk from best to worst
    if (-not $levels -or $levels.Count -eq 0 -or $mid -le 0) { return $fee }
    $remaining = $notional
    $totalCost = 0.0
    $totalCoins = 0.0
    foreach ($l in $levels) {
        $px = [double]$l.px; $sz = [double]$l.sz
        $levelNotional = $sz * $px
        if ($levelNotional -ge $remaining) {
            $coinsNeeded = $remaining / $px
            $totalCost += $remaining
            $totalCoins += $coinsNeeded
            $remaining = 0
            break
        } else {
            $totalCost += $levelNotional
            $totalCoins += $sz
            $remaining -= $levelNotional
        }
    }
    if ($totalCoins -le 0) { return $fee }
    $avgPrice = $totalCost / $totalCoins
    $hs = [math]::Round(($avgPrice - $mid) / $mid * 100, 6)
    if ($hs -lt 0) { $hs = 0 }
    return [math]::Round($hs + $fee, 6)
}

function Calc-ExecCosts($bk, $fee) {
    # Returns @{base, k10, k100, k1M} or just fee if no book
    if (-not $bk -or -not $bk.levels -or $bk.levels[0].Count -eq 0 -or $bk.levels[1].Count -eq 0) {
        return @{ base = $fee; k10 = $fee; k100 = $fee; k1M = $fee; hasBook = $false }
    }
    $bids = $bk.levels[0]; $asks = $bk.levels[1]
    $bb = [double]$bids[0].px; $ba = [double]$asks[0].px
    if ($bb -le 0 -or $ba -le 0) { return @{ base = $fee; k10 = $fee; k100 = $fee; k1M = $fee; hasBook = $false } }
    $mid = ($bb + $ba) / 2
    $baseHs = [math]::Round(($ba - $bb) / (2 * $mid) * 100, 6)
    if ($baseHs -lt 0) { $baseHs = 0 }
    return @{
        base = [math]::Round($baseHs + $fee, 6)
        k10 = Walk-Book $asks $mid 10000 $fee
        k100 = Walk-Book $asks $mid 100000 $fee
        k1M = Walk-Book $asks $mid 1000000 $fee
        hasBook = $true
    }
}

# ===== 1. HYPERLIQUID =====
Write-Host "`n[1/3] Hyperliquid (walk orderbook)..." -ForegroundColor Yellow
$hlTokens = $data | Where-Object { $_.on_hl }
$hlN = 0; $hlT = $hlTokens.Count
foreach ($t in $hlTokens) {
    $hlN++
    $bk = Get-L2 $t.ticker 6
    $fee = $t.hl_fee; if (-not $fee) { $fee = 0.045 }
    $r = Calc-ExecCosts $bk $fee
    $t | Add-Member -NotePropertyName 'hl_exec' -NotePropertyValue $r.base -Force
    $t | Add-Member -NotePropertyName 'has_hl_book' -NotePropertyValue $r.hasBook -Force
    $t | Add-Member -NotePropertyName 'hl_exec_10k' -NotePropertyValue $r.k10 -Force
    $t | Add-Member -NotePropertyName 'hl_exec_100k' -NotePropertyValue $r.k100 -Force
    $t | Add-Member -NotePropertyName 'hl_exec_1M' -NotePropertyValue $r.k1M -Force
    if ($hlN % 30 -eq 0) { Write-Host "  HL: $hlN/$hlT" }
}
$hlBk = ($hlTokens | Where-Object { $_.has_hl_book }).Count
Write-Host "  HL done: $hlT tokens, $hlBk with orderbook"

# ===== 2. TRADE.XYZ =====
Write-Host "`n[2/3] Trade.xyz (walk orderbook)..." -ForegroundColor Yellow
$txTokens = $data | Where-Object { $_.on_tradexyz }
$txN = 0; $txT = $txTokens.Count
foreach ($t in $txTokens) {
    $txN++
    $bk = Get-L2 "xyz:$($t.ticker)" 6
    $fee = $t.tx_fee; if (-not $fee) { $fee = 0.045 }
    $r = Calc-ExecCosts $bk $fee
    $t | Add-Member -NotePropertyName 'tx_exec' -NotePropertyValue $r.base -Force
    $t | Add-Member -NotePropertyName 'has_tx_book' -NotePropertyValue $r.hasBook -Force
    $t | Add-Member -NotePropertyName 'tx_exec_10k' -NotePropertyValue $r.k10 -Force
    $t | Add-Member -NotePropertyName 'tx_exec_100k' -NotePropertyValue $r.k100 -Force
    $t | Add-Member -NotePropertyName 'tx_exec_1M' -NotePropertyValue $r.k1M -Force
    if ($txN % 20 -eq 0) { Write-Host "  TX: $txN/$txT" }
}
$txBk = ($txTokens | Where-Object { $_.has_tx_book }).Count
Write-Host "  TX done: $txT tokens, $txBk with orderbook"

# ===== 3. VARIATIONAL & LIGHTER - use multiplier on existing spread =====
Write-Host "`n[3/3] Variational & Lighter (multiplier on base spread)..." -ForegroundColor Yellow
foreach ($t in $data) {
    if ($t.on_v) {
        $fee = $t.v_fee; if (-not $fee) { $fee = 0 }
        $hs = $t.v_exec - $fee; if ($hs -lt 0) { $hs = 0 }
        $t | Add-Member -NotePropertyName 'v_exec_10k' -NotePropertyValue ([math]::Min(5, [math]::Round($fee + $hs * 1.0, 6))) -Force
        $t | Add-Member -NotePropertyName 'v_exec_100k' -NotePropertyValue ([math]::Min(5, [math]::Round($fee + $hs * 1.5, 6))) -Force
        $t | Add-Member -NotePropertyName 'v_exec_1M' -NotePropertyValue ([math]::Min(5, [math]::Round($fee + $hs * 2.5, 6))) -Force
    }
    if ($t.on_l) {
        $fee = $t.l_fee; if (-not $fee) { $fee = 0 }
        $hs = $t.l_exec - $fee; if ($hs -lt 0) { $hs = 0 }
        $t | Add-Member -NotePropertyName 'l_exec_10k' -NotePropertyValue ([math]::Min(5, [math]::Round($fee + $hs * 1.0, 6))) -Force
        $t | Add-Member -NotePropertyName 'l_exec_100k' -NotePropertyValue ([math]::Min(5, [math]::Round($fee + $hs * 1.5, 6))) -Force
        $t | Add-Member -NotePropertyName 'l_exec_1M' -NotePropertyValue ([math]::Min(5, [math]::Round($fee + $hs * 2.5, 6))) -Force
    }
}
Write-Host "  V+L size fields added (capped at 5%)"
foreach ($t in $data) {
    $best = "-"; $bc = 999
    if ($t.on_v -and $t.v_exec -ne $null -and $t.v_exec -lt $bc) { $best = "Variational"; $bc = $t.v_exec }
    if ($t.on_hl -and $t.hl_exec -ne $null -and $t.hl_exec -lt $bc) { $best = "Hyperliquid"; $bc = $t.hl_exec }
    if ($t.on_l -and $t.l_exec -ne $null -and $t.l_exec -lt $bc) { $best = "Lighter"; $bc = $t.l_exec }
    if ($t.on_tradexyz -and $t.tx_exec -ne $null -and $t.tx_exec -lt $bc) { $best = "Trade.xyz"; $bc = $t.tx_exec }
    $t.best = $best
}
$vB = ($data | Where-Object { $_.best -eq 'Variational' }).Count
$hlB = ($data | Where-Object { $_.best -eq 'Hyperliquid' }).Count
$lB = ($data | Where-Object { $_.best -eq 'Lighter' }).Count
$txB = ($data | Where-Object { $_.best -eq 'Trade.xyz' }).Count
Write-Host "Best: V=$vB HL=$hlB L=$lB TX=$txB"

# ===== SAVE =====
$data | ConvertTo-Json -Depth 4 | Set-Content -Path $dataPath -Encoding UTF8
$elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
Write-Host "`nDone in ${elapsed}s" -ForegroundColor Green
