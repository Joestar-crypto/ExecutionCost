# filter-tokens.ps1 - Keep only L+HL and TX+L tokens, cap V spreads
$ErrorActionPreference = "Stop"
Write-Host "=== FILTER: L+HL + TX+L tokens, cap V spreads ===" -ForegroundColor Cyan

$dataPath = "C:\Users\Administrator\Desktop\Exec cost\data.json"
$data = Get-Content $dataPath -Raw | ConvertFrom-Json

# Keep only tokens on (Lighter + HL) OR (Trade.xyz + Lighter)
$filtered = @()
$seen = @{}
foreach ($t in $data) {
    $key = $t.ticker.ToUpper()
    $keep = ($t.on_l -and $t.on_hl) -or ($t.on_tradexyz -and $t.on_l)
    if ($keep -and -not $seen[$key]) {
        $seen[$key] = $true
        # Cap Variational exec cost at 5% max
        if ($t.v_exec -gt 5) { $t.v_exec = 5 }
        # Cap Lighter at 5% too
        if ($t.l_exec -gt 5) { $t.l_exec = 5 }
        # Recalculate best
        $best = "-"; $bestCost = 999
        if ($t.on_v -and $t.v_exec -ne $null -and $t.v_exec -lt $bestCost) { $best = "Variational"; $bestCost = $t.v_exec }
        if ($t.on_hl -and $t.hl_exec -ne $null -and $t.hl_exec -lt $bestCost) { $best = "Hyperliquid"; $bestCost = $t.hl_exec }
        if ($t.on_l -and $t.l_exec -ne $null -and $t.l_exec -lt $bestCost) { $best = "Lighter"; $bestCost = $t.l_exec }
        if ($t.on_tradexyz -and $t.tx_exec -ne $null -and $t.tx_exec -lt $bestCost) { $best = "Trade.xyz"; $bestCost = $t.tx_exec }
        $t.best = $best
        $filtered += $t
    }
}

Write-Host "Kept: $($filtered.Count) tokens"
$lhl = ($filtered | Where-Object { $_.on_l -and $_.on_hl }).Count
$txl = ($filtered | Where-Object { $_.on_tradexyz -and $_.on_l }).Count
Write-Host "  L+HL: $lhl, TX+L: $txl"

$vBest = ($filtered | Where-Object { $_.best -eq 'Variational' }).Count
$hlBest = ($filtered | Where-Object { $_.best -eq 'Hyperliquid' }).Count
$lBest = ($filtered | Where-Object { $_.best -eq 'Lighter' }).Count
$txBest = ($filtered | Where-Object { $_.best -eq 'Trade.xyz' }).Count
Write-Host "Best: V=$vBest HL=$hlBest L=$lBest TX=$txBest"

# Remove size fields (computed client-side)
foreach ($t in $filtered) {
    $t.PSObject.Properties | Where-Object { $_.Name -match '_exec_(10k|100k|1M)$' } | ForEach-Object {
        $t.PSObject.Properties.Remove($_.Name)
    }
}

$filtered | ConvertTo-Json -Depth 4 | Set-Content -Path $dataPath -Encoding UTF8
Write-Host "Saved." -ForegroundColor Green
