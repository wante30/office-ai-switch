# Office AI Switch v2.0.0

First public release of Office AI Switch.

## Download

Use the Windows package:

```text
OfficeAISwitch-v2.0.0-win-x64.zip
```

Unzip it, then double-click:

```text
OfficeAISwitch.exe
```

On first run, the launcher creates a local Python virtual environment under `gateway_unified\.venv` and installs the gateway dependencies automatically.

## Highlights

- Windows GUI for managing Office AI gateway profiles.
- Local FastAPI gateway compatible with Anthropic Messages API.
- Works with Claude Office add-ins in Word, Excel, and PowerPoint.
- Supports DeepSeek, Kimi, MiMo, MiniMax, and custom Anthropic-compatible relays.
- Saves API keys locally with Windows DPAPI.
- Supports Cloudflare Tunnel for a stable HTTPS gateway URL.
- Includes example Office manifest and startup script.

## Included

- `OfficeAISwitch.exe` Windows launcher
- `word-switch-v2.py` CLI
- `word-switch-v2-gui.ps1` Windows GUI
- `gateway_unified/` FastAPI gateway
- `word-deepseek-manifest.example.xml`
- `start.example.ps1`
- `docs/GATEWAY_SETUP.md`

## Requirements

- Windows 10/11
- PowerShell 5+
- Python 3.11+
- Internet access during first-run dependency installation
- Optional: Cloudflare Tunnel for a stable public HTTPS gateway URL

## Notes

This release focuses on Anthropic-compatible Messages API endpoints. OpenAI/Gemini-native protocol conversion is not yet a stable public feature.

Do not upload real `.env`, API keys, gateway tokens, personal manifest files, or Cloudflare tunnel credentials.

## Source And Credits

- Original gateway reference: [Komikawayi/excel-claude-deepseek-gateway-kit](https://github.com/Komikawayi/excel-claude-deepseek-gateway-kit)
- Web framework: [FastAPI](https://fastapi.tiangolo.com/)
- API protocol reference: [Anthropic Messages API](https://docs.anthropic.com/)
- Public gateway option: [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
