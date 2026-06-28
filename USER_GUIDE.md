# 新用户操作说明

## 一、本地使用流程（无需公网 / tunnel）

如果你只在本机使用 Word，最简单：启动本地 gateway → 配置 profile → 应用 → 导出 XML → 导入 Word。

### 1. 启动 Gateway
打开 `word-switch-v2-gui.ps1`，点击左侧底部：

```
▶ 启动 / 修复 网关
```

- 本地 gateway 地址固定为：`http://127.0.0.1:8790`
- 启动成功后，底部状态栏会显示「本地网关：运行中」。

### 2. 创建并配置 Profile

点击左侧底部：

```
+ 新建配置
```

在右侧表单填写：

| 字段 | 说明 | 示例 |
|------|------|------|
| 名称 | 显示名称 | DeepSeek 官方 |
| 预设来源 | 可忽略，留空即可 | - |
| Base URL | 上游 API 地址 | `https://api.deepseek.com/anthropic` |
| API 格式 | 上游接口协议 | `anthropic` 或 `openai_chat` |
| opus → | Word opus 对应的上游模型 | `deepseek-v4-pro` |
| sonnet → | Word sonnet 对应的上游模型 | `deepseek-v4-flash` |
| haiku → | Word haiku 对应的上游模型 | `deepseek-v4-flash` |
| API Key | 上游 API Key | `sk-...` |

填写完成后：
- 点击 `✓ 保存配置`
- 点击 `⌘ 保存 Key`

> 提示：如果填好名称和 Base URL 后不想手动配模型映射，可以点击 `⚙ 自动配置`，系统会根据接口模型名自动推荐 opus / sonnet / haiku 映射。

### 3. 测试连通性

选中配置，点击：

```
▶ 测试选中
```

- 日志显示 `[OK] xxx: 模型名，xxxms` 即表示成功。
- 如果显示 `[FAIL] 未保存 API Key`，先保存 Key 再测试。

### 4. 应用到 Gateway

点击：

```
➜ 应用网关
```

- 这会把当前 profile 写入 `.env` 并重启 gateway。
- 成功后顶部「当前实际生效」会显示该配置名称。

### 5. 导出 manifest.xml

点击：

```
↓ 导出 manifest.xml
```

- 生成文件：`word-deepseek-manifest-<profile-id>.xml`
- 导出成功后，会自动打开文件所在文件夹并选中该文件。

### 6. 导入 Word

在 Word 中操作：

1. 点击「插入」→「获取加载项」→「我的加载项」
2. 选择「管理我的加载项」或「上传我的加载项」
3. 选择刚才导出的 `.xml` 文件
4. Word 工具栏出现 Claude 按钮，点击即可使用

> 注意：Word 必须和 gateway 在同一台电脑，因为使用的是本地地址 `127.0.0.1:8790`。

---

## 二、远程/多机使用流程（需要公网入口）

如果你想在其他电脑或远程使用 Word 插件，需要配置 cloudflared tunnel。

### 1. 安装 cloudflared

1. 下载 `cloudflared.exe`：https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
2. 把 `cloudflared.exe` 放到 `%USERPROFILE%` 目录下（即 `C:\Users\你的用户名\`）

### 2. 登录并创建 tunnel

以管理员身份打开 PowerShell，依次执行：

```powershell
cd ~
.\cloudflared.exe tunnel login
.\cloudflared.exe tunnel create word-deepseek
```

### 3. 配置 config.yml

编辑或创建文件：

```
C:\Users\你的用户名\.cloudflared\config.yml
```

内容示例：

```yaml
tunnel: <你的 tunnel UUID>
credentials-file: C:\Users\你的用户名\.cloudflared\<你的 tunnel UUID>.json

ingress:
  - hostname: word.yourdomain.com
    service: http://127.0.0.1:8790
  - service: http_status:404
```

其中 `word.yourdomain.com` 是你在 Cloudflare 控制台绑定的域名。

### 4. 启动 Gateway

回到 GUI，点击：

```
▶ 启动 / 修复 网关
```

程序会自动启动 cloudflared tunnel，公网入口会显示在状态栏。

### 5. 导出 manifest.xml

选中 profile 后点击：

```
↓ 导出 manifest.xml
```

此时 `gateway_url` 会自动使用公网地址。

### 6. 导入 Word

和本地流程相同，将 XML 导入任意电脑的 Word 即可使用。

> 注意：每次重启临时 cloudflared tunnel 后公网 URL 可能会变化，需要重新导出 manifest.xml。如果使用固定域名则不会变。

---

## 三、常见问题

### Q1：导出的 XML 有什么用？
A：它是 Office 插件清单文件。Word 通过它知道插件入口网页地址，以及应该把 AI 请求发往哪个 gateway。

### Q2：gateway_token 是什么？
A：它是访问本地/公网 gateway 的鉴权密码。第一次导出时程序会自动生成并保存到 `.env`，之后固定不变。

### Q3：不配置 tunnel 能用吗？
A：能。只要 Word 和 gateway 在同一台电脑，使用本地地址 `127.0.0.1:8790` 即可。

### Q4：修改 profile 后需要重新导出 XML 吗？
A：如果只是改上游模型或 API Key，不需要。但如果改了 `gateway_url`（比如从本地切换到公网），或者改了 `apiFormat`，建议重新导出。

### Q5：为什么测试配置时提示「未保存 API Key」？
A：在「API Key」框填入上游 Key 后，必须点「保存 Key」按钮，不能只点「保存配置」。

### Q6：应用网关后还需要重新启动 Word 吗？
A：不需要。Word 里的插件每次请求都会连到当前运行的 gateway。

### Q7：批量测试和单个测试有什么区别？
A：批量测试会依次测试所有已保存的 profile，方便一次性检查所有上游是否可用。

### Q8：自动配置可靠吗？
A：自动配置会根据模型名推荐映射，但不同上游的模型名可能不标准，推荐后建议再检查一遍。

### Q9：GUI 打开后中文乱码怎么办？
A：确认 `word-switch-v2-gui.ps1` 以 UTF-8 保存（默认就是）。PowerShell 5.1 下若仍乱码，先执行：

```powershell
chcp 65001
```

再启动 GUI。

### Q10：保存 API Key 后测试仍提示「未保存 Key」？
A：
- 确认点的是「保存 Key」而不是「保存配置」。两者分开。
- 检查 `%USERPROFILE%\.word-switch-v2\secrets.json` 是否有该 profile 的条目（内容是 DPAPI 密文）。
- 换机器后 `secrets.json` 不可用（DPAPI 绑定当前用户/机器），需重新保存 Key。

### Q11：「应用到 Word 网关」失败？
A：常见原因：
- 端口 8790 被占用：`netstat -ano | findstr :8790`，杀掉旧进程。
- `.venv` 不存在或损坏：重新创建 Python 虚拟环境。
- `cloudflared.exe` 不在 `%USERPROFILE%\cloudflared.exe`：从 [cloudflared releases](https://github.com/cloudflare/cloudflared/releases) 下载。

### Q12：Office 加载项打不开 / 显示空白？
A：
- 用 `start-word-fixed.ps1` 清理 Office 加载项缓存。
- 确认 `word-deepseek-manifest.xml` 里的 `SourceLocation` 指向你的公网域名。
- Office 完全退出后重新打开（任务管理器确认 `WINWORD.EXE` / `EXCEL.EXE` / `POWERPNT.EXE` 相关进程已结束）。

### Q13：批量测试全部失败？
A：
- 确认所有 profile 已保存 Key（无 Key 的 profile 一定会失败）。
- 单点「测试选中配置」验证单个 profile 是否能通过。
- 网络/DNS 问题会导致批量测试大面积失败，先确认能 `curl` 上游。

### Q14：公网入口测试失败但本地测试通过？
A：
- `cloudflared.exe` 没启动：用 GUI「启动 / 修复 网关」或 `start.ps1`。
- 域名未指向当前 tunnel：检查 Cloudflare 控制台 DNS。
- Tunnel 配置文件位置：`%USERPROFILE%\.cloudflared\config.yml`。
