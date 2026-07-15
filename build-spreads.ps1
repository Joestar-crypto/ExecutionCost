# build-spreads.ps1 - Fetch real spreads from each platform's API
$ErrorActionPreference = "Stop"
$t0 = Get-Date
Write-Host "=== BUILD SPREADS: HL (all) + TX (all) + Lighter (mark-index) ===" -ForegroundColor Cyan

$dataPath = "C:\Users\Administrator\Desktop\Exec cost\data.json"
$data = Get-Content $dataPath -Raw | ConvertFrom-Json

# ===== 1. HYPERLIQUID - L2 depth for ALL tokens =====
Write-Host "`n[1/3] Hyperliquid L2 depth (all tokens)..." -ForegroundColor Yellow

function Get-HLL2($coin, $timeout) {
    try {
        $body = "{`"type`":`"l2Book`",`"coin`":`"$coin`"}"
        $bk = Invoke-RestMethod -Uri 'https://api.hyperliquid.xyz/info' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $timeout
        return $bk
    } catch { return $null }
}

function Calc-Spread($levels, $mid) {
    if (-not $levels -or $levels.Count -eq 0 -or $mid -le 0) { return 0 }
    $bestBid = [double]$levels[0][0].px
    $bestAsk = [double]$levels[1][0].px
    if ($bestBid -le 0 -or $bestAsk -le 0) { return 0 }
    $m = ($bestBid + $bestAsk) / 2
    if ($m -le 0) { return 0 }
    return [math]::Round(($bestAsk - $bestBid) / (2 * $m) * 100, 6)
}

$hlTokens = $data | Where-Object { $_.on_hl -eq $true }
$hlCount = 0; $hlTotal = $hlTokens.Count

foreach ($t in $hlTokens) {
    $hlCount++
    $bk = Get-HLL2 $t.ticker 6
    $spread = 0; $hasBk = $false
    if ($bk -and $bk.levels -and $bk.levels[0].Count -gt 0 -and $bk.levels[1].Count -gt 0) {
        $spread = Calc-Spread $bk.levels 0
        $hasBk = $true
        $t.has_hl_book = $true
    } else {
        $t.has_hl_book = $false
    }
    $fee = $t.hl_fee; if (-not $fee) { $fee = 0.045 }
    $t.hl_exec = [math]::Round($spread + $fee, 6)
    if ($hlCount % 30 -eq 0) { Write-Host "  HL: $hlCount/$hlTotal" }
}
$hlWithBook = ($hlTokens | Where-Object { $_.has_hl_book }).Count
Write-Host "  HL done: $hlTotal tokens, $hlWithBook with orderbook"

# ===== 2. TRADE.XYZ - L2 depth for ALL tokens =====
Write-Host "`n[2/3] Trade.xyz L2 depth (all tokens)..." -ForegroundColor Yellow

$txTokens = $data | Where-Object { $_.on_tradexyz -eq $true }
$txCount = 0; $txTotal = $txTokens.Count

foreach ($t in $txTokens) {
    $txCount++
    $bk = Get-HLL2 "xyz:$($t.ticker)" 6
    $spread = 0; $hasBk = $false
    if ($bk -and $bk.levels -and $bk.levels[0].Count -gt 0 -and $bk.levels[1].Count -gt 0) {
        $spread = Calc-Spread $bk.levels 0
        $hasBk = $true
        $t.has_tx_book = $true
    } else {
        $t.has_tx_book = $false
    }
    $fee = $t.tx_fee; if (-not $fee) { $fee = 0.045 }
    $t.tx_exec = [math]::Round($spread + $fee, 6)
    if ($txCount % 20 -eq 0) { Write-Host "  TX: $txCount/$txTotal" }
}
$txWithBook = ($txTokens | Where-Object { $_.has_tx_book }).Count
Write-Host "  TX done: $txTotal tokens, $txWithBook with orderbook"

# ===== 3. LIGHTER - use mark-index spread (already in data) =====
Write-Host "`n[3/3] Lighter (mark-index proxy)..." -ForegroundColor Yellow
$liCount = ($data | Where-Object { $_.on_l }).Count
Write-Host "  Lighter: $liCount tokens (unchanged, mark-index already in l_exec)"

# ===== RECALCULATE BEST =====
Write-Host "`n=== Recalculating best platform... ===" -ForegroundColor Cyan

foreach ($t in $data) {
    $best = "-"; $bestCost = 999
    if ($t.on_v -and $t.v_exec -ne $null -and $t.v_exec -lt $bestCost) { $best = "Variational"; $bestCost = $t.v_exec }
    if ($t.on_hl -and $t.hl_exec -ne $null -and $t.hl_exec -lt $bestCost) { $best = "Hyperliquid"; $bestCost = $t.hl_exec }
    if ($t.on_l -and $t.l_exec -ne $null -and $t.l_exec -lt $bestCost) { $best = "Lighter"; $bestCost = $t.l_exec }
    if ($t.on_tradexyz -and $t.tx_exec -ne $null -and $t.tx_exec -lt $bestCost) { $best = "Trade.xyz"; $bestCost = $t.tx_exec }
    $t.best = $best
}

# Remove old size-adjusted fields (they'll be computed client-side)
foreach ($t in $data) {
    $t.PSObject.Properties | Where-Object { $_.Name -match '_exec_(10k|100k|1M)$' } | ForEach-Object {
        $t.PSObject.Properties.Remove($_.Name)
    }
}

# ===== SAVE =====
Write-Host "`n=== Saving data.json... ===" -ForegroundColor Cyan
$data | ConvertTo-Json -Depth 4 | Set-Content -Path $dataPath -Encoding UTF8

$elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
$vBest = ($data | Where-Object { $_.best -eq 'Variational' }).Count
$hlBest = ($data | Where-Object { $_.best -eq 'Hyperliquid' }).Count
$lBest = ($data | Where-Object { $_.best -eq 'Lighter' }).Count
$txBest = ($data | Where-Object { $_.best -eq 'Trade.xyz' }).Count
Write-Host "Done in ${elapsed}s" -ForegroundColor Green
Write-Host "Best: V=$vBest HL=$hlBest L=$lBest TX=$txBest" -ForegroundColor Green
