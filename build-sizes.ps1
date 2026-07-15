# build-sizes.ps1 - Compute exact size-adjusted execution costs from real orderbook depth
$ErrorActionPreference = "Stop"
$t0 = Get-Date
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  EXEC COST SIZE-ADJUSTED (10k/100k/1M)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$dataPath = "C:\Users\Administrator\Desktop\Exec cost\data.json"
$data = Get-Content $dataPath -Raw | ConvertFrom-Json

$HL_FEE = 0.045
$TX_FEE = 0.045

# Compute weighted average execution price walking the orderbook
function Get-SizeExecCost($levels, $mid, $targetNotional, $fee) {
    # levels: array of {px, sz} from best to worst (asks for buy)
    # sz is in native coin units, px is price per coin
    $remaining = $targetNotional
    $totalCost = 0.0
    $totalCoins = 0.0
    
    foreach ($l in $levels) {
        $px = [double]$l.px
        $sz = [double]$l.sz
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
    
    if ($totalCoins -le 0 -or $mid -le 0) { return $null }
    
    $avgPrice = $totalCost / $totalCoins
    $halfSpread = [math]::Round(($avgPrice - $mid) / $mid * 100, 6)
    if ($halfSpread -lt 0) { $halfSpread = 0 }
    return [math]::Round($halfSpread + $fee, 6)
}

# ===== 1. HYPERLIQUID - exact L2 depth =====
Write-Host "`n[1/3] Hyperliquid L2 depth (exact)..." -ForegroundColor Yellow

function Get-HLDepth($coin, $timeout) {
    try {
        $body = "{`"type`":`"l2Book`",`"coin`":`"$coin`"}"
        $bk = Invoke-RestMethod -Uri 'https://api.hyperliquid.xyz/info' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $timeout
        return $bk
    } catch { return $null }
}

$hlTokens = $data | Where-Object { $_.has_hl_book -eq $true }
$hlCount = 0
$hlTotal = $hlTokens.Count

foreach ($t in $hlTokens) {
    $hlCount++
    $bk = Get-HLDepth $t.ticker 8
    if (-not $bk -or -not $bk.levels) {
        if ($hlCount % 20 -eq 0) { Write-Host "  HL: $hlCount/$hlTotal" }
        continue
    }
    
    $bids = $bk.levels[0]
    $asks = $bk.levels[1]
    if (-not $bids -or -not $asks -or $bids.Count -eq 0 -or $asks.Count -eq 0) {
        if ($hlCount % 20 -eq 0) { Write-Host "  HL: $hlCount/$hlTotal" }
        continue
    }
    
    $bestBid = [double]$bids[0].px
    $bestAsk = [double]$asks[0].px
    $mid = ($bestBid + $bestAsk) / 2
    
    if ($mid -le 0) {
        if ($hlCount % 20 -eq 0) { Write-Host "  HL: $hlCount/$hlTotal" }
        continue
    }
    
    # Compute exact execution costs for each size
    $t | Add-Member -NotePropertyName "hl_exec_10k" -NotePropertyValue (Get-SizeExecCost $asks $mid 10000 $HL_FEE) -Force
    $t | Add-Member -NotePropertyName "hl_exec_100k" -NotePropertyValue (Get-SizeExecCost $asks $mid 100000 $HL_FEE) -Force
    $t | Add-Member -NotePropertyName "hl_exec_1M" -NotePropertyValue (Get-SizeExecCost $asks $mid 1000000 $HL_FEE) -Force
    
    if ($hlCount % 20 -eq 0) { Write-Host "  HL: $hlCount/$hlTotal" }
}
Write-Host "  HL done: $hlCount tokens processed"

# ===== 2. VARIATIONAL - size-adjusted quotes from API =====
Write-Host "`n[2/3] Variational size-adjusted quotes..." -ForegroundColor Yellow

try {
    $vResp = Invoke-RestMethod -Uri 'https://omni-client-api.prod.ap-northeast-1.variational.io/metadata/stats' -TimeoutSec 20
    
    $vMap = @{}
    foreach ($item in $vResp.listings) {
        $ticker = $item.ticker.ToUpper()
        $baseBid = 0; $baseAsk = 0
        if ($item.quotes.base) { $baseBid = [double]$item.quotes.base.bid; $baseAsk = [double]$item.quotes.base.ask }
        
        $k1Bid = $baseBid; $k1Ask = $baseAsk
        if ($item.quotes.size_1k) { $k1Bid = [double]$item.quotes.size_1k.bid; $k1Ask = [double]$item.quotes.size_1k.ask }
        
        $k100Bid = $baseBid; $k100Ask = $baseAsk
        if ($item.quotes.size_100k) { $k100Bid = [double]$item.quotes.size_100k.bid; $k100Ask = [double]$item.quotes.size_100k.ask }
        
        $vMap[$ticker] = @{
            baseBid = $baseBid; baseAsk = $baseAsk
            k1Bid = $k1Bid; k1Ask = $k1Ask
            k100Bid = $k100Bid; k100Ask = $k100Ask
        }
    }
    Write-Host "  Variational quotes: $($vMap.Count) tokens"
    
    $vCount = 0
    foreach ($t in $data) {
        if (-not $t.on_v) { continue }
        $q = $vMap[$t.ticker.ToUpper()]
        if (-not $q) { continue }
        $vCount++
        
        $vFee = $t.v_fee
        if (-not $vFee) { $vFee = 0 }
        
        # Helper: compute half-spread from bid/ask
        function Get-HS($bid, $ask) {
            if ($bid -le 0 -or $ask -le 0) { return 0 }
            $mid = ($bid + $ask) / 2
            if ($mid -le 0) { return 0 }
            return [math]::Round(($ask - $bid) / (2 * $mid) * 100, 6)
        }
        
        # 10k: interpolate between base and 100k (10k is 1/10 of 100k)
        $w = 0.1  # weight toward 100k
        $bid10k = $q.baseBid + ($q.k100Bid - $q.baseBid) * $w
        $ask10k = $q.baseAsk + ($q.k100Ask - $q.baseAsk) * $w
        $hs10k = Get-HS $bid10k $ask10k
        
        # 100k: use size_100k directly
        $hs100k = Get-HS $q.k100Bid $q.k100Ask
        
        # 1M: extrapolate beyond 100k (2x the spread widening from base to 100k)
        $spreadWidening = $hs100k - (Get-HS $q.baseBid $q.baseAsk)
        if ($spreadWidening -lt 0) { $spreadWidening = 0 }
        $hs1M = $hs100k + $spreadWidening
        
        $t | Add-Member -NotePropertyName "v_exec_10k" -NotePropertyValue ([math]::Round($hs10k + $vFee, 6)) -Force
        $t | Add-Member -NotePropertyName "v_exec_100k" -NotePropertyValue ([math]::Round($hs100k + $vFee, 6)) -Force
        $t | Add-Member -NotePropertyName "v_exec_1M" -NotePropertyValue ([math]::Round($hs1M + $vFee, 6)) -Force
    }
    Write-Host "  V done: $vCount tokens with size quotes"
} catch {
    Write-Host "  Variational API failed: $_" -ForegroundColor Red
}

# ===== 3. TRADE.XYZ - same as HL but with xyz: prefix =====
Write-Host "`n[3/3] Trade.xyz L2 depth..." -ForegroundColor Yellow

$txTokens = $data | Where-Object { $_.has_tx_book -eq $true }
$txCount = 0
$txTotal = $txTokens.Count

foreach ($t in $txTokens) {
    $txCount++
    $bk = Get-HLDepth "xyz:$($t.ticker)" 8
    if (-not $bk -or -not $bk.levels) {
        if ($txCount % 20 -eq 0) { Write-Host "  TX: $txCount/$txTotal" }
        continue
    }
    
    $bids = $bk.levels[0]
    $asks = $bk.levels[1]
    if (-not $bids -or -not $asks -or $bids.Count -eq 0 -or $asks.Count -eq 0) {
        if ($txCount % 20 -eq 0) { Write-Host "  TX: $txCount/$txTotal" }
        continue
    }
    
    $bestBid = [double]$bids[0].px
    $bestAsk = [double]$asks[0].px
    $mid = ($bestBid + $bestAsk) / 2
    
    if ($mid -le 0) {
        if ($txCount % 20 -eq 0) { Write-Host "  TX: $txCount/$txTotal" }
        continue
    }
    
    $t | Add-Member -NotePropertyName "tx_exec_10k" -NotePropertyValue (Get-SizeExecCost $asks $mid 10000 $TX_FEE) -Force
    $t | Add-Member -NotePropertyName "tx_exec_100k" -NotePropertyValue (Get-SizeExecCost $asks $mid 100000 $TX_FEE) -Force
    $t | Add-Member -NotePropertyName "tx_exec_1M" -NotePropertyValue (Get-SizeExecCost $asks $mid 1000000 $TX_FEE) -Force
    
    if ($txCount % 20 -eq 0) { Write-Host "  TX: $txCount/$txTotal" }
}
Write-Host "  TX done: $txCount tokens processed"

# ===== SAVE =====
Write-Host "`n=== Saving data.json... ===" -ForegroundColor Cyan
$data | ConvertTo-Json -Depth 4 | Set-Content -Path $dataPath -Encoding UTF8

$elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
Write-Host "Done in ${elapsed}s" -ForegroundColor Green
Write-Host "Fields added: *_exec_10k, *_exec_100k, *_exec_1M" -ForegroundColor Green
