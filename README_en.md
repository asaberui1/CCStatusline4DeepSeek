**English** | [中文](README.md)

# Claude Code Statusline – DeepSeek Edition

A customizable two-line status bar for [Claude Code](https://claude.ai/code) that shows model, workspace, git branch, context window progress, token usage, and **session-based cost accumulation (¥)**. Optimized for **DeepSeek models** – automatically fetches your balance and uses correct pricing.

![Initializing](./fig/Initializing.jpg)
*Initializing state: single-line display with model, path, branch, progress bar, and effort level — no conversation data yet.*

![In Use](./fig/InUse.jpg)
*In-use state: full two-line display — line 1 same as above, line 2 shows cumulative token usage, session cost, and balance.*

## Features

- **Two-line layout** – model + dir + branch + progress bar + effort (line 1), tokens + cost (line 2)
- **Block progress bar** – 16 blocks, colored by remaining percentage (green/yellow/red)
- **Token counters** – cumulative input, cumulative output, current cache read (formatted as K/M)
- **Cost tracking** – per-session JSON accumulator (`~/.claude/cache/statusline_cost.json`).  
  Each turn's delta tokens are priced using DeepSeek rates (Flash, Pro, or fallback), calculated from the API's **cumulative values** for better accuracy.
- **Rewind detection** – automatically detects Claude Code client-side compaction (context rewinds) to avoid double billing.
- **DeepSeek balance** – cached (60s) via `ANTHROPIC_AUTH_TOKEN` to `https://api.deepseek.com/user/balance`
- **Effort level** – low/medium/high with colored dot
- **Git root highlighting** – bold the repo root directory name in path display
- **Path shortening** – `$HOME` replaced with `~` for compact display

## Installation

1. Save the script as `~/.claude/statusline.sh` and make it executable:
   ```bash
   chmod +x ~/.claude/statusline.sh
   ```
2. Add the following to your `~/.claude/settings.json`:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline.sh"
     }
   }
   ```
3. The script automatically reads `$ANTHROPIC_AUTH_TOKEN` from the current Claude Code session's environment, so you typically don't need to manually set this environment variable – it's already available. (Balance fetching works out of the box if your DeepSeek API key is configured in Claude Code.)

## Usage

Claude Code will automatically run the script and display the status bar. No manual invocation needed.

### Color Reference

| Color | Usage |
|-------|-------|
| Cyan | Model name |
| Yellow | File path |
| Green | Git branch name / progress bar (>50%) |
| Magenta | Output tokens |
| Blue | Input tokens |
| Gold | Cost / Balance |
| Dim (Gray) | Secondary info (path separators, divider) |

## Pricing (¥ per million tokens)

| Model  | Input (cache miss) | Cache read (hit) | Output |
|--------|--------------------|------------------|--------|
| Flash  | ¥1.00              | ¥0.02            | ¥2.00  |
| Pro    | ¥3.00              | ¥0.025           | ¥6.00  |

Fallback = Flash pricing. Source: [DeepSeek Pricing Page](https://api-docs.deepseek.com/zh-cn/quick_start/pricing/), last accessed: 2026-06-07.

## Cost Accumulation Notes

The script uses DeepSeek API's cumulative token values to calculate per-turn incremental costs, rather than relying on current snapshots. This means:

- **More accurate billing**: costs are not duplicated even when context rewinds occur
- **Rewind detection**: when client-side compaction is detected, snapshots update automatically to prevent subsequent requests from being misidentified as new turns
- **Cache costs**: cache read and creation costs are calculated from non-negative deltas (best approximation)

> **⚠️ About cost estimation accuracy**: Balance comes from the DeepSeek API and is accurate. Cumulative cost is estimated based on token usage × model pricing. Since **the API does not expose the exact cache hit/miss breakdown**, the cache cost allocation is an approximation. Always refer to your DeepSeek billing statement for actual charges.

## Files

### Cache Files

- `~/.claude/cache/statusline_cost.json` – per-session cumulative cost
- `~/.claude/cache/statusline_balance.cache` – cached balance (60s)

### Input JSON Format

The script reads a JSON payload from stdin sent by Claude Code. Key fields:

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

The script uses `total_input_tokens` / `total_output_tokens` (cumulative values) to calculate delta costs, rather than snapshot values.

### Cost File Structure

`statusline_cost.json` is keyed by session ID, storing accumulated data:

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
