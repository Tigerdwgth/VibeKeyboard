# VibeKeyboard — CLAUDE.md

## 已知 Bug 和踩坑记录

### macOS 权限
- **麦克风权限**: .app 必须用 python3 硬链接放在 `Contents/MacOS/` 下，macOS TCC 才能将权限关联到 bundle ID。符号链接不行，bash 脚本 exec python 也不行。用 `build_app.sh` 构建。
- **辅助功能权限**: 自动粘贴 (Cmd+V 模拟) 需要辅助功能权限。CGEvent 和 osascript System Events 都需要。首次失败会自动打开系统设置页面引导授权。
- **NSVisualEffectView 白边**: 用 `layer().setCornerRadius_()` 会导致圆角处白边。正确做法是用 `setMaskImage_()` 配合 `NSBezierPath` 生成圆角蒙版。

### ASR 引擎
- **SenseVoice 输出标签**: SenseVoice 结果带 `<|zh|><|NEUTRAL|>` 等标签，需要用正则清理。
- **首次识别慢**: SenseVoice 第一次推理约 7 秒（JIT 编译），后续 <1 秒。
- **FunASR WebSocket 服务**: 之前尝试过 WebSocket 服务端模式，但 websockets 库版本不兼容导致服务端不返回结果。已改为直接用 Python API (`AutoModel.generate`)。
- **funasr_wss_server.py SSL**: 服务脚本默认启用 SSL (`--certfile` 默认指向不存在的路径)，必须传 `--certfile ""` 禁用。
- **funasr_wss_server.py --hotword**: 该参数在某些版本的脚本中不存在，传了会导致 argparse exit code 2。

### LLM 润色
- **千问 0.8B 幻觉严重**: 输入 "分别使用下面这两个权重" 输出变成完全无关的医院内容。0.8B 模型太小不适合做文本润色。已暂时禁用 LLM 润色，改用本地正则规则。
- **建议**: 如需 LLM 润色，至少用 3B+ 模型，或用云端 API。

### UI
- **NSTextField 垂直居中**: NSTextField 不原生支持垂直居中。解决方案：用 `boundingRectWithSize` 计算文字实际高度，手动设置 text_field 的 y 偏移使其在窗口中居中。
- **overlay 初始大小**: 空文本时应显示小圆点 (36px)，不要用默认宽度，否则会出现很长的空白条。
- **rumps + pywebview 冲突**: pywebview 的 `webview.start()` 会创建自己的 NSApplication 事件循环，与 rumps 冲突导致死锁。解决方案：用 WKWebView 在 NSWindow 中渲染（与 rumps 共享同一个 NSApplication）。
- **rumps + AVFoundation 死锁**: `AVCaptureDevice.requestAccessForMediaType_completionHandler_` 如果在 NSApplication 启动前调用（比如在 `run()` 方法开头），会死锁。必须放在后台线程且在 app 启动之后。

### 构建和部署
- **x86_64 miniconda**: macair 上旧版 miniconda 是 x86_64 (Rosetta)，导致性能差、权限路径不对。已换成 arm64 原生 miniconda3。
- **SSH 启动 GUI**: 通过 SSH `open VibeKeyboard.app` 启动的进程无法显示菜单栏图标。必须从 macOS 本地 GUI 会话启动（Finder 双击或本地终端 `open`）。

## 项目结构

- 默认 ASR 后端: `sensevoice`（可在菜单栏切换到 `paraformer`）
- 流式识别间隔: 0.2s
- 去水词: 本地正则规则 (asr/polisher.py)
- LLM 润色: 已禁用（代码保留，config 中配置 `llm_api_url` 可重新启用）
