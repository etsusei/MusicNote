# Musicnote

Musicnote 是一个自用的 macOS 音乐学习与和弦知识库。从喜欢的 Jazz、Funk、R&B 歌曲里圈出一个片段，按下面的顺序处理：

1. 确认 BPM 和调性
2. 用 Logic 自带模型拆成六轨，单选一轨
3. 用 MuScriptor 转成 MIDI，人工校对
4. 分组和弦、识别级数，让 Codex 或 Claude Code 解释骨架
5. 写笔记，在 Playground 里重组素材，导出 MIDI 到 Logic

另外可以把片段的鼓用 Logic 13 拆成单个鼓件、转成步进节奏型，在鼓机里修改，再放到 Playground 的和弦下面一起播放。

还有一个练琴模式：把钢琴分轨转出的 MIDI 和音频以半速送到 Logic 手动校准，再放回来，看着下落的音符跟着原曲练，可以变速不变调、循环某几个小节；接上电钢琴后会显示按对还是按错。

设计文档：[docs/开发文档.md](docs/开发文档.md)、[docs/待定事项.md](docs/待定事项.md)、[docs/练琴模式.md](docs/练琴模式.md)。

## 运行环境（本机）

- macOS 27，Apple Silicon
- Logic Pro 13.0（只引用 App 内的拆轨、鼓细分和 Chord ID 模型，不复制；12.3.1/12.4 也能拆轨，但没有鼓细分）
- Swift 6.4 命令行工具（不需要 Xcode）
- `/opt/homebrew/bin/ffmpeg`、`ffprobe`
- `/opt/homebrew/bin/yt-dlp` 和 `deno`（`brew install yt-dlp`，会一起装上 deno；只有从 Instagram / YouTube 链接导入时才用）
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
| `Sources/MusicnotePractice` | 练琴模式不依赖界面的部分：读 MIDI 文件、往返 Logic 的时间换算和位置比对、给 Logic 用的半速音频、变速播放和它的时钟 |
| `Sources/RubberBand` | Rubber Band Library 4.0.0 的源码（第三方，GPL），变速不变调用 |
| `Sources/MusicnoteChecks` | 核心检查；`e2e` / `seed` 子命令用真实歌曲跑后端，`practice` 子命令对做完的片段跑一遍 Logic 导出和导回 |
| `Sources/StemSeparator` | Logic 模型拆轨 helper（JSONL 进度） |
| `workers/` | Essentia、Musicpy、MuScriptor 适配器和 MP3 编码脚本 |

## 开发用的环境变量

下面这些只在设置时才生效：

- `MUSICNOTE_DATA_ROOT`：改用另一个数据目录
- `MUSICNOTE_SNAPSHOT_DIR` + `MUSICNOTE_ROUTES`：依次打开页面并把窗口存成 PNG
- `MUSICNOTE_FLOW_AUDIO`：用真实音频驱动完整流程，并写出 `flow.txt` 检查记录
- `MUSICNOTE_FLOW_LINK`：用真实 Instagram 或 YouTube 链接走到速度调性检测（不拆轨、不转录），并写出 `flow.txt`
- `MUSICNOTE_PRACTICE_DRIVE`：配合 `MUSICNOTE_ROUTES=practice:<片段 ID>`，静音地把练琴页真的播一遍（速度、变速、循环、快捷键、虚拟 MIDI 键盘），并写出 `practice.txt`
- `MUSICNOTE_SNAPSHOT_FRAME`：截图时带上窗口的标题栏

## 第三方代码与许可证

`Sources/RubberBand` 里带着 [Rubber Band Library](https://breakfastquay.com/rubberband/) 的源码，它以 GNU GPL（第 2 版或更新）发布，许可证全文在 [Sources/RubberBand/vendor/COPYING](Sources/RubberBand/vendor/COPYING)。Musicnote 链接了它，所以编译出来的程序整体要按 GPL 的条件使用和分发。这个项目只是自用，不发布二进制。
