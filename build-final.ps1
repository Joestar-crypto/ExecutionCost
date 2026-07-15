# build-final.ps1 - Clean build: V+HL+L (crypto) + V+TX+L (RWA) with real spreads
$ErrorActionPreference = "Stop"
$t0 = Get-Date
Write-Host "=== FINAL BUILD: 85 crypto (V+HL+L) + 31 RWA (V+TX+L) ===" -ForegroundColor Cyan

$dataPath = "C:\Users\Administrator\Desktop\Exec cost\data.json"
$data = Get-Content $dataPath -Raw | ConvertFrom-Json

# Filter
$filtered = @()
foreach ($t in $data) {
    $keep = ($t.on_v -and $t.on_hl -and $t.on_l) -or ($t.on_v -and $t.on_tradexyz -and $t.on_l)
    if ($keep) { $filtered += $t }
}
Write-Host "Filtered: $($filtered.Count) tokens"
$crypto = ($filtered | Where-Object { $_.on_v -and $_.on_hl -and $_.on_l }).Count
$rwa = ($filtered | Where-Object { $_.on_v -and $_.on_tradexyz -and $_.on_l }).Count
Write-Host "  Crypto (V+HL+L): $crypto, RWA (V+TX+L): $rwa"

# ===== HL: walk orderbook for real spread+slippage =====
Write-Host "`n[1/2] Hyperliquid orderbook walking..." -ForegroundColor Yellow
function Get-L2($coin) {
    try {
        $body = "{`"type`":`"l2Book`",`"coin`":`"$coin`"}"
        return Invoke-RestMethod -Uri 'https://api.hyperliquid.xyz/info' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 6
    } catch { return $null }
}
function Walk($levels, $mid, $notional) {
    if (-not $levels -or $levels.Count -eq 0 -or $mid -le 0) { return 0 }
    $rem = $notional; $cost = 0.0; $coins = 0.0
    foreach ($l in $levels) {
        $px = [double]$l.px; $sz = [double]$l.sz
        $lv = $sz * $px
        if ($lv -ge $rem) { $cost += $rem; $coins += $rem / $px; $rem = 0; break }
        $cost += $lv; $coins += $sz; $rem -= $lv
    }
    if ($coins -le 0) { return 0 }
    $avg = $cost / $coins
    $hs = ($avg - $mid) / $mid * 100
    if ($hs -lt 0) { $hs = 0 }
    return [math]::Round($hs, 6)
}

$hlFee = 0.045
$n = 0
foreach ($t in $filtered) {
    if (-not $t.on_hl) { continue }
    $n++
    $bk = Get-L2 $t.ticker
    $hasBk = $false; $sp = 0; $sp10k = 0; $sp100k = 0; $sp1M = 0
    if ($bk -and $bk.levels -and $bk.levels[0].Count -gt 0 -and $bk.levels[1].Count -gt 0) {
        $bids = $bk.levels[0]; $asks = $bk.levels[1]
        $bb = [double]$bids[0].px; $ba = [double]$asks[0].px
        if ($bb -gt 0 -and $ba -gt 0) {
            $mid = ($bb + $ba) / 2
            $sp = [math]::Round(($ba - $bb) / (2 * $mid) * 100, 6)
            if ($sp -lt 0) { $sp = 0 }
            $sp10k = Walk $asks $mid 10000
            $sp100k = Walk $asks $mid 100000
            $sp1M = Walk $asks $mid 1000000
            $hasBk = $true
        }
    }
    $t | Add-Member -Force -NotePropertyName 'has_hl_book' -NotePropertyValue $hasBk
    $t | Add-Member -Force -NotePropertyName 'hl_exec' -NotePropertyValue ([math]::Round($sp + $hlFee, 6))
    $t | Add-Member -Force -NotePropertyName 'hl_exec_10k' -NotePropertyValue ([math]::Round($sp10k + $hlFee, 6))
    $t | Add-Member -Force -NotePropertyName 'hl_exec_100k' -NotePropertyValue ([math]::Round($sp100k + $hlFee, 6))
    $t | Add-Member -Force -NotePropertyName 'hl_exec_1M' -NotePropertyValue ([math]::Round($sp1M + $hlFee, 6))
    if ($n % 20 -eq 0) { Write-Host "  HL: $n" }
}
Write-Host "  HL done: $n tokens"

# ===== TX: walk orderbook with xyz: prefix =====
Write-Host "`n[2/2] Trade.xyz orderbook walking..." -ForegroundColor Yellow
$txFee = 0.045
$n = 0
foreach ($t in $filtered) {
    if (-not $t.on_tradexyz) { continue }
    $n++
    $bk = Get-L2 "xyz:$($t.ticker)"
    $hasBk = $false; $sp = 0; $sp10k = 0; $sp100k = 0; $sp1M = 0
    if ($bk -and $bk.levels -and $bk.levels[0].Count -gt 0 -and $bk.levels[1].Count -gt 0) {
        $bids = $bk.levels[0]; $asks = $bk.levels[1]
        $bb = [double]$bids[0].px; $ba = [double]$asks[0].px
        if ($bb -gt 0 -and $ba -gt 0) {
            $mid = ($bb + $ba) / 2
            $sp = [math]::Round(($ba - $bb) / (2 * $mid) * 100, 6)
            if ($sp -lt 0) { $sp = 0 }
            $sp10k = Walk $asks $mid 10000
            $sp100k = Walk $asks $mid 100000
            $sp1M = Walk $asks $mid 1000000
            $hasBk = $true
        }
    }
    $t | Add-Member -Force -NotePropertyName 'has_tx_book' -NotePropertyValue $hasBk
    $t | Add-Member -Force -NotePropertyName 'tx_exec' -NotePropertyValue ([math]::Round($sp + $txFee, 6))
    $t | Add-Member -Force -NotePropertyName 'tx_exec_10k' -NotePropertyValue ([math]::Round($sp10k + $txFee, 6))
    $t | Add-Member -Force -NotePropertyName 'tx_exec_100k' -NotePropertyValue ([math]::Round($sp100k + $txFee, 6))
    $t | Add-Member -Force -NotePropertyName 'tx_exec_1M' -NotePropertyValue ([math]::Round($sp1M + $txFee, 6))
    if ($n % 15 -eq 0) { Write-Host "  TX: $n" }
}
Write-Host "  TX done: $n tokens"

# ===== V + L: multiplier on base spread (capped 5%) =====
Write-Host "`n=== V & L size fields ===" -ForegroundColor Yellow
foreach ($t in $filtered) {
    if ($t.on_v) {
        $f = [double]$t.v_fee; if ($f -eq 0 -and -not $t.v_fee) { $f = 0.0 }
        $hs = [double]$t.v_exec - $f; if ($hs -lt 0) { $hs = 0 }
        $t | Add-Member -Force -NotePropertyName 'v_exec_10k' -NotePropertyValue ([double]([math]::Min(5.0, [math]::Round($f + $hs * 1.0, 6))))
        $t | Add-Member -Force -NotePropertyName 'v_exec_100k' -NotePropertyValue ([double]([math]::Min(5.0, [math]::Round($f + $hs * 1.5, 6))))
        $t | Add-Member -Force -NotePropertyName 'v_exec_1M' -NotePropertyValue ([double]([math]::Min(5.0, [math]::Round($f + $hs * 2.5, 6))))
    }
    if ($t.on_l) {
        $f = [double]$t.l_fee; if ($f -eq 0 -and -not $t.l_fee) { $f = 0.0 }
        $hs = [double]$t.l_exec - $f; if ($hs -lt 0) { $hs = 0 }
        $t | Add-Member -Force -NotePropertyName 'l_exec_10k' -NotePropertyValue ([double]([math]::Min(5.0, [math]::Round($f + $hs * 1.0, 6))))
        $t | Add-Member -Force -NotePropertyName 'l_exec_100k' -NotePropertyValue ([double]([math]::Min(5.0, [math]::Round($f + $hs * 1.5, 6))))
        $t | Add-Member -Force -NotePropertyName 'l_exec_1M' -NotePropertyValue ([double]([math]::Min(5.0, [math]::Round($f + $hs * 2.5, 6))))
    }
}

# Fix Lighter tokens with l_exec=0 (use V spread as proxy)
$liFixed = 0
foreach ($t in $filtered) {
    $lVal = [double]$t.l_exec
    if ($t.on_l -and $t.on_v -and $lVal -eq 0) {
        $vHs = [double]$t.v_exec - [double]$t.v_fee
        if ($vHs -lt 0) { $vHs = 0 }
        $newExec = [math]::Round($vHs * 0.7, 6)
        $t | Add-Member -Force -NotePropertyName 'l_exec' -NotePropertyValue $newExec
        $t | Add-Member -Force -NotePropertyName 'l_exec_10k' -NotePropertyValue ([double]([math]::Min(5.0, [math]::Round($newExec * 1.0, 6))))
        $t | Add-Member -Force -NotePropertyName 'l_exec_100k' -NotePropertyValue ([double]([math]::Min(5.0, [math]::Round($newExec * 1.5, 6))))
        $t | Add-Member -Force -NotePropertyName 'l_exec_1M' -NotePropertyValue ([double]([math]::Min(5.0, [math]::Round($newExec * 2.5, 6))))
        $liFixed++
    }
}
Write-Host "  Lighter proxy fix: $liFixed tokens (0 -> V-spread*0.7)" -ForegroundColor Yellow

# Recalculate best
foreach ($t in $filtered) {
    $best = "-"; $bc = 999
    if ($t.on_v -and $t.v_exec -ne $null -and $t.v_exec -lt $bc) { $best = "Variational"; $bc = $t.v_exec }
    if ($t.on_hl -and $t.hl_exec -ne $null -and $t.hl_exec -lt $bc) { $best = "Hyperliquid"; $bc = $t.hl_exec }
    if ($t.on_l -and $t.l_exec -ne $null -and $t.l_exec -lt $bc) { $best = "Lighter"; $bc = $t.l_exec }
    if ($t.on_tradexyz -and $t.tx_exec -ne $null -and $t.tx_exec -lt $bc) { $best = "Trade.xyz"; $bc = $t.tx_exec }
    $t.best = $best
}

$vB = ($filtered | Where-Object { $_.best -eq 'Variational' }).Count
$hlB = ($filtered | Where-Object { $_.best -eq 'Hyperliquid' }).Count
$lB = ($filtered | Where-Object { $_.best -eq 'Lighter' }).Count
$txB = ($filtered | Where-Object { $_.best -eq 'Trade.xyz' }).Count
Write-Host "`nBest: V=$vB HL=$hlB L=$lB TX=$txB" -ForegroundColor Green

$filtered | ConvertTo-Json -Depth 4 | Set-Content -Path $dataPath -Encoding UTF8
$elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
Write-Host "Done in ${elapsed}s" -ForegroundColor Green
