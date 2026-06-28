# 本次改动说明

## 一、核心功能修复

### 1. 批量测试 ID 传递修复
- **问题**：批量测试时配置 ID 被错误替换为当前 PowerShell 进程 ID，导致全部测试失败。
- **根因**：`$pid` 是 PowerShell 自动变量，表示当前进程 ID，无法被赋值覆盖；在 Runspace 中赋值为数组元素时失效并返回 PID。
- **修复**：将循环变量从 `$pid` 改名为 `$profileId`，并清理了调试日志输出。

## 二、UI 美化与交互优化

### 1. 按钮体系重构
- 统一按钮颜色语义：
  - **蓝色**：保存配置、应用网关、启动/修复网关
  - **绿色**：测试选中、批量测试、测试公网、新建配置
  - **红色**：删除配置、删除当前
  - **灰色**：保存 Key、自动配置、复制配置、复制当前、刷新
- 为按钮添加 Unicode 图标，简化文字标签：
  - `✓ 保存配置`、`⌘ 保存 Key`、`⚙ 自动配置`
  - `▶ 测试选中`、`➜ 应用网关`、`↗ 测试公网`
  - `⧉ 复制配置`、`⚡ 批量测试`、`× 删除配置`
  - `+ 新建配置`、`↻ 刷新`、`⧉ 复制当前`、`▶ 启动 / 修复 网关`
- 添加鼠标悬停和按下颜色反馈。

### 2. 日志区域升级
- `TextBox` 替换为 `RichTextBox`，支持按语义着色：
  - 时间戳：灰色
  - 成功/通过：绿色
  - 失败/错误：红色
  - 警告：黄色
- 清空日志按钮简化为「清空」，移至标题栏右侧。

### 3. 左侧配置列表精简
- 卡片高度从 96px 缩减至 78px，间距更紧凑。
- ID 改为灰色小字。
- Key 状态改为色点 + 文字提示。
- 模型映射移至右下角右对齐。

### 4. 右侧表单对齐
- 所有标签改为右对齐（固定 80px），输入框左对齐成两列。
- 模型映射标签简化为 `opus →`、`sonnet →`、`haiku →`。
- API Key 输入框增加占位提示「留空不覆盖已保存 Key」。
- 按钮整体上移，布局更紧凑。

### 5. 顶部标题区优化
- 当前生效配置名右侧增加 Gateway 状态徽章（运行中/已停止）。
- 状态信息简化为 `Tunnel · Key · API 格式` 和模型映射两行。

## 三、新增功能：一键导出 manifest.xml

### 1. 功能说明
新增「↓ 导出 manifest.xml」按钮，可根据当前选中的 profile 自动生成 Office 插件清单文件（manifest.xml），用于导入 Word/Excel/PowerPoint。

### 2. 生成逻辑
- 以 `word-deepseek-manifest.example.xml` 为模板。
- 自动替换以下字段：
  - `gateway_url`：优先使用公网入口 `PUBLIC_URL`，否则回退到本地 `http://127.0.0.1:8790`。
  - `gateway_token`：从 `.env` 读取 `GATEWAY_ACCESS_TOKEN`；若不存在则自动生成并写入 `.env`。
  - `gateway_api_format`：取当前 profile 的 API 格式。
  - `<Id>`：每次导出生成新的 GUID，避免冲突。
- 导出文件默认保存为当前目录下的 `word-deepseek-manifest-<profile-id>.xml`。
- 导出成功后自动打开文件所在文件夹并选中该 XML。

### 3. CLI 支持
```bash
python word-switch-v2.py profile export-manifest <profile-id> [--url URL] [-o 输出路径]
```

## 四、已知限制

- `gateway_url` 和 `gateway_token` 是全局 gateway 配置，不在 profile 详情页中单独设置。
- 公网入口需要用户自行配置 cloudflared tunnel；本地使用可忽略 tunnel。
- manifest.xml 导入 Word 的操作仍需在 Word 中手动完成。
