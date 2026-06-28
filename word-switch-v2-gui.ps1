# Word AI Switch v2 - Native desktop GUI (schema v3, optimized)
# 布局：左侧配置列表 + 右侧详情 + 底部状态栏
# 关键修复：
#   1. Invoke-Background 通过 payload hashtable 显式传参，解决 Runspace 变量作用域 bug（无限加载根因）
#   2. Refresh-All 改为后台异步执行，UI 不冻结
#   3. 选中状态强化：左侧 4px 蓝色指示条 + 名称加粗，不重建整个列表
#   4. 30 秒超时警告 + 60 秒进程强制终止，防止无限转圈
#   5. 统一字体 Microsoft YaHei UI，保证中文显示
#   6. 按钮 2 行布局，间距统一

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.ComponentModel

if (-not ("WordSwitchV2GuiNative.ConsoleWindow" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace WordSwitchV2GuiNative {
    public static class ConsoleWindow {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    }
}
"@
}
$consoleWindow = [WordSwitchV2GuiNative.ConsoleWindow]::GetConsoleWindow()
if ($consoleWindow -ne [IntPtr]::Zero) {
    [void][WordSwitchV2GuiNative.ConsoleWindow]::ShowWindow($consoleWindow, 0)
}

[System.Windows.Forms.Application]::EnableVisualStyles()

# --- 路径与常量 ---
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Python = Join-Path $Root "gateway_unified\.venv\Scripts\python.exe"
if (-not (Test-Path $Python)) { $Python = "python" }
$Backend = Join-Path $Root "word-switch-v2.py"
$StateDir = Join-Path $env:USERPROFILE ".word-switch-v2"
$StateFile = Join-Path $StateDir "state.json"
$WelcomeFile = Join-Path $StateDir "welcome-shown.json"

# 统一字体（Microsoft YaHei UI 保证中文显示）
$FontUi = [System.Drawing.Font]::new("Microsoft YaHei UI", 9)
$FontUiBold = [System.Drawing.Font]::new("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$FontTitle = [System.Drawing.Font]::new("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
$FontBrand = [System.Drawing.Font]::new("Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold)
$FontMono = [System.Drawing.Font]::new("Consolas", 9)

# 颜色方案
$ColorBgDark = [System.Drawing.Color]::FromArgb(15, 23, 42)
$ColorSidebar = [System.Drawing.Color]::FromArgb(24, 32, 50)
$ColorCard = [System.Drawing.Color]::FromArgb(30, 41, 59)
$ColorCardActive = [System.Drawing.Color]::FromArgb(12, 43, 63)
$ColorPanelLight = [System.Drawing.Color]::FromArgb(245, 247, 250)
$ColorWhite = [System.Drawing.Color]::White
$ColorTextMain = [System.Drawing.Color]::FromArgb(241, 245, 249)
$ColorTextSub = [System.Drawing.Color]::FromArgb(148, 163, 184)
$ColorAccent = [System.Drawing.Color]::FromArgb(59, 130, 246)
$ColorSuccess = [System.Drawing.Color]::FromArgb(34, 197, 94)
$ColorWarning = [System.Drawing.Color]::FromArgb(245, 158, 11)

# 按钮语义色
$ColorBtnPrimary = [System.Drawing.Color]::FromArgb(37, 99, 235)      # 蓝：保存、应用、启动
$ColorBtnSuccess = [System.Drawing.Color]::FromArgb(5, 150, 105)      # 绿：测试、新建
$ColorBtnDanger = [System.Drawing.Color]::FromArgb(220, 38, 38)       # 红：删除
$ColorBtnSecondary = [System.Drawing.Color]::FromArgb(100, 116, 139)  # 灰：次要操作

# --- 共享状态 ---
$script:StatusCache = $null
$script:Profiles = @()
$script:Presets = @()
$script:SelectedId = ""
$script:ActiveId = ""
$script:KeyDirty = $false
$script:LoadingProfile = $false
$script:Busy = $false
$script:BusyAction = ""
$script:BusyStartTime = 0
$script:LastProfileCount = -1
$script:TimeoutWarned = $false
$script:ForceRender = $false
$script:ProcessingResult = $false
$script:PreserveKeyOnReload = $false

# --- Runspace 池 ---
$script:Sync = [hashtable]::Synchronized(@{ Results = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new()); })
$script:RunspacePool = [runspacefactory]::CreateRunspacePool(1, 2)
$script:RunspacePool.ApartmentState = "STA"
$script:RunspacePool.ThreadOptions = "ReuseThread"
$script:RunspacePool.Open()

# 后台执行：所有变量通过 $Payload hashtable 显式传入
# 解决 Runspace 不继承 $script:/父作用域变量的 bug（无限加载根因）
function Invoke-Background([hashtable]$Payload, [string]$Tag = "job") {
    $powershell = [powershell]::Create()
    $powershell.AddScript({
        param($Payload, $Sync, $Tag, $Backend, $Python)

        # 在 runspace 内部定义进程调用函数（runspace 看不到外部函数）
        function Run-Python([string[]]$Arguments, [string]$StandardInput = "", [bool]$WriteStdin = $false) {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $Python
            $psi.Arguments = '"' + $Backend + '" ' + ($Arguments -join ' ')
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $WriteStdin
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            # 关键：强制 Python 使用 UTF-8 模式，解决中文乱码
            $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
            $psi.EnvironmentVariables["PYTHONUTF8"] = "1"
            $proc = [System.Diagnostics.Process]::Start($psi)
            if ($WriteStdin) {
                # 用 UTF-8 字节流写入 stdin，避免 PowerShell StreamWriter 默认编码导致中文变 ????
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($StandardInput)
                $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
                $proc.StandardInput.BaseStream.Flush()
                $proc.StandardInput.Close()
            }
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $exitOk = $proc.WaitForExit(60000)
            if (-not $exitOk) {
                try { $proc.Kill() } catch {}
                return [pscustomobject]@{ ExitCode = -1; Output = "操作超时（60 秒），后端进程已被强制终止。" }
            }
            return [pscustomobject]@{
                ExitCode = $proc.ExitCode
                Output = ($stdout + "`n" + $stderr).Trim()
            }
        }

        $result = $null
        switch ($Payload.Action) {
            "refresh" {
                Run-Python @("init") | Out-Null
                $result = Run-Python @("gateway", "status", "--local")
            }
            "save-profile" {
                $result = Run-Python @("profile", "save", "--stdin") $Payload.Json $true
            }
            "save-key" {
                $result = Run-Python @("secret", "save", $Payload.Id, "--stdin") $Payload.Key $true
            }
            "auto-configure" {
                if ($Payload.UseStdin) {
                    $result = Run-Python @("profile", "auto-configure", $Payload.Id, "--stdin") $Payload.Key $true
                } else {
                    $result = Run-Python @("profile", "auto-configure", $Payload.Id)
                }
            }
            "test-selected" {
                $result = Run-Python @("profile", "test", $Payload.Id)
            }
            "apply" {
                $result = Run-Python @("gateway", "apply", $Payload.Id)
            }
            "test-public" {
                $result = Run-Python @("gateway", "test-public")
            }
            "delete-profile" {
                $result = Run-Python @("profile", "delete", $Payload.Id)
            }
            "export-manifest" {
                $result = Run-Python @("profile", "export-manifest", $Payload.Id)
            }
            "batch-test" {
                $results = @()
                $idsStr = [string]$Payload.IdsStr
                # 用正则 Split，避免 PowerShell -split 在 Runspace 中行为异常；不再强制 [string[]] 转换
                $ids = [System.Text.RegularExpressions.Regex]::Split($idsStr, '\|')
                for ($i = 0; $i -lt $ids.Length; $i++) {
                    $profileId = $ids[$i]
                    if ([string]::IsNullOrWhiteSpace($profileId)) { continue }
                    $r = Run-Python @("profile", "test", $profileId)
                    $output = $r.Output
                    try { $output | ConvertFrom-Json | Out-Null } catch {
                        $output = @{ status = "failed"; message = "进程错误(exit=$($r.ExitCode)): $output" } | ConvertTo-Json -Compress
                    }
                    $results += @{ id = $profileId; exitCode = $r.ExitCode; output = $output }
                }
                if ($results.Count -eq 0) {
                    $json = "[]"
                } else {
                    $json = ConvertTo-Json -InputObject $results -Compress -Depth 5
                    if ([string]::IsNullOrWhiteSpace($json)) { $json = "[]" }
                }
                $result = [pscustomobject]@{ ExitCode = 0; Output = $json }
            }
            "start" {
                $result = Run-Python @("gateway", "start")
            }
            default {
                $result = [pscustomobject]@{ ExitCode = -1; Output = "Unknown action: [$($Payload.Action)] keys=$($Payload.Keys -join ',')" }
            }
        }
        $Sync.Results.Enqueue(@{ Tag = $Tag; Result = $result; Action = [string]$Payload.Action })
    }).AddArgument($Payload).AddArgument($script:Sync).AddArgument($Tag).AddArgument($Backend).AddArgument($Python) | Out-Null
    $powershell.RunspacePool = $script:RunspacePool
    $powershell.BeginInvoke() | Out-Null
}

# --- Form ---
$form = [System.Windows.Forms.Form]::new()
$form.Text = "Word AI Switch v2"
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.ClientSize = [System.Drawing.Size]::new(1280, 820)
$form.MinimumSize = [System.Drawing.Size]::new(1120, 740)
$form.BackColor = $ColorPanelLight
$form.Font = $FontUi

# === Sidebar (左) ===
$sidebar = [System.Windows.Forms.Panel]::new()
$sidebar.Dock = [System.Windows.Forms.DockStyle]::Left
$sidebar.Width = 360
$sidebar.BackColor = $ColorSidebar
$form.Controls.Add($sidebar)

# === 左侧栏顶部装饰条（accent 渐变模拟）===
$sidebarAccent = [System.Windows.Forms.Panel]::new()
$sidebarAccent.Location = [System.Drawing.Point]::new(0, 0)
$sidebarAccent.Size = [System.Drawing.Size]::new(360, 4)
$sidebarAccent.BackColor = $ColorAccent
$sidebarAccent.Dock = [System.Windows.Forms.DockStyle]::Top
$sidebar.Controls.Add($sidebarAccent)

$brand = [System.Windows.Forms.Label]::new()
$brand.Text = "WORD AI SWITCH"
$brand.Location = [System.Drawing.Point]::new(20, 24)
$brand.Size = [System.Drawing.Size]::new(270, 30)
$brand.Font = $FontBrand
$brand.ForeColor = $ColorWhite
$brand.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($brand)

$subtitle = [System.Windows.Forms.Label]::new()
$subtitle.Text = "Claude for Word 配置管理 v2"
$subtitle.Location = [System.Drawing.Point]::new(20, 58)
$subtitle.Size = [System.Drawing.Size]::new(320, 20)
$subtitle.ForeColor = $ColorTextSub
$subtitle.Font = $FontUi
$subtitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($subtitle)

$helpButton = [System.Windows.Forms.Button]::new()
$helpButton.Text = "?"
$helpButton.Location = [System.Drawing.Point]::new(308, 22)
$helpButton.Size = [System.Drawing.Size]::new(36, 34)
$helpButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$helpButton.FlatAppearance.BorderSize = 0
$helpButton.BackColor = $ColorAccent
$helpButton.ForeColor = $ColorWhite
$helpButton.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 12, [System.Drawing.FontStyle]::Bold)
$helpButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$helpButton.Add_Click({ Open-UserGuide })
$helpButton.BringToFront()
$sidebar.Controls.Add($helpButton)

$helpTooltip = [System.Windows.Forms.ToolTip]::new()
$helpTooltip.SetToolTip($helpButton, "查看帮助说明")

$divider = [System.Windows.Forms.Panel]::new()
$divider.Location = [System.Drawing.Point]::new(20, 90)
$divider.Size = [System.Drawing.Size]::new(320, 1)
$divider.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$divider.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($divider)

# 搜索框
$searchBox = [System.Windows.Forms.TextBox]::new()
$searchBox.Location = [System.Drawing.Point]::new(20, 102)
$searchBox.Size = [System.Drawing.Size]::new(320, 30)
$searchBox.Font = $FontUi
$searchBox.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$searchBox.ForeColor = $ColorTextMain
$searchBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$searchBox.Text = "搜索配置..."
$searchBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($searchBox)

# 配置列表标题 + 计数
$listHeader = [System.Windows.Forms.Label]::new()
$listHeader.Text = "配置列表"
$listHeader.Location = [System.Drawing.Point]::new(20, 142)
$listHeader.Size = [System.Drawing.Size]::new(160, 18)
$listHeader.Font = $FontUiBold
$listHeader.ForeColor = $ColorTextSub
$sidebar.Controls.Add($listHeader)

$listCountLabel = [System.Windows.Forms.Label]::new()
$listCountLabel.Text = "0 个"
$listCountLabel.Location = [System.Drawing.Point]::new(280, 142)
$listCountLabel.Size = [System.Drawing.Size]::new(60, 18)
$listCountLabel.Font = $FontUiBold
$listCountLabel.ForeColor = $ColorAccent
$listCountLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$listCountLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($listCountLabel)

$profileListPanel = [System.Windows.Forms.Panel]::new()
$profileListPanel.Location = [System.Drawing.Point]::new(12, 168)
$profileListPanel.Size = [System.Drawing.Size]::new(336, 440)
$profileListPanel.AutoScroll = $true
$profileListPanel.BackColor = $ColorSidebar
$profileListPanel.Padding = [System.Windows.Forms.Padding]::new(0, 4, 0, 4)
# 高度自适应：Top + Bottom anchor 让列表区随窗口高度缩放
$profileListPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$sidebar.Controls.Add($profileListPanel)

# === 底部按钮区（Dock=Bottom，永远贴底，自适应） ===
$sidebarBottom = [System.Windows.Forms.Panel]::new()
$sidebarBottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
$sidebarBottom.Height = 148
$sidebarBottom.BackColor = $ColorSidebar
$sidebar.Controls.Add($sidebarBottom)

# 第一排：新建 + 刷新
$newButton = [System.Windows.Forms.Button]::new()
$newButton.Text = "+ 新建配置"
$newButton.Location = [System.Drawing.Point]::new(20, 4)
$newButton.Size = [System.Drawing.Size]::new(155, 36)
$newButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$newButton.FlatAppearance.BorderSize = 0
$newButton.BackColor = $ColorBtnSuccess
$newButton.ForeColor = $ColorWhite
$newButton.Font = $FontUiBold
$newButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$sidebarBottom.Controls.Add($newButton)

$refreshButton = [System.Windows.Forms.Button]::new()
$refreshButton.Text = "↻ 刷新"
$refreshButton.Location = [System.Drawing.Point]::new(185, 4)
$refreshButton.Size = [System.Drawing.Size]::new(155, 36)
$refreshButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$refreshButton.FlatAppearance.BorderSize = 0
$refreshButton.BackColor = $ColorBtnSecondary
$refreshButton.ForeColor = $ColorWhite
$refreshButton.Font = $FontUiBold
$refreshButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$sidebarBottom.Controls.Add($refreshButton)

# 第二排：删除当前 + 复制当前
$sidebarDeleteButton = [System.Windows.Forms.Button]::new()
$sidebarDeleteButton.Text = "× 删除当前"
$sidebarDeleteButton.Location = [System.Drawing.Point]::new(20, 44)
$sidebarDeleteButton.Size = [System.Drawing.Size]::new(155, 36)
$sidebarDeleteButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$sidebarDeleteButton.FlatAppearance.BorderSize = 0
$sidebarDeleteButton.BackColor = $ColorBtnDanger
$sidebarDeleteButton.ForeColor = $ColorWhite
$sidebarDeleteButton.Font = $FontUiBold
$sidebarDeleteButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$sidebarBottom.Controls.Add($sidebarDeleteButton)

$sidebarCopyButton = [System.Windows.Forms.Button]::new()
$sidebarCopyButton.Text = "⧉ 复制当前"
$sidebarCopyButton.Location = [System.Drawing.Point]::new(185, 44)
$sidebarCopyButton.Size = [System.Drawing.Size]::new(155, 36)
$sidebarCopyButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$sidebarCopyButton.FlatAppearance.BorderSize = 0
$sidebarCopyButton.BackColor = $ColorBtnSecondary
$sidebarCopyButton.ForeColor = $ColorWhite
$sidebarCopyButton.Font = $FontUiBold
$sidebarCopyButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$sidebarBottom.Controls.Add($sidebarCopyButton)

# 第三排：启动 / 修复 网关（全宽）
$startButton = [System.Windows.Forms.Button]::new()
$startButton.Text = "▶ 启动 / 修复 网关"
$startButton.Location = [System.Drawing.Point]::new(20, 84)
$startButton.Size = [System.Drawing.Size]::new(320, 36)
$startButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$startButton.FlatAppearance.BorderSize = 0
$startButton.BackColor = $ColorBtnPrimary
$startButton.ForeColor = $ColorWhite
$startButton.Font = $FontUiBold
$startButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$sidebarBottom.Controls.Add($startButton)

# 侧栏底部版权
$sidebarFooter = [System.Windows.Forms.Label]::new()
$sidebarFooter.Text = "v2.0 · MIT License"
$sidebarFooter.Location = [System.Drawing.Point]::new(20, 124)
$sidebarFooter.Size = [System.Drawing.Size]::new(320, 16)
$sidebarFooter.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 8)
$sidebarFooter.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$sidebarFooter.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$sidebarBottom.Controls.Add($sidebarFooter)

# === Main panel (右) ===
$mainPanel = [System.Windows.Forms.Panel]::new()
$mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainPanel.Padding = [System.Windows.Forms.Padding]::new(24, 20, 24, 16)
$mainPanel.BackColor = $ColorPanelLight
$form.Controls.Add($mainPanel)
$mainPanel.BringToFront()

$title = [System.Windows.Forms.Label]::new()
$title.Text = "Claude for Word Gateway"
$title.Location = [System.Drawing.Point]::new(24, 20)
$title.Size = [System.Drawing.Size]::new(760, 30)
$title.Font = $FontTitle
$title.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$title.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$mainPanel.Controls.Add($title)

# Active card — Dock=Top
$activeCard = [System.Windows.Forms.Panel]::new()
$activeCard.Location = [System.Drawing.Point]::new(24, 58)
$activeCard.Size = [System.Drawing.Size]::new(872, 100)
$activeCard.BackColor = $ColorWhite
$activeCard.Dock = [System.Windows.Forms.DockStyle]::Top
$mainPanel.Controls.Add($activeCard)

$activeTitle = [System.Windows.Forms.Label]::new()
$activeTitle.Text = "当前实际生效"
$activeTitle.Location = [System.Drawing.Point]::new(16, 10)
$activeTitle.Size = [System.Drawing.Size]::new(200, 18)
$activeTitle.Font = $FontUiBold
$activeTitle.ForeColor = $ColorTextSub
$activeCard.Controls.Add($activeTitle)

$activeName = [System.Windows.Forms.Label]::new()
$activeName.Text = "未应用"
$activeName.Location = [System.Drawing.Point]::new(16, 30)
$activeName.Size = [System.Drawing.Size]::new(620, 26)
$activeName.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
$activeName.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$activeCard.Controls.Add($activeName)

$gatewayStatusBadge = [System.Windows.Forms.Label]::new()
$gatewayStatusBadge.Text = "Gateway 已停止"
$gatewayStatusBadge.Location = [System.Drawing.Point]::new(660, 32)
$gatewayStatusBadge.Size = [System.Drawing.Size]::new(120, 22)
$gatewayStatusBadge.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 8, [System.Drawing.FontStyle]::Bold)
$gatewayStatusBadge.ForeColor = $ColorWhite
$gatewayStatusBadge.BackColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$gatewayStatusBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$gatewayStatusBadge.Padding = [System.Windows.Forms.Padding]::new(8, 2, 8, 2)
$activeCard.Controls.Add($gatewayStatusBadge)

$activeDetail = [System.Windows.Forms.Label]::new()
$activeDetail.Text = "Loading..."
$activeDetail.Location = [System.Drawing.Point]::new(16, 60)
$activeDetail.Size = [System.Drawing.Size]::new(840, 32)
$activeDetail.Font = $FontUi
$activeDetail.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$activeDetail.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$activeCard.Controls.Add($activeDetail)

# Detail card — Dock=Fill 自动填满剩余空间
$detailCard = [System.Windows.Forms.Panel]::new()
$detailCard.Location = [System.Drawing.Point]::new(24, 168)
$detailCard.Size = [System.Drawing.Size]::new(872, 500)
$detailCard.BackColor = $ColorWhite
$detailCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$detailCard.Padding = [System.Windows.Forms.Padding]::new(0, 0, 0, 8)
$mainPanel.Controls.Add($detailCard)

$detailTitle = [System.Windows.Forms.Label]::new()
$detailTitle.Text = "配置详情"
$detailTitle.Location = [System.Drawing.Point]::new(16, 12)
$detailTitle.Size = [System.Drawing.Size]::new(200, 22)
$detailTitle.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 11, [System.Drawing.FontStyle]::Bold)
$detailTitle.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$detailCard.Controls.Add($detailTitle)

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 18, [System.Drawing.ContentAlignment]$Align = [System.Drawing.ContentAlignment]::MiddleLeft) {
    $label = [System.Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [System.Drawing.Point]::new($X, $Y)
    $label.Size = [System.Drawing.Size]::new($Width, $Height)
    $label.Font = $FontUi
    $label.ForeColor = $ColorTextSub
    $label.TextAlign = $Align
    return $label
}

function New-TextBox([int]$X, [int]$Y, [int]$Width, [bool]$Password = $false, [int]$Height = 28) {
    $box = [System.Windows.Forms.TextBox]::new()
    $box.Location = [System.Drawing.Point]::new($X, $Y)
    $box.Size = [System.Drawing.Size]::new($Width, $Height)
    $box.Font = $FontUi
    $box.UseSystemPasswordChar = $Password
    return $box
}

function Shift-Color([System.Drawing.Color]$Color, [int]$Amount) {
    $r = [math]::Max(0, [math]::Min(255, $Color.R + $Amount))
    $g = [math]::Max(0, [math]::Min(255, $Color.G + $Amount))
    $b = [math]::Max(0, [math]::Min(255, $Color.B + $Amount))
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function New-Button([string]$Text, [int]$X, [int]$Y, [int]$Width, [System.Drawing.Color]$Color) {
    $button = [System.Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Location = [System.Drawing.Point]::new($X, $Y)
    $button.Size = [System.Drawing.Size]::new($Width, 34)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $Color
    $button.ForeColor = $ColorWhite
    $button.Font = $FontUiBold
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.FlatAppearance.MouseOverBackColor = (Shift-Color $Color 30)
    $button.FlatAppearance.MouseDownBackColor = (Shift-Color $Color -30)
    return $button
}

# 为侧栏底部按钮统一添加悬停/按下反馈
foreach ($sbBtn in @($newButton, $refreshButton, $sidebarDeleteButton, $sidebarCopyButton, $startButton)) {
    $sbBtn.FlatAppearance.MouseOverBackColor = (Shift-Color $sbBtn.BackColor 30)
    $sbBtn.FlatAppearance.MouseDownBackColor = (Shift-Color $sbBtn.BackColor -30)
}

# 表单字段 - 统一两列布局，标签右对齐
$lblW = 80
$leftInputX = 100
$leftInputW = 340
$rightLabelX = 452
$rightInputX = 536
$rightInputW = 330
$rightAlign = [System.Drawing.ContentAlignment]::MiddleRight

# 第 1 行：名称 + 预设
$detailCard.Controls.Add((New-Label "名称" 16 40 $lblW 28 $rightAlign))
$nameBox = New-TextBox $leftInputX 38 $leftInputW
$detailCard.Controls.Add($nameBox)

$detailCard.Controls.Add((New-Label "预设来源" $rightLabelX 40 $lblW 28 $rightAlign))
$presetBox = [System.Windows.Forms.ComboBox]::new()
$presetBox.Location = [System.Drawing.Point]::new($rightInputX, 38)
$presetBox.Size = [System.Drawing.Size]::new($rightInputW, 28)
$presetBox.Font = $FontUi
$presetBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$detailCard.Controls.Add($presetBox)

# 第 2 行：Base URL
$detailCard.Controls.Add((New-Label "Base URL" 16 76 $lblW 28 $rightAlign))
$baseUrlBox = New-TextBox $leftInputX 74 766
$detailCard.Controls.Add($baseUrlBox)

# 第 3 行：API 格式 + Key 状态
$detailCard.Controls.Add((New-Label "API 格式" 16 112 $lblW 28 $rightAlign))
$apiFormatBox = [System.Windows.Forms.ComboBox]::new()
$apiFormatBox.Location = [System.Drawing.Point]::new($leftInputX, 110)
$apiFormatBox.Size = [System.Drawing.Size]::new($leftInputW, 28)
$apiFormatBox.Font = $FontUi
$apiFormatBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$apiFormatBox.Items.Add("anthropic")
[void]$apiFormatBox.Items.Add("openai_chat (尚未启用)")
[void]$apiFormatBox.Items.Add("openai_responses (尚未启用)")
[void]$apiFormatBox.Items.Add("gemini_native (尚未启用)")
$detailCard.Controls.Add($apiFormatBox)

$detailCard.Controls.Add((New-Label "Key 状态" $rightLabelX 112 $lblW 28 $rightAlign))
$keyStateLabel = [System.Windows.Forms.Label]::new()
$keyStateLabel.Location = [System.Drawing.Point]::new($rightInputX, 110)
$keyStateLabel.Size = [System.Drawing.Size]::new($rightInputW, 28)
$keyStateLabel.Font = $FontUiBold
$keyStateLabel.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$keyStateLabel.Text = "未保存"
$keyStateLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$detailStateLabel = $keyStateLabel
$detailCard.Controls.Add($keyStateLabel)

# 第 4 行：模型映射标题
$detailCard.Controls.Add((New-Label "模型映射（Word 别名 → 上游模型）" 16 150 840))

# 第 5 行：opus + sonnet
$detailCard.Controls.Add((New-Label "opus →" 16 174 $lblW 28 $rightAlign))
$opusBox = New-TextBox $leftInputX 172 $leftInputW
$detailCard.Controls.Add($opusBox)

$detailCard.Controls.Add((New-Label "sonnet →" $rightLabelX 174 $lblW 28 $rightAlign))
$sonnetBox = New-TextBox $rightInputX 172 $rightInputW
$detailCard.Controls.Add($sonnetBox)

# 第 6 行：haiku + API Key
$detailCard.Controls.Add((New-Label "haiku →" 16 210 $lblW 28 $rightAlign))
$haikuBox = New-TextBox $leftInputX 208 $leftInputW
$detailCard.Controls.Add($haikuBox)

$detailCard.Controls.Add((New-Label "API Key" $rightLabelX 210 $lblW 28 $rightAlign))
$keyBox = New-TextBox $rightInputX 208 $rightInputW $true
if ($keyBox.PlaceholderText -is [string]) { $keyBox.PlaceholderText = "留空不覆盖已保存 Key" }
$detailCard.Controls.Add($keyBox)

# 按钮 - 三行布局
$saveProfileButton = New-Button "✓ 保存配置" 16 260 150 $ColorBtnPrimary
$saveKeyButton = New-Button "⌘ 保存 Key" 176 260 130 $ColorBtnSecondary
$autoButton = New-Button "⚙ 自动配置" 316 260 150 $ColorBtnSecondary
$detailCard.Controls.AddRange(@($saveProfileButton, $saveKeyButton, $autoButton))

$testButton = New-Button "▶ 测试选中" 16 298 140 $ColorBtnSuccess
$applyButton = New-Button "➜ 应用网关" 166 298 140 $ColorBtnPrimary
$testPublicButton = New-Button "↗ 测试公网" 316 298 140 $ColorBtnSuccess
$detailCard.Controls.AddRange(@($testButton, $applyButton, $testPublicButton))

$copyButton = New-Button "⧉ 复制配置" 16 336 140 $ColorBtnSecondary
$batchTestButton = New-Button "⚡ 批量测试" 166 336 140 $ColorBtnSuccess
$deleteButton = New-Button "× 删除配置" 316 336 140 $ColorBtnDanger
$detailCard.Controls.AddRange(@($copyButton, $batchTestButton, $deleteButton))

$exportManifestButton = New-Button "↓ 导出 manifest.xml" 16 374 200 $ColorBtnSecondary
$detailCard.Controls.Add($exportManifestButton)

# Log card — Dock=Bottom 永远贴底
$logCard = [System.Windows.Forms.Panel]::new()
$logCard.Location = [System.Drawing.Point]::new(24, 678)
$logCard.Size = [System.Drawing.Size]::new(872, 200)
$logCard.BackColor = $ColorBgDark
$logCard.Dock = [System.Windows.Forms.DockStyle]::Bottom
$mainPanel.Controls.Add($logCard)
$logTitle = [System.Windows.Forms.Label]::new()
$logTitle.Text = "操作日志 / 最近测试结果"
$logTitle.Location = [System.Drawing.Point]::new(12, 6)
$logTitle.Size = [System.Drawing.Size]::new(300, 18)
$logTitle.Font = $FontUiBold
$logTitle.ForeColor = $ColorTextSub
$logCard.Controls.Add($logTitle)

# 日志清空按钮
$logClearButton = [System.Windows.Forms.Button]::new()
$logClearButton.Text = "清空"
$logClearButton.Location = [System.Drawing.Point]::new(820, 4)
$logClearButton.Size = [System.Drawing.Size]::new(40, 22)
$logClearButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$logClearButton.FlatAppearance.BorderSize = 0
$logClearButton.BackColor = $ColorBgDark
$logClearButton.ForeColor = $ColorTextSub
$logClearButton.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 8)
$logClearButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$logClearButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$logClearButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$logClearButton.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$logCard.Controls.Add($logClearButton)

$logBox = [System.Windows.Forms.RichTextBox]::new()
$logBox.Location = [System.Drawing.Point]::new(12, 30)
$logBox.Size = [System.Drawing.Size]::new(848, 162)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$logBox.BackColor = [System.Drawing.Color]::FromArgb(2, 6, 23)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$logBox.Font = $FontMono
$logBox.Text = "就绪。公网入口检查只在点击「测试公网入口」按钮时执行。"
$logBox.Dock = [System.Windows.Forms.DockStyle]::Bottom
$logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$logCard.Controls.Add($logBox)

# 绑定清空按钮事件
$logClearButton.Add_Click({
    $logBox.Clear()
    $logBox.Text = "[$(Get-Date -Format 'HH:mm:ss')] 日志已清空。"
})

# Status bar
$statusBar = [System.Windows.Forms.Label]::new()
$statusBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$statusBar.Height = 32
$statusBar.Font = $FontUi
$statusBar.ForeColor = $ColorTextMain
$statusBar.BackColor = $ColorBgDark
$statusBar.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusBar.Padding = [System.Windows.Forms.Padding]::new(20, 0, 20, 0)
$statusBar.Text = "本地网关：未知 | 公网入口：未测试 | 当前启用：- | Word sonnet → -"
$form.Controls.Add($statusBar)

# === 逻辑函数 ===

function Set-Busy([string]$Action = "") {
    $script:Busy = ($Action -ne "")
    $script:BusyAction = $Action
    $script:BusyStartTime = if ($script:Busy) { [System.Environment]::TickCount } else { 0 }
    $script:TimeoutWarned = $false
    $form.UseWaitCursor = $script:Busy
    $controls = @($newButton, $refreshButton, $startButton, $saveProfileButton, $saveKeyButton, $autoButton, $testButton, $applyButton, $testPublicButton, $copyButton, $batchTestButton, $deleteButton, $nameBox, $presetBox, $baseUrlBox, $apiFormatBox, $opusBox, $sonnetBox, $haikuBox, $keyBox)
    foreach ($control in $controls) {
        $control.Enabled = -not $script:Busy
    }
    if ($script:Busy) {
        $statusBar.Text = "处理中：$Action..."
    } else {
        Update-StatusBar
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Log-Line([string]$Text) {
    $stamp = (Get-Date).ToString("HH:mm:ss")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0

    if ($logBox.TextLength -gt 0) { $logBox.AppendText("`r`n") }

    # 时间戳：灰色
    $logBox.SelectionColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
    $logBox.AppendText("[$stamp] ")

    # 根据内容语义着色
    $msgColor = [System.Drawing.Color]::FromArgb(203, 213, 225)  # 默认浅灰
    if ($Text -match '^\[OK\]|测试通过|保存成功|Key 已保存|自动配置完成|已应用|网关启动成功|已删除|刷新完成') {
        $msgColor = [System.Drawing.Color]::FromArgb(74, 222, 128)   # 绿
    } elseif ($Text -match '^\[FAIL\]|^ERROR|^批量测试失败|失败|错误|异常|未保存|无法|超时') {
        $msgColor = [System.Drawing.Color]::FromArgb(248, 113, 113)  # 红
    } elseif ($Text -match '^警告|超过 30 秒') {
        $msgColor = [System.Drawing.Color]::FromArgb(251, 191, 36)   # 黄
    }

    $logBox.SelectionColor = $msgColor
    $logBox.AppendText($Text)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Show-Error([string]$Message, [string]$HowToFix = "") {
    $text = $Message
    if ($HowToFix) { $text += "`r`n`r`n怎么修：`r`n$HowToFix" }
    [System.Windows.Forms.MessageBox]::Show($form, $text, "Word AI Switch v2 - 提示", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    Log-Line "ERROR: $Message"
}

function Show-Info([string]$Message) {
    [System.Windows.Forms.MessageBox]::Show($form, $Message, "Word AI Switch v2", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Open-UserGuide() {
    Show-HelpForm
}

function Show-HelpForm() {
    $help = [System.Windows.Forms.Form]::new()
    $help.Text = "使用说明"
    $help.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $help.ClientSize = [System.Drawing.Size]::new(560, 460)
    $help.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $help.MaximizeBox = $false
    $help.MinimizeBox = $false
    $help.BackColor = $ColorPanelLight
    $help.Font = $FontUi

    $title = [System.Windows.Forms.Label]::new()
    $title.Text = "Word AI Switch v2 使用说明"
    $title.Location = [System.Drawing.Point]::new(20, 16)
    $title.Size = [System.Drawing.Size]::new(520, 28)
    $title.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $help.Controls.Add($title)

    # 左侧切换按钮区
    $btnPanel = [System.Windows.Forms.Panel]::new()
    $btnPanel.Location = [System.Drawing.Point]::new(20, 52)
    $btnPanel.Size = [System.Drawing.Size]::new(120, 350)
    $btnPanel.BackColor = $ColorPanelLight
    $help.Controls.Add($btnPanel)

    $rtb = [System.Windows.Forms.RichTextBox]::new()
    $rtb.Location = [System.Drawing.Point]::new(150, 52)
    $rtb.Size = [System.Drawing.Size]::new(390, 350)
    $rtb.ReadOnly = $true
    $rtb.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
    $rtb.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 10)
    $rtb.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
    $rtb.BackColor = $ColorPanelLight
    $rtb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $help.Controls.Add($rtb)

    $fontH1 = [System.Drawing.Font]::new("Microsoft YaHei UI", 14, [System.Drawing.FontStyle]::Bold)
    $fontBody = [System.Drawing.Font]::new("Microsoft YaHei UI", 10)
    $fontBold = [System.Drawing.Font]::new("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
    $cTitle = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $cText = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $cActive = $ColorAccent
    $cInactive = [System.Drawing.Color]::FromArgb(226, 232, 240)

    $helpTabs = @(
        @{ Text = "本地使用"; Key = "local" },
        @{ Text = "远程使用"; Key = "remote" },
        @{ Text = "常见问题"; Key = "faq" }
    )
    $tabButtons = @()
    $activeTab = "local"

    function Add-HelpLine([System.Windows.Forms.RichTextBox]$Box, [string]$Text, [System.Drawing.Font]$Font, [System.Drawing.Color]$Color, [int]$TopPadding = 0) {
        if ($TopPadding -gt 0) {
            $Box.SelectionFont = [System.Drawing.Font]::new("Microsoft YaHei UI", $TopPadding / 2)
            $Box.AppendText("`n")
        }
        $Box.SelectionFont = $Font
        $Box.SelectionColor = $Color
        $Box.AppendText($Text + "`n")
    }

    function Set-HelpContent([string]$Key) {
        $rtb.Clear()
        switch ($Key) {
            "local" {
                Add-HelpLine $rtb "本地使用（无需公网）" $fontH1 $cTitle
                Add-HelpLine $rtb "" $fontBody $cText 10

                Add-HelpLine $rtb "1. 启动网关" $fontBold $cTitle
                Add-HelpLine $rtb "   点击左侧「▶ 启动 / 修复 网关」，本地服务会运行在 127.0.0.1:8790。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "2. 配置 Profile" $fontBold $cTitle
                Add-HelpLine $rtb "   点击「+ 新建配置」，填写名称、Base URL、API 格式、模型映射，然后保存。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 6
                Add-HelpLine $rtb "   也可以先填好名称和 Base URL，再点「⚙ 自动配置」，系统会根据模型名自动推荐映射。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "3. 保存 API Key" $fontBold $cTitle
                Add-HelpLine $rtb "   在「API Key」框填入上游 Key，点击「保存 Key」。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "4. 应用网关" $fontBold $cTitle
                Add-HelpLine $rtb "   选中配置后点击「➜ 应用网关」。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "5. 导出 manifest.xml" $fontBold $cTitle
                Add-HelpLine $rtb "   点击「↓ 导出 manifest.xml」，导出后文件夹会自动打开。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "6. 导入 Word" $fontBold $cTitle
                Add-HelpLine $rtb "   Word → 插入 → 获取加载项 → 我的加载项 → 上传我的加载项，选择导出的 XML。" $fontBody $cText
            }
            "remote" {
                Add-HelpLine $rtb "远程 / 多机使用" $fontH1 $cTitle
                Add-HelpLine $rtb "" $fontBody $cText 10

                Add-HelpLine $rtb "需要公网入口" $fontBold $cTitle
                Add-HelpLine $rtb "   如果 Word 和本软件不在同一台电脑，或者想在外网使用，需要先配置 cloudflared tunnel。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "1. 安装 cloudflared" $fontBold $cTitle
                Add-HelpLine $rtb "   下载 cloudflared.exe 放到 %USERPROFILE% 目录。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "2. 创建 tunnel" $fontBold $cTitle
                Add-HelpLine $rtb "   运行 cloudflared tunnel login 登录，然后 cloudflared tunnel create word-deepseek 创建。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "3. 配置 config.yml" $fontBold $cTitle
                Add-HelpLine $rtb "   在 %USERPROFILE%\.cloudflared\config.yml 中配置 tunnel 和域名。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "4. 启动并导出" $fontBold $cTitle
                Add-HelpLine $rtb "   GUI 会自动启动 tunnel，此时导出 manifest.xml 会使用公网 URL。" $fontBody $cText
            }
            "faq" {
                Add-HelpLine $rtb "常见问题" $fontH1 $cTitle
                Add-HelpLine $rtb "" $fontBody $cText 10

                Add-HelpLine $rtb "Q：导出的 XML 是什么？" $fontBold $cTitle
                Add-HelpLine $rtb "A：Office 插件清单，Word 靠它知道插件入口地址和 gateway 地址。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：gateway_token 会变吗？" $fontBold $cTitle
                Add-HelpLine $rtb "A：第一次导出时自动生成并保存到 .env，之后固定不变。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：没有 tunnel 能用吗？" $fontBold $cTitle
                Add-HelpLine $rtb "A：能，只要 Word 和本软件在同一台电脑即可。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：修改 profile 后要重新导出 XML 吗？" $fontBold $cTitle
                Add-HelpLine $rtb "A：改了模型或 Key 不需要；改了 API 格式或 gateway URL 建议重新导出。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：GUI 打开后中文乱码怎么办？" $fontBold $cTitle
                Add-HelpLine $rtb "A：确认脚本以 UTF-8 保存。PowerShell 5.1 下若仍乱码，先执行 chcp 65001 再启动。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：保存 API Key 后测试仍提示「未保存 Key」？" $fontBold $cTitle
                Add-HelpLine $rtb "A：确认点的是「保存 Key」而不是「保存配置」。secrets.json 是 DPAPI 加密的，换机器后需重新保存。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：「应用到 Word 网关」失败？" $fontBold $cTitle
                Add-HelpLine $rtb "A：常见原因：端口 8790 被占用、.venv 损坏、cloudflared.exe 不在 %USERPROFILE% 下。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：Office 加载项打不开 / 显示空白？" $fontBold $cTitle
                Add-HelpLine $rtb "A：用 start-word-fixed.ps1 清理缓存，确认 manifest 里的 SourceLocation 指向正确域名，并完全退出 Office 后重开。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：批量测试全部失败？" $fontBold $cTitle
                Add-HelpLine $rtb "A：确认所有 profile 都已保存 Key；单个测试确认上游连通；检查本地网络/DNS。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：公网入口测试失败但本地测试通过？" $fontBold $cTitle
                Add-HelpLine $rtb "A：检查 cloudflared 是否启动、Cloudflare DNS 是否指向当前 tunnel、config.yml 是否配置正确。" $fontBody $cText
                Add-HelpLine $rtb "" $fontBody $cText 8

                Add-HelpLine $rtb "Q：自动配置可靠吗？" $fontBold $cTitle
                Add-HelpLine $rtb "A：自动配置会根据模型名推荐映射，但不同上游的模型名可能不标准，推荐后建议再检查一遍。" $fontBody $cText
            }
        }
        $rtb.SelectionStart = 0
        $rtb.ScrollToCaret()
    }

    function Update-TabButtons() {
        for ($i = 0; $i -lt $tabButtons.Count; $i++) {
            $btn = $tabButtons[$i]
            $key = $helpTabs[$i].Key
            if ($key -eq $activeTab) {
                $btn.BackColor = $cActive
                $btn.ForeColor = $ColorWhite
            } else {
                $btn.BackColor = $cInactive
                $btn.ForeColor = $cTitle
            }
        }
    }

    for ($i = 0; $i -lt $helpTabs.Count; $i++) {
        $tab = $helpTabs[$i]
        $btn = [System.Windows.Forms.Button]::new()
        $btn.Text = $tab.Text
        $btn.Location = [System.Drawing.Point]::new(0, $i * 42)
        $btn.Size = [System.Drawing.Size]::new(110, 36)
        $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $btn.FlatAppearance.BorderSize = 0
        $btn.Font = $FontUiBold
        $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
        $btn.Tag = $tab.Key
        $btn.Add_Click({
            $activeTab = $this.Tag
            Set-HelpContent $activeTab
            Update-TabButtons
        })
        $tabButtons += $btn
        $btnPanel.Controls.Add($btn)
    }

    Set-HelpContent "local"
    Update-TabButtons

    $okBtn = [System.Windows.Forms.Button]::new()
    $okBtn.Text = "知道了"
    $okBtn.Location = [System.Drawing.Point]::new(440, 412)
    $okBtn.Size = [System.Drawing.Size]::new(100, 32)
    $okBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $okBtn.FlatAppearance.BorderSize = 0
    $okBtn.BackColor = $ColorBtnPrimary
    $okBtn.ForeColor = $ColorWhite
    $okBtn.Font = $FontUiBold
    $okBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $help.Controls.Add($okBtn)
    $help.AcceptButton = $okBtn

    [void]$help.ShowDialog($form)
}

function Get-WelcomeState() {
    if (Test-Path $WelcomeFile) {
        try {
            $json = Get-Content $WelcomeFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return ([bool]$json.welcomeShown) -or ([bool]$json.doNotShowAgain)
        } catch { return $false }
    }
    return $false
}

function Set-WelcomeState([bool]$DoNotShowAgain) {
    $dir = Split-Path -Parent $WelcomeFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $exportGuideState = Get-ExportGuideState
    @{
        welcomeShown = $true
        doNotShowAgain = $DoNotShowAgain
        doNotShowExportGuide = $exportGuideState
    } | ConvertTo-Json -Compress | Set-Content $WelcomeFile -Encoding UTF8
}

function Show-WelcomeForm() {
    if (Get-WelcomeState) { return }

    $welcome = [System.Windows.Forms.Form]::new()
    $welcome.Text = "欢迎使用 Word AI Switch v2"
    $welcome.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $welcome.ClientSize = [System.Drawing.Size]::new(480, 320)
    $welcome.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $welcome.MaximizeBox = $false
    $welcome.MinimizeBox = $false
    $welcome.BackColor = $ColorPanelLight
    $welcome.Font = $FontUi

    $title = [System.Windows.Forms.Label]::new()
    $title.Text = "欢迎使用 Word AI Switch v2"
    $title.Location = [System.Drawing.Point]::new(20, 18)
    $title.Size = [System.Drawing.Size]::new(440, 28)
    $title.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $welcome.Controls.Add($title)

    $body = [System.Windows.Forms.Label]::new()
    $body.Text = "本地使用只需 4 步：`r`n`r`n1. 点「▶ 启动 / 修复 网关」启动本地服务`r`n2. 新建/选中 profile，填写 Base URL、API 格式、模型映射`r`n3. 保存 Key 后点「➜ 应用网关」`r`n4. 点「↓ 导出 manifest.xml」，然后导入 Word`r`n`r`n远程使用需先配置 cloudflared tunnel，详见说明文档。"
    $body.Location = [System.Drawing.Point]::new(20, 56)
    $body.Size = [System.Drawing.Size]::new(440, 150)
    $body.Font = $FontUi
    $body.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $welcome.Controls.Add($body)

    $chk = [System.Windows.Forms.CheckBox]::new()
    $chk.Text = "下次启动不再显示"
    $chk.Location = [System.Drawing.Point]::new(20, 220)
    $chk.Size = [System.Drawing.Size]::new(200, 24)
    $chk.Font = $FontUi
    $chk.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $welcome.Controls.Add($chk)

    $guideBtn = [System.Windows.Forms.Button]::new()
    $guideBtn.Text = "查看完整说明"
    $guideBtn.Location = [System.Drawing.Point]::new(240, 260)
    $guideBtn.Size = [System.Drawing.Size]::new(110, 32)
    $guideBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $guideBtn.FlatAppearance.BorderSize = 0
    $guideBtn.BackColor = $ColorBtnSecondary
    $guideBtn.ForeColor = $ColorWhite
    $guideBtn.Font = $FontUiBold
    $guideBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $guideBtn.Add_Click({ Open-UserGuide })
    $welcome.Controls.Add($guideBtn)

    $okBtn = [System.Windows.Forms.Button]::new()
    $okBtn.Text = "知道了"
    $okBtn.Location = [System.Drawing.Point]::new(360, 260)
    $okBtn.Size = [System.Drawing.Size]::new(100, 32)
    $okBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $okBtn.FlatAppearance.BorderSize = 0
    $okBtn.BackColor = $ColorBtnPrimary
    $okBtn.ForeColor = $ColorWhite
    $okBtn.Font = $FontUiBold
    $okBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $welcome.Controls.Add($okBtn)
    $welcome.AcceptButton = $okBtn

    [void]$welcome.ShowDialog($form)
    Set-WelcomeState $chk.Checked
}

function Get-ExportGuideState() {
    if (Test-Path $WelcomeFile) {
        try {
            $json = Get-Content $WelcomeFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return [bool]$json.doNotShowExportGuide
        } catch { return $false }
    }
    return $false
}

function Set-ExportGuideState([bool]$DoNotShowAgain) {
    $dir = Split-Path -Parent $WelcomeFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $welcomeState = Get-WelcomeState
    $state = @{
        welcomeShown = $welcomeState
        doNotShowAgain = $welcomeState
        doNotShowExportGuide = $DoNotShowAgain
    }
    $state | ConvertTo-Json -Compress | Set-Content $WelcomeFile -Encoding UTF8
}

function Show-ExportManifestGuide([string]$Path) {
    if (Get-ExportGuideState) { return }

    $guide = [System.Windows.Forms.Form]::new()
    $guide.Text = "manifest.xml 导出成功"
    $guide.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $guide.ClientSize = [System.Drawing.Size]::new(520, 260)
    $guide.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $guide.MaximizeBox = $false
    $guide.MinimizeBox = $false
    $guide.BackColor = $ColorPanelLight
    $guide.Font = $FontUi

    $title = [System.Windows.Forms.Label]::new()
    $title.Text = "manifest.xml 已导出"
    $title.Location = [System.Drawing.Point]::new(20, 18)
    $title.Size = [System.Drawing.Size]::new(480, 28)
    $title.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $guide.Controls.Add($title)

    $body = [System.Windows.Forms.Label]::new()
    $body.Text = "文件已保存到：`r`n$Path`r`n`r`n下一步操作：`r`n1. 保持本软件运行（本地 gateway 正在运行）`r`n2. 打开 Word → 插入 → 获取加载项 → 我的加载项`r`n3. 选择「上传我的加载项」，选中刚导出的 XML 文件`r`n4. Word 工具栏出现 Claude 按钮，点击即可使用"
    $body.Location = [System.Drawing.Point]::new(20, 56)
    $body.Size = [System.Drawing.Size]::new(480, 130)
    $body.Font = $FontUi
    $body.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $guide.Controls.Add($body)

    $chk = [System.Windows.Forms.CheckBox]::new()
    $chk.Text = "下次导出不再提示"
    $chk.Location = [System.Drawing.Point]::new(20, 196)
    $chk.Size = [System.Drawing.Size]::new(200, 24)
    $chk.Font = $FontUi
    $chk.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
    $guide.Controls.Add($chk)

    $okBtn = [System.Windows.Forms.Button]::new()
    $okBtn.Text = "知道了"
    $okBtn.Location = [System.Drawing.Point]::new(400, 196)
    $okBtn.Size = [System.Drawing.Size]::new(100, 32)
    $okBtn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $okBtn.FlatAppearance.BorderSize = 0
    $okBtn.BackColor = $ColorBtnPrimary
    $okBtn.ForeColor = $ColorWhite
    $okBtn.Font = $FontUiBold
    $okBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $okBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $guide.Controls.Add($okBtn)
    $guide.AcceptButton = $okBtn

    [void]$guide.ShowDialog($form)
    Set-ExportGuideState $chk.Checked
}

function Get-CurrentProfile {
    if (-not $script:SelectedId) { return $null }
    foreach ($p in $script:Profiles) {
        if ([string]$p.id -eq $script:SelectedId) { return $p }
    }
    return $null
}

# 渲染整个列表（只在 profiles 数量变化时调用）
function Render-ProfileList {
    $profileListPanel.SuspendLayout()
    $profileListPanel.Controls.Clear()
    # 搜索过滤
    $keyword = ""
    if ($searchBox.Text -and $searchBox.Text -ne "搜索配置...") {
        $keyword = $searchBox.Text.Trim().ToLower()
    }
    $y = 4
    foreach ($p in $script:Profiles) {
        # 应用搜索过滤
        if ($keyword) {
            $matchName = ([string]$p.name).ToLower().Contains($keyword)
            $matchId = ([string]$p.id).ToLower().Contains($keyword)
            if (-not ($matchName -or $matchId)) { continue }
        }
        $isActive = ([string]$p.id -eq $script:ActiveId)
        $isSelected = ([string]$p.id -eq $script:SelectedId)
        $card = [System.Windows.Forms.Panel]::new()
        $card.Location = [System.Drawing.Point]::new(8, $y)
        $card.Size = [System.Drawing.Size]::new(300, 78)
        $card.BackColor = if ($isActive) { $ColorCardActive } else { $ColorCard }
        $card.Cursor = [System.Windows.Forms.Cursors]::Hand
        $card.Tag = [string]$p.id

        # 左侧指示条（4px）：选中=蓝，启用=绿，默认=灰
        $indicator = [System.Windows.Forms.Panel]::new()
        $indicator.Location = [System.Drawing.Point]::new(0, 0)
        $indicator.Size = [System.Drawing.Size]::new(4, 78)
        $indicator.BackColor = if ($isActive) { $ColorSuccess } elseif ($isSelected) { $ColorAccent } else { [System.Drawing.Color]::FromArgb(51, 65, 85) }
        $card.Controls.Add($indicator)

        $nameLbl = [System.Windows.Forms.Label]::new()
        $nameLbl.Text = [string]$p.name
        $nameLbl.Location = [System.Drawing.Point]::new(14, 9)
        $nameLbl.Size = [System.Drawing.Size]::new(190, 22)
        $nameLbl.Font = if ($isSelected) { $FontUiBold } else { $FontUi }
        $nameLbl.ForeColor = $ColorTextMain
        $nameLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
        $nameLbl.Tag = [string]$p.id
        $card.Controls.Add($nameLbl)

        $activeBadge = [System.Windows.Forms.Label]::new()
        $activeBadge.Text = if ($isActive) { "● 已启用" } else { "" }
        $activeBadge.Location = [System.Drawing.Point]::new(190, 11)
        $activeBadge.Size = [System.Drawing.Size]::new(90, 18)
        $activeBadge.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 8, [System.Drawing.FontStyle]::Bold)
        $activeBadge.ForeColor = $ColorSuccess
        $activeBadge.Cursor = [System.Windows.Forms.Cursors]::Hand
        $activeBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        $activeBadge.Tag = [string]$p.id
        $card.Controls.Add($activeBadge)

        $idLbl = [System.Windows.Forms.Label]::new()
        $idLbl.Text = [string]$p.id
        $idLbl.Location = [System.Drawing.Point]::new(14, 31)
        $idLbl.Size = [System.Drawing.Size]::new(270, 16)
        $idLbl.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 8)
        $idLbl.ForeColor = $ColorTextSub
        $idLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
        $idLbl.Tag = [string]$p.id
        $card.Controls.Add($idLbl)

        $keyMasked = [string]$p.apiKeyMasked
        $keyText = if ($p.apiKeySaved) { "Key $keyMasked" } else { "Key 未保存" }
        $keyColor = if ($p.apiKeySaved) { $ColorSuccess } else { $ColorWarning }

        $keyDot = [System.Windows.Forms.Panel]::new()
        $keyDot.Location = [System.Drawing.Point]::new(14, 57)
        $keyDot.Size = [System.Drawing.Size]::new(6, 6)
        $keyDot.BackColor = $keyColor
        $keyDot.Cursor = [System.Windows.Forms.Cursors]::Hand
        $keyDot.Tag = [string]$p.id
        $card.Controls.Add($keyDot)

        $keyLbl = [System.Windows.Forms.Label]::new()
        $keyLbl.Text = $keyText
        $keyLbl.Location = [System.Drawing.Point]::new(24, 51)
        $keyLbl.Size = [System.Drawing.Size]::new(120, 16)
        $keyLbl.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 8)
        $keyLbl.ForeColor = $keyColor
        $keyLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
        $keyLbl.Tag = [string]$p.id
        $card.Controls.Add($keyLbl)

        $routeText = "sonnet → " + [string]$p.routes.sonnet
        $sonnetLbl = [System.Windows.Forms.Label]::new()
        $sonnetLbl.Text = $routeText
        $sonnetLbl.Location = [System.Drawing.Point]::new(140, 51)
        $sonnetLbl.Size = [System.Drawing.Size]::new(140, 16)
        $sonnetLbl.Font = [System.Drawing.Font]::new("Microsoft YaHei UI", 8)
        $sonnetLbl.ForeColor = $ColorTextSub
        $sonnetLbl.Cursor = [System.Windows.Forms.Cursors]::Hand
        $sonnetLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
        $sonnetLbl.Tag = [string]$p.id
        $card.Controls.Add($sonnetLbl)

        $clickHandler = {
            param($sender, $e)
            $id = [string]$sender.Tag
            if ($id -and $id -ne $script:SelectedId) {
                $script:SelectedId = $id
                Load-ProfileIntoForm
                Update-SelectionVisual
            }
        }
        foreach ($c in @($card, $nameLbl, $idLbl, $keyLbl, $keyDot, $activeBadge, $sonnetLbl, $indicator)) {
            $c.Add_Click($clickHandler)
        }

        $profileListPanel.Controls.Add($card)
        $y += 86
    }
    $profileListPanel.ResumeLayout($true)
    $profileListPanel.HorizontalScroll.Visible = $false
    $profileListPanel.HorizontalScroll.Enabled = $false
    $script:LastProfileCount = $script:Profiles.Count
    # 更新计数
    if ($listCountLabel) {
        $listCountLabel.Text = "$($script:Profiles.Count) 个"
    }
}

# 只更新选中视觉（不重建列表，性能优化）
function Update-SelectionVisual {
    foreach ($control in $profileListPanel.Controls) {
        if ($control -is [System.Windows.Forms.Panel] -and $control.Tag) {
            $cardId = [string]$control.Tag
            $isActive = ($cardId -eq $script:ActiveId)
            $isSelected = ($cardId -eq $script:SelectedId)
            $control.BackColor = if ($isActive) { $ColorCardActive } else { $ColorCard }
            # indicator 是第一个子控件
            if ($control.Controls.Count -gt 0 -and $control.Controls[0] -is [System.Windows.Forms.Panel]) {
                $indicator = $control.Controls[0]
                $indicator.BackColor = if ($isActive) { $ColorSuccess } elseif ($isSelected) { $ColorAccent } else { [System.Drawing.Color]::FromArgb(51, 65, 85) }
            }
            # nameLbl 是第二个子控件
            if ($control.Controls.Count -gt 1 -and $control.Controls[1] -is [System.Windows.Forms.Label]) {
                $nameLbl = $control.Controls[1]
                $nameLbl.Font = if ($isSelected) { $FontUiBold } else { $FontUi }
            }
        }
    }
}

function Load-ProfileIntoForm {
    $p = Get-CurrentProfile
    $script:LoadingProfile = $true
    if (-not $p) {
        $nameBox.Text = ""
        $baseUrlBox.Text = ""
        $opusBox.Text = ""
        $sonnetBox.Text = ""
        $haikuBox.Text = ""
        $keyBox.Text = ""
        $keyStateLabel.Text = "未保存（新建后请先保存配置）"
        $keyStateLabel.ForeColor = $ColorWarning
        if ($presetBox.Items.Count -gt 0) { $presetBox.SelectedIndex = 0 }
        $apiFormatBox.SelectedIndex = 0
        $script:LoadingProfile = $false
        return
    }
    $nameBox.Text = [string]$p.name
    $baseUrlBox.Text = [string]$p.baseUrl
    $routes = $p.routes
    $opusBox.Text = if ($routes -and $routes.opus) { [string]$routes.opus } else { "" }
    $sonnetBox.Text = if ($routes -and $routes.sonnet) { [string]$routes.sonnet } else { "" }
    $haikuBox.Text = if ($routes -and $routes.haiku) { [string]$routes.haiku } else { "" }
    # 保存配置后的 refresh 保留用户输入的 Key，避免输入被清空导致无法保存 Key
    if ($script:PreserveKeyOnReload) {
        $script:PreserveKeyOnReload = $false
    } else {
        $keyBox.Text = ""
    }
    $presetId = [string]$p.presetId
    $matchedIdx = -1
    for ($i = 0; $i -lt $presetBox.Items.Count; $i++) {
        if ([string]$presetBox.Items[$i] -eq $presetId) { $matchedIdx = $i; break }
    }
    if ($matchedIdx -ge 0) { $presetBox.SelectedIndex = $matchedIdx }
    $fmt = [string]$p.apiFormat
    if ($fmt -eq "anthropic") { $apiFormatBox.SelectedIndex = 0 }
    elseif ($fmt -eq "openai_chat") { $apiFormatBox.SelectedIndex = 1 }
    elseif ($fmt -eq "openai_responses") { $apiFormatBox.SelectedIndex = 2 }
    elseif ($fmt -eq "gemini_native") { $apiFormatBox.SelectedIndex = 3 }
    else { $apiFormatBox.SelectedIndex = 0 }

    $keyMasked = [string]$p.apiKeyMasked
    if ($p.apiKeySaved) {
        $keyStateLabel.Text = "已保存 $keyMasked"
        $keyStateLabel.ForeColor = $ColorSuccess
    } else {
        $keyStateLabel.Text = "未保存"
        $keyStateLabel.ForeColor = $ColorWarning
    }
    # 仅在非保留模式下重置 KeyDirty（保留模式由 save-profile 触发，用户 Key 输入需保留）
    if (-not ($keyBox.Text -and $script:KeyDirty)) {
        $script:KeyDirty = $false
    }
    $script:LoadingProfile = $false

    if ($p.lastTest) {
        $lt = $p.lastTest
        $status = [string]$lt.status
        $ts = if ($lt.checkedAt) { [string]$lt.checkedAt } else { "-" }
        $msg = if ($lt.message) { [string]$lt.message } else { "" }
        $model = if ($lt.upstreamModel) { [string]$lt.upstreamModel } else { "-" }
        $latency = if ($lt.latencyMs) { "$($lt.latencyMs)ms" } else { "-" }
        $logBox.Text = "最近测试: $status`r`n  时间: $ts`r`n  baseUrl: $($lt.baseUrl)`r`n  upstreamModel: $model`r`n  latency: $latency`r`n  message: $msg"
        if ($lt.howToFix) { $logBox.AppendText("`r`n  怎么修: $($lt.howToFix)") }
    }
}

# 异步刷新（后台执行，UI 不冻结）
function Refresh-All-Async {
    if ($script:Busy) { return }
    Set-Busy "刷新配置"
    Log-Line "刷新中..."
    Invoke-Background -Payload @{ Action = "refresh" } -Tag "refresh"
}

function Update-ActiveCard {
    if (-not $script:StatusCache) { return }
    $a = $script:StatusCache.activeProfile
    $gwRunning = $script:StatusCache.gateway.running
    $gwText = if ($gwRunning) { "Gateway 运行中" } else { "Gateway 已停止" }
    $gwColor = if ($gwRunning) { $ColorBtnSuccess } else { $ColorBtnSecondary }
    $gatewayStatusBadge.Text = $gwText
    $gatewayStatusBadge.BackColor = $gwColor

    $tun = if ($script:StatusCache.tunnel.running) { "Tunnel 运行中" } else { "Tunnel 已停止" }
    if ($a) {
        $activeName.Text = "$($a.name)  ($($a.id))"
        $keyStr = if ($a.keySaved) { "Key $($a.keyPreview)" } else { "Key 未保存" }
        $activeDetail.Text = "$tun  ·  $keyStr  ·  API 格式: $($a.apiFormat)`r`nopus → $($a.routes.opus)    sonnet → $($a.routes.sonnet)    haiku → $($a.routes.haiku)"
    } else {
        $activeName.Text = "未应用任何 profile"
        $activeDetail.Text = "$tun  ·  请选中一个 profile 后点「应用网关」。"
    }
}

function Update-StatusBar {
    if ($script:Busy) {
        $statusBar.Text = "处理中：$($script:BusyAction)..."
        return
    }
    if (-not $script:StatusCache) {
        $statusBar.Text = "本地网关：未知 | 公网入口：未测试 | 当前启用：- | Word sonnet → -"
        return
    }
    $gw = if ($script:StatusCache.gateway.running) { "运行中" } else { "已停止" }
    $active = if ($script:StatusCache.activeProfileName) { [string]$script:StatusCache.activeProfileName } else { "-" }
    $sonnet = if ($script:StatusCache.activeProfile -and $script:StatusCache.activeProfile.routes) { [string]$script:StatusCache.activeProfile.routes.sonnet } else { "-" }
    $statusBar.Text = "本地网关：$gw | 公网入口：未测试 | 当前启用：$active | Word sonnet -> $sonnet"
}

function Build-ProfileJson {
    $fmt = "anthropic"
    if ($apiFormatBox.SelectedIndex -eq 1) { $fmt = "openai_chat" }
    elseif ($apiFormatBox.SelectedIndex -eq 2) { $fmt = "openai_responses" }
    elseif ($apiFormatBox.SelectedIndex -eq 3) { $fmt = "gemini_native" }
    $presetId = if ($presetBox.SelectedItem) { [string]$presetBox.SelectedItem } else { "custom_gateway" }
    $obj = [ordered]@{
        name = $nameBox.Text.Trim()
        baseUrl = $baseUrlBox.Text.Trim()
        presetId = $presetId
        apiFormat = $fmt
        routes = @{ opus = $opusBox.Text.Trim(); sonnet = $sonnetBox.Text.Trim(); haiku = $haikuBox.Text.Trim() }
    }
    if ($script:SelectedId) { $obj["id"] = $script:SelectedId }
    return ($obj | ConvertTo-Json -Compress)
}

# === JobTimer：结果轮询 + 超时检测 ===
$jobTimer = [System.Windows.Forms.Timer]::new()
$jobTimer.Interval = 150
$jobTimer.Add_Tick({
    if ($script:ProcessingResult) { return }
    $script:ProcessingResult = $true
    try {
        # 超时检测（30 秒警告一次）
        if ($script:Busy -and $script:BusyStartTime -gt 0 -and -not $script:TimeoutWarned) {
            $elapsed = [System.Environment]::TickCount - $script:BusyStartTime
            if ($elapsed -gt 30000) {
                Log-Line "警告：当前操作已超过 30 秒，可能卡住。如长时间无响应可关闭窗口重开。"
                $script:TimeoutWarned = $true
            }
        }
        # 处理结果队列
        while ($script:Sync.Results.Count -gt 0) {
            $item = $script:Sync.Results.Dequeue()
            $action = [string]$item.Action
            $result = $item.Result
            Set-Busy ""
            try {
            switch ($action) {
                "refresh" {
                    if ($result.ExitCode -eq 0) {
                        $script:StatusCache = $result.Output | ConvertFrom-Json
                        $script:Profiles = @($script:StatusCache.profiles)
                        $script:Presets = @($script:StatusCache.presets)
                        $script:ActiveId = [string]$script:StatusCache.activeProfileId
                        $presetBox.Items.Clear()
                        foreach ($preset in $script:Presets) { [void]$presetBox.Items.Add([string]$preset.id) }
                        if (-not $script:SelectedId) {
                            $script:SelectedId = if ($script:ActiveId) { $script:ActiveId } elseif ($script:Profiles.Count -gt 0) { [string]$script:Profiles[0].id } else { "" }
                        } else {
                            $exists = $false
                            foreach ($p in $script:Profiles) { if ([string]$p.id -eq $script:SelectedId) { $exists = $true; break } }
                            if (-not $exists) {
                                $script:SelectedId = if ($script:ActiveId) { $script:ActiveId } elseif ($script:Profiles.Count -gt 0) { [string]$script:Profiles[0].id } else { "" }
                            }
                        }
                        if ($script:Profiles.Count -ne $script:LastProfileCount -or $script:ForceRender) {
                            Render-ProfileList
                            $script:ForceRender = $false
                        } else {
                            Update-SelectionVisual
                        }
                        Load-ProfileIntoForm
                        Update-ActiveCard
                        Update-StatusBar
                        Log-Line "刷新完成：$($script:Profiles.Count) 个配置"
                    } else {
                        $script:StatusCache = $null
                        Show-Error "刷新失败：$($result.Output)" "确认 word-switch-v2.py 可正常执行。"
                    }
                }
                "save-profile" {
                    $parsed = $result.Output | ConvertFrom-Json
                    if ($result.ExitCode -eq 0 -and $parsed.ok) {
                        Log-Line "保存成功：$($parsed.profile.name) ($($parsed.profile.id))"
                        $script:SelectedId = [string]$parsed.profile.id
                        $script:ForceRender = $true
                        # 保留用户输入的 API Key，避免 refresh 后被清空导致无法保存 Key
                        $script:PreserveKeyOnReload = $true
                        Refresh-All-Async
                    } else {
                        $err = if ($parsed.error) { [string]$parsed.error } else { $result.Output }
                        Show-Error "保存配置失败：$err" "检查 name 和 baseUrl 是否填写完整。"
                    }
                }
                "save-key" {
                    $parsed = $result.Output | ConvertFrom-Json
                    if ($result.ExitCode -eq 0 -and $parsed.ok) {
                        Log-Line "Key 已保存：$($parsed.keyPreview)"
                        $keyBox.Text = ""
                        $script:KeyDirty = $false
                        $script:ForceRender = $true
                        Refresh-All-Async
                    } else {
                        $err = if ($parsed.error) { [string]$parsed.error } else { $result.Output }
                        Show-Error "保存 Key 失败：$err" "确认 profile 已保存。"
                    }
                }
                "auto-configure" {
                    $parsed = $result.Output | ConvertFrom-Json
                    if ($parsed.ok) {
                        $cnt = if ($parsed.fetch.models) { @($parsed.fetch.models).Count } else { 0 }
                        Log-Line "自动配置完成：拉到 $cnt 个模型，已写入建议映射。"
                        Refresh-All-Async
                        Show-Info "自动配置完成。已根据模型名推荐 opus/sonnet/haiku 映射。请点击「测试选中配置」验证上游鉴权。"
                    } else {
                        $err = if ($parsed.error) { [string]$parsed.error } else { "拉取模型列表失败" }
                        $howTo = if ($parsed.howToFix) { [string]$parsed.howToFix } else { "确认 Base URL 正确、API Key 有效、网络可达上游。" }
                        Show-Error "自动配置失败：$err" $howTo
                    }
                }
                "test-selected" {
                    $parsed = $result.Output | ConvertFrom-Json
                    if ($parsed.status -eq "passed") {
                        Log-Line "测试通过：sonnet -> $($parsed.upstreamModel)，$($parsed.latencyMs)ms"
                        Refresh-All-Async
                        Show-Info "测试通过。`r`nbaseUrl: $($parsed.baseUrl)`r`nupstreamModel: $($parsed.upstreamModel)`r`nlatency: $($parsed.latencyMs)ms"
                    } else {
                        $msg = if ($parsed.message) { [string]$parsed.message } else { "未知错误" }
                        $howTo = if ($parsed.howToFix) { [string]$parsed.howToFix } else { "" }
                        Show-Error "测试失败：$msg" $howTo
                        Refresh-All-Async
                    }
                }
                "apply" {
                    $parsed = $result.Output | ConvertFrom-Json
                    if ($result.ExitCode -eq 0 -and $parsed.ok) {
                        Log-Line "已应用到 Word 网关：$($parsed.activeProfileName)"
                        Refresh-All-Async
                        Show-Info "已应用到 Word 网关。`r`nactiveProfile: $($parsed.activeProfileName)"
                    } else {
                        $err = if ($parsed.error) { [string]$parsed.error } else { $result.Output }
                        Show-Error "应用失败：$err" "确认已保存 API Key，且本机端口未被占用。"
                    }
                }
                "test-public" {
                    $parsed = $result.Output | ConvertFrom-Json
                    if ($parsed.status -eq "passed") {
                        Log-Line "公网入口测试通过：$($parsed.activeProfileName) -> $($parsed.upstreamModel)，$($parsed.latencyMs)ms"
                        Show-Info "公网入口测试通过。"
                    } else {
                        $msg = if ($parsed.message) { [string]$parsed.message } else { "未知错误" }
                        $howTo = if ($parsed.howToFix) { [string]$parsed.howToFix } else { "" }
                        Show-Error "公网入口测试失败：$msg" $howTo
                    }
                }
                "start" {
                    $parsed = $result.Output | ConvertFrom-Json
                    if ($result.ExitCode -eq 0 -and $parsed.ok) {
                        Log-Line "网关启动成功"
                        Refresh-All-Async
                    } else {
                        $err = if ($parsed.error) { [string]$parsed.error } else { $result.Output }
                        Show-Error "网关启动失败：$err" "确认 active profile 已保存 Key，且 .venv 存在。"
                    }
                }
                "delete-profile" {
                    $parsed = $result.Output | ConvertFrom-Json
                    if ($result.ExitCode -eq 0 -and $parsed.ok) {
                        Log-Line "已删除：$($parsed.deletedName) ($($parsed.deletedId))"
                        $script:SelectedId = ""
                        $script:ForceRender = $true
                        Refresh-All-Async
                    } else {
                        $err = if ($parsed.error) { [string]$parsed.error } else { $result.Output }
                        Show-Error "删除失败：$err" ""
                    }
                }
                "export-manifest" {
                    $parsed = $result.Output | ConvertFrom-Json
                    if ($result.ExitCode -eq 0 -and $parsed.ok) {
                        Log-Line "manifest 已导出：$($parsed.path)"
                        Show-ExportManifestGuide $parsed.path
                        try { Start-Process "explorer.exe" -ArgumentList "/select,$($parsed.path)" } catch {}
                    } else {
                        $err = if ($parsed.error) { [string]$parsed.error } else { $result.Output }
                        Show-Error "导出 manifest 失败：$err" ""
                    }
                }
                "batch-test" {
                    $passed = 0; $failed = 0
                    if ([string]::IsNullOrWhiteSpace($result.Output)) {
                        Log-Line "批量测试失败：结果为空（result=$result）"
                    } elseif ($result.Output -eq "[]") {
                        Log-Line "批量测试失败：结果为空数组 []"
                    } elseif (-not ($result.Output.TrimStart().StartsWith("["))) {
                        Log-Line "批量测试诊断（非JSON）：$($result.Output)"
                    } else {
                        try {
                            $items = $result.Output | ConvertFrom-Json
                            if ($items -isnot [System.Array]) { $items = @($items) }
                            foreach ($item in $items) {
                                try {
                                    $testResult = $item.output | ConvertFrom-Json
                                    $status = [string]$testResult.status
                                    if ($status -eq "passed") {
                                        $passed++
                                        Log-Line "[OK] $($item.id): $($testResult.upstreamModel)，$($testResult.latencyMs)ms"
                                    } else {
                                        $failed++
                                        $msg = if ($testResult.message) { [string]$testResult.message } else { "未知错误" }
                                        Log-Line "[FAIL] $($item.id): $msg"
                                    }
                                } catch {
                                    $failed++
                                    Log-Line "[FAIL] $($item.id): 结果解析失败 - $($_.Exception.Message)"
                                }
                            }
                        } catch {
                            Log-Line "批量测试结果解析失败：$($_.Exception.Message)"
                        }
                    }
                    Log-Line "批量测试完成：$passed 通过 / $failed 失败"
                }
            }
            } catch {
                Log-Line "操作异常：$($_.Exception.Message)"
            }
        }
    } catch {
        Log-Line "Timer 异常：$($_.Exception.Message)"
    }
    $script:ProcessingResult = $false
})
$jobTimer.Start()

# === 事件处理器 ===

$keyBox.Add_TextChanged({
    if (-not $script:LoadingProfile) { $script:KeyDirty = $true }
})

$refreshButton.Add_Click({ Refresh-All-Async })

$newButton.Add_Click({
    $script:SelectedId = ""
    $script:LoadingProfile = $true
    $nameBox.Text = ""
    $baseUrlBox.Text = ""
    $opusBox.Text = ""
    $sonnetBox.Text = ""
    $haikuBox.Text = ""
    $keyBox.Text = ""
    $keyStateLabel.Text = "未保存（新建后请先保存配置）"
    $keyStateLabel.ForeColor = $ColorWarning
    if ($presetBox.Items.Count -gt 0) { $presetBox.SelectedIndex = 0 }
    $apiFormatBox.SelectedIndex = 0
    $script:LoadingProfile = $false
    $logBox.Text = "新建 profile：填写名称、Base URL，可选填预设来源和 API 格式，然后点「保存配置」。"
    $nameBox.Focus()
    Update-SelectionVisual
})

$saveProfileButton.Add_Click({
    if ($script:Busy) { return }
    if (-not $nameBox.Text.Trim() -or -not $baseUrlBox.Text.Trim()) {
        Show-Error "保存失败：name 或 baseUrl 为空。" "在表单里填写名称和 Base URL。"
        return
    }
    # 输入校验：baseUrl 必须以 http:// 或 https:// 开头
    $url = $baseUrlBox.Text.Trim()
    if ($url -notmatch '^https?://') {
        Show-Error "保存失败：Base URL 格式不正确。" "Base URL 必须以 http:// 或 https:// 开头。"
        return
    }
    $json = Build-ProfileJson
    Set-Busy "保存配置"
    Log-Line "保存配置中..."
    Invoke-Background -Payload @{ Action = "save-profile"; Json = $json } -Tag "save-profile"
})

$saveKeyButton.Add_Click({
    if ($script:Busy) { return }
    if (-not $script:SelectedId) {
        Show-Error "请先点「保存配置」创建 profile。" ""
        return
    }
    if (-not $keyBox.Text -or -not $script:KeyDirty) {
        Show-Error "请输入新的 API Key 再点保存。" "Key 框为空时不覆盖已保存的 Key。"
        return
    }
    $keyText = $keyBox.Text
    $id = $script:SelectedId
    Set-Busy "保存 Key"
    Log-Line "保存 Key 中... (id=$id)"
    Invoke-Background -Payload @{ Action = "save-key"; Id = $id; Key = $keyText } -Tag "save-key"
})

$autoButton.Add_Click({
    if ($script:Busy) { return }
    if (-not $script:SelectedId) {
        Show-Error "请先选中或保存一个 profile。" ""
        return
    }
    $id = $script:SelectedId
    $keyText = $keyBox.Text
    $useStdin = ($keyText -and $script:KeyDirty)
    Set-Busy "自动配置"
    Log-Line "自动配置中（拉取模型列表）..."
    $payload = @{ Action = "auto-configure"; Id = $id; UseStdin = $useStdin }
    if ($useStdin) { $payload["Key"] = $keyText }
    Invoke-Background -Payload $payload -Tag "auto-configure"
})

$testButton.Add_Click({
    if ($script:Busy) { return }
    if (-not $script:SelectedId) {
        Show-Error "请先选中一个 profile。" ""
        return
    }
    $id = $script:SelectedId
    Set-Busy "测试选中配置"
    Log-Line "测试选中配置中（直接打上游）..."
    Invoke-Background -Payload @{ Action = "test-selected"; Id = $id } -Tag "test-selected"
})

$applyButton.Add_Click({
    if ($script:Busy) { return }
    if (-not $script:SelectedId) {
        Show-Error "请先选中一个 profile。" ""
        return
    }
    $p = Get-CurrentProfile
    if ($p -and -not $p.apiKeySaved) {
        Show-Error "该 profile 未保存 API Key，无法应用。" "先在「API Key」输入框填入 Key 并点「保存 Key」。"
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show($form, "确认要把 profile 「$($p.name)」 应用到 Word 网关吗？`r`n这会重启本机 gateway 和 cloudflared tunnel。", "确认", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $id = $script:SelectedId
    Set-Busy "应用到 Word 网关"
    Log-Line "应用中（重启网关 + tunnel，可能需要 10-20 秒）..."
    Invoke-Background -Payload @{ Action = "apply"; Id = $id } -Tag "apply"
})

$testPublicButton.Add_Click({
    if ($script:Busy) { return }
    Set-Busy "测试公网入口"
    $publicUrl = "当前配置的公网入口"
    if ($script:StatusCache -and $script:StatusCache.publicUrl) {
        $publicUrl = [string]$script:StatusCache.publicUrl
    }
    Log-Line "测试公网入口中（$publicUrl）..."
    Invoke-Background -Payload @{ Action = "test-public" } -Tag "test-public"
})

$startButton.Add_Click({
    if ($script:Busy) { return }
    Set-Busy "启动网关"
    Log-Line "启动/修复 网关 + tunnel..."
    Invoke-Background -Payload @{ Action = "start" } -Tag "start"
})

# === 搜索框事件 ===
$searchBox.Add_Enter({
    if ($searchBox.Text -eq "搜索配置...") { $searchBox.Text = "" }
})
$searchBox.Add_Leave({
    if (-not $searchBox.Text.Trim()) { $searchBox.Text = "搜索配置..." }
})
$searchBox.Add_TextChanged({
    if ($searchBox.Text -ne "搜索配置...") { Render-ProfileList }
})

# === 复制配置 ===
$copyButton.Add_Click({
    if ($script:Busy) { return }
    $p = Get-CurrentProfile
    if (-not $p) {
        Show-Error "请先选中一个 profile 再复制。" ""
        return
    }
    $script:SelectedId = ""
    $script:LoadingProfile = $true
    $nameBox.Text = [string]$p.name + "（副本）"
    $baseUrlBox.Text = [string]$p.baseUrl
    $routes = $p.routes
    $opusBox.Text = if ($routes -and $routes.opus) { [string]$routes.opus } else { "" }
    $sonnetBox.Text = if ($routes -and $routes.sonnet) { [string]$routes.sonnet } else { "" }
    $haikuBox.Text = if ($routes -and $routes.haiku) { [string]$routes.haiku } else { "" }
    $keyBox.Text = ""
    $script:KeyDirty = $false
    $keyStateLabel.Text = "未保存（副本需重新填入 Key）"
    $keyStateLabel.ForeColor = $ColorWarning
    if ($presetBox.Items.Count -gt 0) { $presetBox.SelectedIndex = 0 }
    $apiFormatBox.SelectedIndex = 0
    $script:LoadingProfile = $false
    $logBox.Text = "已复制「$($p.name)」的配置，修改名称后点「保存配置」创建新 profile。"
    $nameBox.Focus()
    Update-SelectionVisual
})

# === 删除配置 ===
$deleteButton.Add_Click({
    if ($script:Busy) { return }
    if (-not $script:SelectedId) {
        Show-Error "请先选中一个 profile 再删除。" ""
        return
    }
    $p = Get-CurrentProfile
    if (-not $p) { return }
    $confirm = [System.Windows.Forms.MessageBox]::Show($form, "确认删除配置「$($p.name)」($($p.id))？`r`n`r`n此操作会同时删除已保存的 API Key，且不可撤销。", "确认删除", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $id = $script:SelectedId
    Set-Busy "删除配置"
    Log-Line "删除配置中（$id）..."
    Invoke-Background -Payload @{ Action = "delete-profile"; Id = $id } -Tag "delete-profile"
})

# === 批量测试 ===
$batchTestButton.Add_Click({
    if ($script:Busy) { return }
    if ($script:Profiles.Count -eq 0) {
        Show-Error "没有可测试的配置。" ""
        return
    }
    $ids = @()
    foreach ($p in $script:Profiles) { $ids += [string]$p.id }
    $idsStr = $ids -join "|"
    Set-Busy "批量测试"
    Log-Line "批量测试中（共 $($ids.Count) 个配置，请稍候）..."
    Invoke-Background -Payload @{ Action = "batch-test"; IdsStr = $idsStr } -Tag "batch-test"
})

$exportManifestButton.Add_Click({
    if ($script:Busy) { return }
    if (-not $script:SelectedId) {
        Show-Error "请先选中一个 profile。" ""
        return
    }
    Set-Busy "导出 manifest"
    Log-Line "正在导出 manifest.xml（$($script:SelectedId)）..."
    Invoke-Background -Payload @{ Action = "export-manifest"; Id = $script:SelectedId } -Tag "export-manifest"
})

$form.Add_Shown({
    Show-WelcomeForm
    Refresh-All-Async
})
$form.Add_FormClosing({ $jobTimer.Stop() })
[void]$form.ShowDialog()

# Cleanup
$jobTimer.Stop()
$jobTimer.Dispose()
$script:RunspacePool.Close()
$script:RunspacePool.Dispose()
