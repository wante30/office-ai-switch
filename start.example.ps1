# Office AI Switch example launcher
# Copy this file to start.ps1 and adjust paths before using it.

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$GatewayDir = Join-Path $ProjectRoot "gateway_unified"
$Cloudflared = Join-Path $env:USERPROFILE "cloudflared.exe"
$CloudflaredConfig = Join-Path $env:USERPROFILE ".cloudflared\config.yml"
$TunnelName = "office-ai-switch"

Write-Host "=== Starting Office AI Switch Gateway ===" -ForegroundColor Green

Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-ExecutionPolicy", "Bypass",
    "-Command",
    "cd '$GatewayDir'; Write-Host 'Gateway on http://127.0.0.1:8790' -ForegroundColor Cyan; .\.venv\Scripts\python.exe -m uvicorn claude_gateway.main:app --host 127.0.0.1 --port 8790"
)

Start-Sleep -Seconds 3

Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-ExecutionPolicy", "Bypass",
    "-Command",
    "Write-Host 'Cloudflare Tunnel starting...' -ForegroundColor Cyan; & '$Cloudflared' tunnel --config '$CloudflaredConfig' run '$TunnelName'"
)

Write-Host "Both processes started. Keep both windows open." -ForegroundColor Yellow
