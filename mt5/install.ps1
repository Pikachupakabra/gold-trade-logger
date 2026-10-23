# Copies the Gold Trade Logger MT5 files into MetaTrader 5's data folder and compiles them.
# Run from the project folder:
#   powershell -ExecutionPolicy Bypass -File mt5\install.ps1
# Safe to run again after any change; it overwrites the old copies.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$metaEditor = 'C:\Program Files\MetaTrader 5\MetaEditor64.exe'

# MT5 keeps its MQL5 folder under AppData, in a folder with a long random name.
$mql5 = Get-ChildItem (Join-Path $env:APPDATA 'MetaQuotes\Terminal') -Directory |
    ForEach-Object { Join-Path $_.FullName 'MQL5' } |
    Where-Object { Test-Path (Join-Path $_ 'Experts') } |
    Select-Object -First 1
if (-not $mql5) { throw 'Could not find the MT5 data folder. Open MT5 once, then try again.' }
Write-Host "MT5 data folder: $mql5"

$copies = @(
    @{ From = 'TradeLoggerCalc.mqh'; To = 'Include\GoldTradeLogger' },
    @{ From = 'Supertrend.mq5';      To = 'Indicators\GoldTradeLogger' },
    @{ From = 'TradeRecorder.mq5';   To = 'Experts\GoldTradeLogger' }
)
foreach ($c in $copies) {
    $dir = Join-Path $mql5 $c.To
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item (Join-Path $here $c.From) $dir -Force
}

$failed = $false
foreach ($c in $copies | Where-Object { $_.From -like '*.mq5' }) {
    $source = Join-Path (Join-Path $mql5 $c.To) $c.From
    $log = [IO.Path]::ChangeExtension($source, '.log')
    Start-Process $metaEditor -ArgumentList "/compile:`"$source`"", "/log:`"$log`"", "/inc:`"$mql5`"" -Wait
    $result = Get-Content $log -Encoding Unicode | Where-Object { $_ -match 'error|warning|result' }
    Write-Host "`n$($c.From):"
    $result | ForEach-Object { Write-Host "  $_" }
    if (($result -join ' ') -notmatch ' 0 errors') { $failed = $true }
}
if ($failed) { throw 'Compiling failed; see the errors above.' }
Write-Host "`nDone. In MT5, refresh the Navigator (right-click > Refresh) to see the new files."
