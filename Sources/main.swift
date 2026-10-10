import AppKit
import Accelerate
import CoreMedia
import ScreenCaptureKit

// ============================================================================
// DesktopAudioBar — 壁纸级底部音频频谱条（macOS 27 / Apple Silicon）
//
// 层级：desktopIcon + 1 = 壁纸与桌面图标之上、所有应用窗口（Ghostty 等）之下
// 音频：ScreenCaptureKit 原生捕获系统音频（无需 BlackHole 虚拟声卡）
//
// v2 律动引擎（对标 cava 的丝滑效果）：
//   1. Hann 窗：减少频谱泄漏，波形干净
//   2. 正确 packed 填充：实部=偶数样本、虚部=奇数样本（修复频谱扭曲）
//   3. 时间域指数平滑：上升平滑跟手、下降缓慢衰减（gravity 效果）
//   4. 平滑峰值跟踪 AGC：自动增益稳定不抖动
//   5. 动态范围压缩（sqrt）：全频段均匀响应
//
// 修改外观/行为请编辑 Config 区；改完重新执行 ./build.sh 即可。
// ============================================================================

/// 调试文件日志（确认问题后可删除）
enum DebugLog {
    static let path = "/tmp/desktop-audio-bar.log"
    static func write(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

enum Config {
    // —— 外观 ——
    static let baseHeight: CGFloat = 2          // 静音时也显示的条形基础高度（px，近 0，cava 风格）
    static let amplitude: CGFloat = 280         // 音乐律动幅度：基础高度上额外升高的最大高度（px）
    static let barHeight: CGFloat = baseHeight + amplitude   // 窗口总高
    static let barCount = 48                        // 条形数量
    static let barOpacity: CGFloat = 0.95           // 条形不透明度 0~1
    static let barGap: CGFloat = 2                  // 条形间距 px
    static let barCornerRadius: CGFloat = 2         // 条形圆角（0 = 纯矩形）
    static let topColor    = NSColor(srgbRed: 0.54, green: 0.71, blue: 0.98, alpha: 1.0)   // #89b4fa 蓝
    static let bottomColor = NSColor(srgbRed: 0.80, green: 0.65, blue: 0.97, alpha: 1.0)   // #cba6f7 紫
    static let mirror = false                       // true = 上下镜像成两条

    // —— 窗口层级 ——
    static let levelOffset = 1                      // desktopIcon + 1 = 图标之上应用之下；0 = 图标之下

    // —— 音频分析（v3 = 完整复刻 cava 信号链）——
    static let fftSize = 4096                       // FFT 窗口
    static let sampleRate = 48000
    static let useAGC = true                        // 自适应增益（cava autosens）
    static let gain: Float = 1.0                    // 手动增益（useAGC=false 时生效）
    static let logCurve: Float = 1.3                // 频段对数映射指数（越大低频占比越高）
    // cava 平滑/增益参数（cavacore.c 默认值，60fps 换算）
    static let framerateMod: Float = 66.0 / 60.0    // 帧率修正
    static let noiseReduction: Float = 0.77         // 泄漏积分器反馈系数（越大记忆越长）
    static let integralMod: Float = pow(framerateMod, 0.1)   // 积分器修正
    static let gravityMod: Float = pow(framerateMod, 2.5) * 2.0 / noiseReduction  // 下落曲线系数
    static let fallStep: Float = 0.028              // 下落步进/帧
    static let boostPow: Float = 0.85               // 高频提升指数（cava: eq *= f^0.85）
    static let sensUp: Float = 0.001                // 不过冲时 sens 上升速率
    static let sensDown: Float = 0.02               // 过冲时 sens 下降速率
    static let sensInitBoost: Float = 0.1           // 初始快速上升速率
}

// MARK: - 音频环形缓冲

final class AudioRingBuffer {
    private var buffer: [Float]
    private let capacity: Int
    private var writeIndex = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for s in samples {
            buffer[writeIndex] = s
            writeIndex = (writeIndex + 1) % capacity
        }
    }

    func latest(_ count: Int) -> [Float] {
        let n = min(count, capacity)
        var out = [Float](repeating: 0, count: n)
        lock.lock()
        defer { lock.unlock() }
        var idx = (writeIndex - n + capacity) % capacity
        for i in 0..<n {
            out[i] = buffer[idx]
            idx = (idx + 1) % capacity
        }
        return out
    }
}

// MARK: - ScreenCaptureKit 音频捕获

final class AudioCapture: NSObject, SCStreamOutput {
    let ring = AudioRingBuffer(capacity: 16384)
    private var stream: SCStream?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "DesktopAudioBar", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "未找到可用显示器"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Config.sampleRate
        config.channelCount = 2
        // 视频帧我们不消费，给一个小尺寸 + 低频投递，仅用于驱动投递管线
        config.width = 64
        config.height = 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 8
        config.showsCursor = false

        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        let queue = DispatchQueue(label: "DesktopAudioBar.audio")
        // macOS 14+ 必须同时注册 .screen output 才能驱动音频投递管线
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        DebugLog.write("capture started OK")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        if outputType == .screen { return }
        let samples = Self.extractMonoSamples(sampleBuffer)
        ring.append(samples)
    }

    /// 从 CMSampleBuffer 提取单声道 Float 序列（兼容 Float32 / Int16、交错 / 非交错）
    static func extractMonoSamples(_ sb: CMSampleBuffer) -> [Float] {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return [] }
        let asbd = asbdPtr.pointee

        var sizeNeeded: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 8)
        defer { raw.deallocate() }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil,
            bufferListOut: raw.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr else { return [] }

        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let numSamples = Int(CMSampleBufferGetNumSamples(sb))

        var mono: [Float] = []

        if isInterleaved {
            guard buffers.count >= 1 else { return [] }
            let buf = buffers[0]
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return [] }
            let frames = min(numSamples, Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            mono.reserveCapacity(frames)
            if isFloat {
                let p = data.assumingMemoryBound(to: Float.self)
                if channels >= 2 {
                    for f in 0..<frames { mono.append((p[f * channels] + p[f * channels + 1]) * 0.5) }
                } else {
                    for f in 0..<frames { mono.append(p[f]) }
                }
            } else {
                let p = data.assumingMemoryBound(to: Int16.self)
                if channels >= 2 {
                    for f in 0..<frames {
                        let l = Float(p[f * channels]) / 32768.0
                        let r = Float(p[f * channels + 1]) / 32768.0
                        mono.append((l + r) * 0.5)
                    }
                } else {
                    for f in 0..<frames { mono.append(Float(p[f]) / 32768.0) }
                }
            }
        } else {
            // 非交错：取第一个声道
            guard buffers.count >= 1 else { return [] }
            let buf = buffers[0]
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return [] }
            let count = min(numSamples, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
            if isFloat {
                let p = data.assumingMemoryBound(to: Float.self)
                mono = Array(UnsafeBufferPointer(start: p, count: count))
            } else {
                let p = data.assumingMemoryBound(to: Int16.self)
                mono = (0..<count).map { Float(p[$0]) / 32768.0 }
            }
        }
        return mono
    }
}

// MARK: - FFT 频谱分析（v3 = 完整复刻 cava 信号链）

final class SpectrumAnalyzer {
    private let n: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var re: [Float]
    private var im: [Float]
    private var mags: [Float]
    private var window: [Float]            // Hann 窗
    private var lastLevels: [Float]        // 上帧输出（无音频时返回）
    private(set) var lastRawMax: Float = 0

    // cava 状态
    private var sens: Float = 1.0
    private var sensInit = true
    private var silence = true
    private var cavaPrev: [Float]          // 上帧输出（clamp 前）
    private var cavaPeak: [Float]          // 峰值保持
    private var cavaFall: [Float]          // 下落进度
    private var cavaMem: [Float]           // 泄漏积分器记忆

    // 预计算频段
    private var bandStart: [Int] = []
    private var bandEnd: [Int] = []
    private var bandBoost: [Float] = []

    init(fftSize: Int, barCount: Int) {
        self.n = fftSize
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.re = [Float](repeating: 0, count: fftSize / 2)
        self.im = [Float](repeating: 0, count: fftSize / 2)
        self.mags = [Float](repeating: 0, count: fftSize / 2)
        self.lastLevels = [Float](repeating: 0, count: barCount)
        self.cavaPrev = [Float](repeating: 0, count: barCount)
        self.cavaPeak = [Float](repeating: 0, count: barCount)
        self.cavaFall = [Float](repeating: 0, count: barCount)
        self.cavaMem = [Float](repeating: 0, count: barCount)
        // Hann 窗：w[i] = 0.5 * (1 - cos(2πi/(n-1)))
        self.window = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize {
            window[i] = 0.5 * (1 - cos(2 * Float.pi * Float(i) / Float(fftSize - 1)))
        }
        // 频段范围 + 高频提升（cava: eq *= f^0.85，f 为频段中心频率 Hz）
        let ucount = fftSize / 2 - 1
        let curve = Config.logCurve
        for b in 0..<barCount {
            let start = min(Int(pow(Float(b) / Float(barCount), curve) * Float(ucount)), ucount)
            let end = min(Int(pow(Float(b + 1) / Float(barCount), curve) * Float(ucount)), ucount)
            bandStart.append(start)
            bandEnd.append(max(end, start + 1))
            let fc = Float((start + end) / 2) * Float(Config.sampleRate / 2) / Float(ucount)
            bandBoost.append(pow(fc / 1000.0, Config.boostPow))
        }
    }

    func levels(from samples: [Float], barCount: Int, gain: Float, useAGC: Bool, decay: Float) -> [Float] {
        guard samples.count == n else { return lastLevels }

        // 加窗 + 正确 packed 填充：实部=偶数样本、虚部=奇数样本
        re.withUnsafeMutableBufferPointer { reBuf in
            im.withUnsafeMutableBufferPointer { imBuf in
                for i in 0..<(n / 2) {
                    reBuf[i] = samples[2 * i] * window[2 * i]
                    imBuf[i] = samples[2 * i + 1] * window[2 * i + 1]
                }
                var split = DSPSplitComplex(realp: reBuf.baseAddress!, imagp: imBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))   // 幅度平方
            }
        }
        var count32: Int32 = Int32(n / 2)
        vvsqrtf(&mags, mags, &count32)                                  // 开方得幅度

        // 幅度归一化：Hann 窗使幅度减半，zrip bin 幅度 ≈ A*N/4 → 乘 4/N 得真实幅度 A
        let usable = mags.dropFirst().map { $0 * 4.0 / Float(n) }

        // —— cava: 频段聚合 = 幅度累加（不取平均）× 高频提升 ——
        var raw = [Float](repeating: 0, count: barCount)
        for b in 0..<barCount {
            var sum: Float = 0
            let s = bandStart[b]
            let e = min(bandEnd[b], usable.count)
            if e > s {
                for i in s..<e { sum += usable[i] }
            }
            raw[b] = sum * bandBoost[b]
        }

        // silence 检测（cava: 有非零样本才算有声）
        let maxLevel = raw.max() ?? 0
        lastRawMax = maxLevel
        if maxLevel < 1e-5 { silence = true } else { silence = false }

        // —— cava: sens 自适应乘性增益 + falloff + integral + clamp ——
        let fm = Config.framerateMod
        let alpha = Config.noiseReduction / Config.integralMod   // 泄漏积分器反馈 ≈0.763
        let gMod = Config.gravityMod
        var overshoot = false
        var bars = [Float](repeating: 0, count: barCount)
        for b in 0..<barCount {
            var out = raw[b]
            if useAGC { out *= sens }
            else { out *= gain }

            // falloff：本帧值 < 上帧处理后的值 → 从峰值按抛物线缓慢滑落（cava 丝滑手感）
            if out < cavaPrev[b] && Config.noiseReduction > 0.1 {
                out = cavaPeak[b] * (1.0 - cavaFall[b] * cavaFall[b] * gMod)
                if out < 0 { out = 0 }
                cavaFall[b] += Config.fallStep
            } else {
                cavaPeak[b] = out
                cavaFall[b] = 0
            }
            cavaPrev[b] = out

            // integral：泄漏积分器（放大 + 记忆，让条"赖在高位"缓慢回落）
            out = cavaMem[b] * alpha + out
            cavaMem[b] = out

            // clamp 1.0 + overshoot 检测（cava 仅在 autosens 模式 clamp）
            if useAGC {
                if out > 1.0 { out = 1.0; overshoot = true }
                if out < 0 { out = 0 }
            } else {
                out = max(0, min(1, out))
            }
            bars[b] = out
        }

        // —— cava: sens 调整（过冲则降，否则缓慢升；初始快速升）——
        if useAGC {
            if overshoot {
                sens *= (1.0 - Config.sensDown * fm)
                sensInit = false
            } else if !silence {
                sens *= (1.0 + Config.sensUp * fm * 1.0)
                if sensInit { sens *= (1.0 + Config.sensInitBoost * fm) }
            }
            sens = min(max(sens, 0.01), 100.0)
        }

        lastLevels = bars
        return bars
    }
}

// MARK: - 频谱视图

final class SpectrumView: NSView {
    private var levels: [Float] = [Float](repeating: 0, count: Config.barCount)
    private var statusText: String?
    private var barColors: [NSColor] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // 预计算条形颜色（自下而上：bottom → top 渐变），避免每帧创建渐变对象
        for i in 0..<max(Config.barCount, 1) {
            let t = CGFloat(i) / CGFloat(max(Config.barCount - 1, 1))
            barColors.append(lerp(Config.bottomColor, Config.topColor, t))
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func lerp(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let aRGB = a.usingColorSpace(.sRGB)!
        let bRGB = b.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: aRGB.redComponent + (bRGB.redComponent - aRGB.redComponent) * t,
                       green: aRGB.greenComponent + (bRGB.greenComponent - aRGB.greenComponent) * t,
                       blue: aRGB.blueComponent + (bRGB.blueComponent - aRGB.blueComponent) * t,
                       alpha: 1.0)
    }

    func update(levels: [Float]) {
        self.levels = levels
        needsDisplay = true
    }

    func showStatus(_ text: String) {
        statusText = text
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        if let text = statusText {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(white: 1.0, alpha: 0.95)
            ]
            (text as NSString).draw(at: NSPoint(x: 16, y: bounds.midY - 8), withAttributes: attrs)
            return
        }

        ctx.setAlpha(Config.barOpacity)
        defer { ctx.setAlpha(1.0) }

        let count = max(levels.count, 1)
        let gap = Config.barGap
        let padding: CGFloat = 4
        let barW = max(1, (bounds.width - padding * 2 - gap * CGFloat(count - 1)) / CGFloat(count))

        // 非镜像：条形绘制区 = 整个窗口高度；镜像：上下各半
        let bandH = Config.mirror ? bounds.height / 2 : bounds.height
        drawBars(in: NSRect(x: 0, y: 0, width: bounds.width, height: bandH),
                 levels: levels, reversed: false, barW: barW, gap: gap, padding: padding)

        if Config.mirror {
            drawBars(in: NSRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bandH),
                     levels: levels, reversed: true, barW: barW, gap: gap, padding: padding)
        }
    }

    private func drawBars(in rect: NSRect, levels: [Float], reversed: Bool, barW: CGFloat, gap: CGFloat, padding: CGFloat) {
        let h = rect.height
        for (i, lv) in levels.enumerated() {
            let x = rect.minX + padding + CGFloat(i) * (barW + gap)
            // 条形高度 = 基础高度 + 律动幅度（clamp 到绘制区域，防镜像溢出）
            let bh = min(Config.baseHeight + CGFloat(lv) * Config.amplitude, h)
            let y = reversed ? rect.maxY - bh : rect.minY
            let barRect = NSRect(x: x, y: y, width: barW, height: bh)
            guard barRect.height >= 1 else { continue }
            let path = NSBezierPath(roundedRect: barRect, xRadius: Config.barCornerRadius, yRadius: Config.barCornerRadius)
            barColors[min(i, barColors.count - 1)].setFill()
            path.fill()
        }
    }
}

// MARK: - 应用入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []        // 每个屏幕一个窗口
    private var views: [SpectrumView] = []
    private let capture = AudioCapture()
    private let analyzer = SpectrumAnalyzer(fftSize: Config.fftSize, barCount: Config.barCount)
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindows()
        Task { await startCapture() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    /// 为所有已连接的显示器各创建一个频谱窗口（支持多屏）
    private func setupWindows() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        for screen in screens {
            let h = Config.mirror ? Config.barHeight * 2 : Config.barHeight
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                               width: screen.frame.width, height: h)

            let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            // 关键：桌面图标层级之上、普通应用窗口（Ghostty）之下
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + Config.levelOffset)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let view = SpectrumView()
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        DebugLog.write("created \(windows.count) window(s) for \(screens.count) screen(s)")
    }

    @MainActor private func startCapture() async {
        do {
            try await capture.start()
        } catch {
            let msg = "需要屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕录制 → 开启 DesktopAudioBar，然后重新运行"
            for v in views { v.showStatus(msg) }
            DebugLog.write("capture failed: \(error.localizedDescription)")
        }
    }

    private func tick() {
        let samples = capture.ring.latest(Config.fftSize)
        guard samples.count == Config.fftSize else { return }
        let levels = analyzer.levels(from: samples, barCount: Config.barCount,
                                     gain: Config.gain, useAGC: Config.useAGC, decay: 0)
        for v in views { v.update(levels: levels) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
