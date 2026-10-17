# Musicnote

Musicnote 是一个自用的 macOS 音乐学习与和弦知识库。从喜欢的 Jazz、Funk、R&B 歌曲里圈出一个片段，按下面的顺序处理：

1. 确认 BPM 和调性
2. 用 Logic 自带模型拆成六轨，单选一轨
3. 用 MuScriptor 转成 MIDI，人工校对
4. 分组和弦、识别级数，让 Codex 或 Claude Code 解释骨架
5. 写笔记，在 Playground 里重组素材，导出 MIDI 到 Logic

设计文档：[docs/开发文档.md](docs/开发文档.md)、[docs/待定事项.md](docs/待定事项.md)。

## 运行环境（本机）

- macOS 27，Apple Silicon
- Logic Pro 12.3.1（只引用 App 内的拆轨模型，不复制）
- Swift 6.4 命令行工具（不需要 Xcode）
- `/opt/homebrew/bin/ffmpeg`、`ffprobe`
- `uv`；Codex 与 Claude Code 的 CLI（`brew install --cask codex claude-code`），并已登录各自的订阅

## 一次性准备

```bash
# MuScriptor（第三方仓库，放在 muscriptor/，不提交）
cd muscriptor && uv sync && cd ..

# Essentia 与 Musicpy 各用一个 venv
uv venv --python 3.12 workers/essentia/.venv && uv pip install --python workers/essentia/.venv/bin/python essentia numpy
uv venv --python 3.12 workers/musicpy/.venv && uv pip install --python workers/musicpy/.venv/bin/python musicpy

# 试听音色（MIT，约 215 MB）
muscriptor/.venv/bin/python -c "from huggingface_hub import hf_hub_download as d; d('MuScriptor/assets','MuseScore_General.sf2',local_dir='Resources/SoundFonts')"
```

## 构建与运行

```bash
scripts/build_app.sh          # 生成 dist/Musicnote.app（release，ad-hoc 签名）
open dist/Musicnote.app

swift run MusicnoteChecks     # 核心逻辑检查（命令行工具没有 XCTest，用可执行程序代替）
```

数据存放在 `~/Library/Application Support/Musicnote`。完成的片段只保留选中分轨的 MP3、校正后的 MIDI、分析结果和笔记，不会复制或删除你的原曲。

## 代码结构

| 目录 | 内容 |
| --- | --- |
| `Sources/MusicnoteCore` | 数据模型、SQLite 存储、时间与乐理、和弦分组、MIDI 写出、流水线、provider 适配、Playground 规则 |
| `Sources/MusicnoteApp` | SwiftUI 三栏界面、AppKit 钢琴卷帘、AVAudioEngine 共享时钟、聊天 |
| `Sources/StemSeparator` | Logic 模型拆轨 helper（JSONL 进度） |
| `Sources/MusicnoteChecks` | 核心检查；`e2e` / `seed` 子命令用真实歌曲跑后端 |
| `workers/` | Essentia、Musicpy、MuScriptor 适配器和 MP3 编码脚本 |

## 开发用的环境变量

下面这些只在设置时才生效：

- `MUSICNOTE_DATA_ROOT`：改用另一个数据目录
- `MUSICNOTE_SNAPSHOT_DIR` + `MUSICNOTE_ROUTES`：依次打开页面并把窗口存成 PNG
- `MUSICNOTE_FLOW_AUDIO`：用真实音频驱动完整流程，并写出 `flow.txt` 检查记录
