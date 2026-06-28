# Office AI Switch 网关配置指南

本文讲清楚 Office AI Switch 背后的网关链路，适合开源用户从零搭建自己的 Claude for Microsoft Office 第三方 API 网关。它适用于 Word、Excel 和 PowerPoint，因为示例 manifest 同时声明了 `Document`、`Workbook`、`Presentation` 三类 Office Host。

## 1. 整体链路

```text
Microsoft Office
  -> Word / Excel / PowerPoint
  -> Claude Office 加载项前端 https://pivot.claude.ai
  -> Enterprise Gateway URL
  -> 你的 HTTPS 域名，例如 https://word.example.com
  -> Cloudflare Tunnel
  -> 本机 http://127.0.0.1:8790
  -> gateway_unified FastAPI 网关
  -> DeepSeek / MiMo / Kimi / MiniMax / Anthropic-compatible 中转站
```

这里有两个不同的 URL：

| URL | 作用 |
|---|---|
| `https://pivot.claude.ai` | Claude Office 加载项自己的前端页面，由 Office WebView2 加载 |
| `https://word.example.com` | 你自己的 Enterprise Gateway URL，最终转发到本机 FastAPI 网关 |

如果 `pivot.claude.ai` 被代理规则弄坏，加载项会打不开；如果 `word.example.com` 不通，加载项能打开但会显示无法连接 API。

公网入口地址是可配置项。本地 `.env` 里建议写：

```env
OFFICE_AI_PUBLIC_URL=https://word.example.com
```

切换器也兼容旧变量名 `WORD_AI_PUBLIC_URL`。如果两个变量都没有配置，程序会尝试读取 `%USERPROFILE%\.cloudflared\config.yml` 里的第一个 `hostname:` 或 `- hostname:`；仍然找不到时才回退到占位地址 `https://word.example.com`，避免开源仓库里出现真实域名。

## 2. 本机网关

网关目录：

```powershell
cd gateway_unified
```

首次安装：

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -e .
```

健康检查目标：

```text
http://127.0.0.1:8790/healthz
```

手动启动 generic provider：

```powershell
$env:ACTIVE_PROVIDER="generic"
$env:GENERIC_BASE_URL="https://your-relay.example/anthropic"
$env:GENERIC_API_KEY="sk-your-upstream-key"
$env:MODEL_PRIMARY="your-pro-model"
$env:MODEL_MID="your-sonnet-model"
$env:MODEL_FAST="your-fast-model"
.\.venv\Scripts\python.exe -m uvicorn claude_gateway.main:app --host 127.0.0.1 --port 8790
```

更推荐用 Office AI Switch 管理这些值：

```powershell
python ..\word-switch-v2.py profile list
python ..\word-switch-v2.py secret save custom-relay
python ..\word-switch-v2.py profile test custom-relay
python ..\word-switch-v2.py gateway apply custom-relay
```

GUI 启动：

```powershell
powershell -ExecutionPolicy Bypass -File .\word-switch-v2-gui.ps1
```

## 3. Office AI Switch Profile

一个 profile 至少需要：

```json
{
  "id": "custom-relay",
  "name": "My Relay",
  "baseUrl": "https://your-relay.example/anthropic",
  "apiFormat": "anthropic",
  "routes": {
    "opus": "your-pro-model",
    "sonnet": "your-default-model",
    "haiku": "your-fast-model"
  }
}
```

当前稳定支持的是 Anthropic-compatible Messages API。`apiFormat=openai_chat`、`openai_responses`、`gemini_native` 是预留字段；如果上游只提供 OpenAI 或 Gemini 原生格式，需要先实现协议转换，否则不要宣称可用。

## 4. Cloudflare Tunnel

推荐用命名 tunnel，这样重启后域名不会变。

登录：

```powershell
cloudflared tunnel login
```

创建 tunnel：

```powershell
cloudflared tunnel create office-ai-switch
```

示例配置文件：

```yaml
tunnel: YOUR_TUNNEL_ID
credentials-file: C:\Users\YourName\.cloudflared\YOUR_TUNNEL_ID.json

ingress:
  - hostname: word.example.com
    service: http://127.0.0.1:8790
  - service: http_status:404
```

保存为：

```text
C:\Users\YourName\.cloudflared\config.yml
```

启动：

```powershell
cloudflared tunnel --config "$env:USERPROFILE\.cloudflared\config.yml" run office-ai-switch
```

验证：

```powershell
Invoke-WebRequest https://word.example.com/healthz
```

应返回类似：

```json
{"status":"ok","provider":"generic"}
```

## 5. DNS 配置

如果域名接入 Cloudflare，可以让 cloudflared 自动创建 DNS：

```powershell
cloudflared tunnel route dns office-ai-switch word.example.com
```

也可以手动在 Cloudflare DNS 页面添加：

```text
Type: CNAME
Name: word
Target: YOUR_TUNNEL_ID.cfargotunnel.com
Proxy: enabled
```

## 6. Office Manifest 配置

开源仓库里不要提交真实 manifest token。请从示例文件复制：

```text
word-deepseek-manifest.example.xml
```

把里面的占位符替换成你的值：

| 占位符 | 替换为 |
|---|---|
| `https%3A%2F%2Fword.example.com` | URL 编码后的 Enterprise Gateway URL |
| `your-gateway-token` | 你的网关访问 token |
| `anthropic` | 当前建议保持 anthropic |

未编码 URL：

```text
https://word.example.com
```

URL 编码后：

```text
https%3A%2F%2Fword.example.com
```

SourceLocation 形态：

```text
https://pivot.claude.ai/?m=unified-1.0.0.12&gateway_url=https%3A%2F%2Fword.example.com&gateway_token=your-gateway-token&gateway_api_format=anthropic
```

## 7. Office 侧载加载项

常见流程：

1. 打开 Word、Excel 或 PowerPoint。
2. 开发工具或 Office 加载项管理里上传 manifest。
3. 如果加载项打不开，先确认浏览器或系统能访问：

```powershell
Invoke-WebRequest https://pivot.claude.ai/
```

4. 如果加载项打开但无法连接 API，确认：

```powershell
Invoke-WebRequest https://word.example.com/healthz
```

5. 如果 Office WebView2 缓存旧错误，关闭 Word 后清理：

```text
%LOCALAPPDATA%\Microsoft\Office\16.0\Wef
```

## 8. 代理注意事项

Office 加载项前端 `pivot.claude.ai` 和你的网关域名是两条链路。部分代理节点会让 `pivot.claude.ai` TLS 握手失败。遇到加载项打不开时，优先测试：

```powershell
curl.exe -I --noproxy "*" https://pivot.claude.ai/
curl.exe -I --proxy http://127.0.0.1:7890 https://pivot.claude.ai/
```

如果直连可用、代理不可用，就把 `pivot.claude.ai` 加入代理直连规则。

## 9. 开源安全清单

发布前确认：

- [ ] `gateway_unified/.env` 没有提交。
- [ ] `%USERPROFILE%\.word-switch-v2\secrets.json` 没有复制进仓库。
- [ ] `word-deepseek-manifest.xml` 中没有真实 `gateway_token`。
- [ ] `start.ps1` 中没有个人机器绝对路径。
- [ ] README 只承诺 Anthropic-compatible 已稳定支持。
- [ ] OpenAI/Gemini 原生格式标为未完成或实验性。
