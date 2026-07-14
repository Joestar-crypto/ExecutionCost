# ExecutionCost.XYZ

**Compare real execution costs across derivatives platforms.** Half-spread + taker fees for 239 tokens across 4 venues.

## Platforms

| Platform | Fee | Spread Source |
|---|---|---|
| 🔮 **Variational** (Omni) | 0% | Real OLP bid/ask quotes |
| 🔷 **Hyperliquid** | 0.045% taker | Real on-chain L2 order book |
| 🟠 **Lighter** | 0% | Mark/index price proxy |
| 💗 **Trade.xyz** (HIP-3) | 0.045% taker | Real on-chain L2 order book (`xyz:` prefix) |

## Data

- **239 tokens** on ≥2 platforms
- Variational: 506 tokens · Hyperliquid: 177 · Lighter: 198 · Trade.xyz: 86
- Real L2 book spreads fetched for 80 HL + 50 Trade.xyz tokens
- Crypto/RWA classification based on Hyperliquid listing presence

## Quick Start

```bash
# 1. Fetch fresh data (takes ~2 min)
powershell -ExecutionPolicy Bypass -File .\build.ps1

# 2. Start local server
powershell -Command "$l=New-Object System.Net.HttpListener;$l.Prefixes.Add('http://localhost:8765/');$l.Start();while($l.IsListening){$c=$l.GetContext();$p=$c.Request.Url.LocalPath;if($p-eq'/'){$p='/index.html'};$f=Join-Path $pwd $p.TrimStart('/');if(Test-Path $f){$b=[IO.File]::ReadAllBytes($f);$c.Response.OutputStream.Write($b,0,$b.Length)};$c.Response.Close()}"

# 3. Open http://localhost:8765
```

## Files

- `build.ps1` — data pipeline: fetches all 4 APIs, computes spreads + fees
- `data.json` — compiled results (239 tokens)
- `index.html` — single-page dashboard (Chart.js, no framework)
- `tradexyz_tokens.json` — Trade.xyz market list for client-side tagging

## Execution Cost Formula

```
execution cost = half-spread + taker fee

half-spread = (ask − bid) / (ask + bid) × 100%
```

## Features

- 🎯 Scatter plot with all tokens mixed by execution cost
- 🥧 Best Platform pie chart (filterable by Crypto/RWA)
- 📊 Top 20 bar chart
- 🔍 Searchable, sortable table with category filters
- 🌐 Crypto / RWA / Trade.xyz classification
- ━ Average reference lines (toggleable)
- 💧 `executioncost.xyz` watermark on all charts

## Color Scheme

| Platform | Color | Hex |
|---|---|---|
| Variational | Indigo | `#7C3AED` |
| Hyperliquid | Teal | `#14B8A6` |
| Lighter | Amber | `#F59E0B` |
| Trade.xyz | Rose | `#EC4899` |

---

*Data refreshes every time you run `build.ps1`. Execution costs are indicative — actual costs vary with market conditions and order size.*
