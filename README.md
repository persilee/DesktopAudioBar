# DesktopAudioBar — 壁纸级底部音频频谱条

一个完全本地、无依赖的 macOS 桌面频谱条：**频谱条显示在壁纸之上、所有应用窗口（Ghostty 等）之下**。

- 音频：ScreenCaptureKit 原生捕获**系统音频**（无需 BlackHole 虚拟声卡）
- 渲染：vDSP FFT + 对数频段聚合 + 自动增益 + 峰值阻尼，60fps，CPU 占用极低
- 样式：无边框透明窗口，底部 48px，蓝紫渐变（Catppuccin 配色，可改）

## 编译

```bash
cd DesktopAudioBar
./build.sh
```

产物：`build/DesktopAudioBar.app`（已 ad-hoc 签名）

## 运行

```bash
open build/DesktopAudioBar.app
```

**首次运行**：系统会弹窗请求「屏幕录制」权限（ScreenCaptureKit 捕获系统音频需要）→ 点 **允许**。
若已拒绝，去 系统设置 → 隐私与安全性 → 屏幕录制 → 打开 DesktopAudioBar，然后重新运行。

授权后，屏幕底部就会出现频谱条，Ghostty 等应用窗口会正常盖在它上面。

## 退出

```bash
killall DesktopAudioBar
```

## 自定义外观 / 行为

编辑 `Sources/main.swift` 顶部 `Config` 区，改完重新 `./build.sh`：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `barHeight` | 48 | 频谱条高度（px，贴屏幕底部） |
| `barCount` | 48 | 条形数量 |
| `barOpacity` | 0.90 | 条形不透明度 0~1 |
| `barGap` | 2 | 条形间距 px |
| `topColor` / `bottomColor` | #89b4fa / #cba6f7 | 渐变两端颜色 |
| `mirror` | false | true = 上下镜像成两条 |
| `levelOffset` | 1 | 窗口层级：1 = 桌面图标之上、应用之下；0 = 图标之下 |
| `useAGC` | true | 自动增益（跟随音量自适应） |
| `gain` | 1.0 | 手动增益（`useAGC=false` 时生效） |
| `levelDecay` | 0.82 | 条形回落速度（越小回落越快） |
| `agcDecay` | 0.985 | 自动增益峰值衰减（越小响应越灵敏） |

## 开机自启

系统设置 → 通用 → 登录项与扩展 → 点击 + 添加 `build/DesktopAudioBar.app`

## 已知限制

- 仅显示在主屏（NSScreen.main）
- 无界面/菜单栏图标，退出用 `killall DesktopAudioBar`
- 若底部挡到桌面图标，把 `levelOffset` 改为 0（图标之下）或调高 `barHeight` 数值位置
