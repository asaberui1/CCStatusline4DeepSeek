[English](README_en.md) | **中文**

# Claude Code Statusline – DeepSeek 版

专为 [Claude Code](https://claude.ai/code) 定制的双行状态栏，显示模型、工作目录、Git 分支、上下文窗口进度、Token 用量及**会话累计成本（¥）**。为 **DeepSeek 模型**优化——自动获取余额并使用正确的定价。

![初始化界面](./fig/Initializing.jpg)
*初始化状态：第一行信息，尚无对话数据，显示模型、路径、分支、进度条和精力等级。*

![使用中界面](./fig/InUse.jpg)
*使用中状态：双行完整显示，第一行同初始化，第二行展示累计 Token 用量、会话累计成本及余额。*

## 功能特性

- **双行布局** — 模型 + 目录 + 分支 + 进度条 + 精力等级（第一行），Token + 成本（第二行）
- **方块进度条** — 16 格，根据剩余百分比着色（绿/黄/红）
- **Token 计数器** — 累计输入、累计输出、当前缓存读取（格式化为 K/M）
- **成本追踪** — 基于会话的 JSON 累计器（`~/.claude/cache/statusline_cost.json`）。  
  每轮对话的增量 Token 按 DeepSeek 费率（Flash、Pro 或回退）计价，使用 API 返回的**累计值**计算，计费更准确。
- **回卷检测** — 自动识别 Claude Code 客户端侧压缩（上下文回卷），避免重复计费。
- **DeepSeek 余额** — 通过 `ANTHROPIC_AUTH_TOKEN` 请求 `https://api.deepseek.com/user/balance`，缓存 60 秒
- **精力等级** — 低/中/高，带彩色圆点
- **Git 根目录高亮** — 路径中的仓库根目录名以粗体显示
- **路径缩略** — `$HOME` 自动替换为 `~` 以缩短路径

## 安装

1. 将脚本保存为 `~/.claude/statusline.sh` 并赋予执行权限：
   ```bash
   chmod +x ~/.claude/statusline.sh
   ```
2. 在 `~/.claude/settings.json` 中添加以下配置：
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline.sh"
     }
   }
   ```
3. 脚本会自动读取当前 Claude Code 会话环境中的 `$ANTHROPIC_AUTH_TOKEN`，通常无需手动设置——它已经可用。（如果你的 DeepSeek API 密钥已在 Claude Code 中配置，余额获取开箱即用。）

## 使用

Claude Code 会自动运行脚本并显示状态栏，无需手动调用。

### 色彩对照

| 颜色 | 用途 |
|------|------|
| 青色 | 模型名称 |
| 黄色 | 文件路径 |
| 绿色 | Git 分支名 / 进度条（>50%） |
| 紫色 | 输出 Token |
| 蓝色 | 输入 Token |
| 金色 | 成本金额 / 余额 |
| 灰色 | 次要信息（路径分隔符、分隔线）

## 定价（每百万 Token，单位 ¥）

| 模型   | 输入（缓存未命中） | 缓存读取（命中） | 输出   |
|--------|--------------------|------------------|--------|
| Flash  | ¥1.00              | ¥0.02            | ¥2.00  |
| Pro    | ¥3.00              | ¥0.025           | ¥6.00  |

回退使用 Flash 定价。数据来源：[DeepSeek 定价页](https://api-docs.deepseek.com/zh-cn/quick_start/pricing/)，网页最后访问时间：2026-06-07。

## 成本累计说明

脚本使用 DeepSeek API 返回的累计 Token 值来计算每轮对话的增量成本，而不是依赖当前快照。这意味着：

- **更准确的计费**：即使发生上下文回卷，成本也不会重复计算
- **回卷检测**：当检测到客户端侧压缩时，快照会自动更新，防止后续请求误判为新对话
- **缓存成本**：缓存读取和创建成本基于非负增量计算（最佳近似）

> **⚠️ 关于成本估算精度**：余额来自 DeepSeek API，精确可靠。累计成本基于 Token 用量 × 模型定价估算，由于**无法从 API 获取精确的缓存命中/未命中拆分**，缓存部分的成本分摊是近似值。实际费用请以 DeepSeek 对账单为准。

## 文件

### 缓存文件

- `~/.claude/cache/statusline_cost.json` — 按会话的累计成本
- `~/.claude/cache/statusline_balance.cache` — 余额缓存（60 秒）

### 输入数据格式

脚本从标准输入读取 Claude Code 发送的 JSON，核心字段如下：

```json
{
  "model": { "display_name": "DeepSeek V4 Flash", "id": "deepseek-v4-flash" },
  "session_name": "my-session",
  "session_id": "abc123",
  "workspace": { "current_dir": "/path/to/repo" },
  "context_window": {
    "remaining_percentage": 82.5,
    "current_usage": {
      "input_tokens": 15234,
      "output_tokens": 8901,
      "cache_read_input_tokens": 5000,
      "cache_creation_input_tokens": 2000
    },
    "total_input_tokens": 150000,
    "total_output_tokens": 75000
  },
  "effort": { "level": "medium" }
}
```

脚本使用 `total_input_tokens` / `total_output_tokens`（累计值）计算增量成本，而非当前快照值。

### 成本文件结构

`statusline_cost.json` 以会话 ID 为键，存储每个会话的累计数据：

```json
{
  "session_id_1": {
    "total_cost": 0.1234,
    "prev_in": 15234,
    "prev_out": 8901,
    "prev_cache_read": 5000,
    "prev_cache_create": 2000,
    "prev_total_in": 150000,
    "prev_total_out": 75000,
    "prev_remaining": 82.5
  }
}
```

## License

MIT
