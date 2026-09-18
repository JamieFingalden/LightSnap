import SwiftUI
import AVKit

private enum RecordingPalette {
    static let base = Color(red: 0.085, green: 0.09, blue: 0.11)
    static let panel = Color(red: 0.12, green: 0.125, blue: 0.15)
    static let accent = Color(red: 0.64, green: 0.59, blue: 1)

    static func colors(_ background: RecordingStyle.Background) -> [Color] {
        switch background {
        case .goldenGate: [.init(red: 0.10, green: 0.06, blue: 0.05), .init(red: 1.0, green: 0.62, blue: 0.20)]
        case .tahoe: [.init(red: 0.03, green: 0.10, blue: 0.22), .init(red: 0.45, green: 0.85, blue: 0.95)]
        case .sequoia, .custom: [.init(red: 0.09, green: 0.06, blue: 0.22), .init(red: 0.92, green: 0.35, blue: 0.72)]
        case .bigSur: [.init(red: 0.98, green: 0.60, blue: 0.30), .init(red: 0.30, green: 0.18, blue: 0.55)]
        case .catalina: [.init(red: 0.88, green: 0.52, blue: 0.35), .init(red: 0.02, green: 0.07, blue: 0.17)]
        case .sonoma: [.init(red: 0.22, green: 0.03, blue: 0.10), .init(red: 1.0, green: 0.45, blue: 0.30)]
        case .monterey: [.init(red: 0.05, green: 0.07, blue: 0.18), .init(red: 0.20, green: 0.80, blue: 0.78)]
        case .white: [.white, .white]
        case .black: [.black, .black]
        }
    }
}

struct RecordingSetupView: View {
    @ObservedObject var model: RecordingController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "record.circle").font(.system(size: 27)).foregroundStyle(RecordingPalette.accent)
                    .frame(width: 48, height: 48).background(RecordingPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("录下一段精彩操作").font(.system(size: 21, weight: .semibold))
                    Text("自动缩放、平滑鼠标，录完即可导出。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refreshSources() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新录制来源").accessibilityLabel("刷新录制来源").disabled(model.loading || model.isBusy)
            }
            .padding(.top, 42).padding(.horizontal, 26).padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 14) {
                Picker("录制范围", selection: $model.options.sourceKind) {
                    Label("屏幕", systemImage: "display").tag(0)
                    Label("窗口", systemImage: "macwindow").tag(1)
                    Label("区域", systemImage: "viewfinder").tag(2)
                }.pickerStyle(.segmented).labelsHidden()
                sourcePicker
            }.padding(.horizontal, 26).padding(.bottom, 18).disabled(model.isBusy)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourcePreview
                    VStack(spacing: 14) {
                        HStack {
                            Label("系统声音", systemImage: "speaker.wave.2")
                            Spacer()
                            Toggle("录制系统声音", isOn: $model.options.systemAudio).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        Divider().opacity(0.5)
                        HStack {
                            Label("麦克风", systemImage: "mic")
                            Spacer()
                            Picker("麦克风", selection: $model.options.microphoneID) {
                                Text("关闭").tag("")
                                ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                            }.labelsHidden().frame(maxWidth: 300)
                        }
                        HStack {
                            Label("摄像头", systemImage: "video")
                            Spacer()
                            Picker("摄像头", selection: $model.options.cameraID) {
                                Text("关闭").tag("")
                                ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                            }.labelsHidden().frame(maxWidth: 300)
                        }
                    }
                    .font(.system(size: 13)).padding(17).background(RecordingPalette.panel, in: RoundedRectangle(cornerRadius: 14))
                    HStack(spacing: 20) {
                        Picker("倒计时", selection: $model.options.countdown) {
                            Text("关闭").tag(0); Text("3 秒").tag(3); Text("5 秒").tag(5)
                        }
                        Picker("帧率", selection: $model.options.frameRate) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                    }
                    Toggle("记录快捷键", isOn: $model.options.recordShortcuts).font(.system(size: 12))
                        .help("需要辅助功能权限，仅记录 Command 或 Control 组合，不记录正文输入。")
                    if model.options.sourceKind == 0 || model.options.sourceKind == 2 {
                        Toggle("录屏中隐藏桌面图标", isOn: $model.options.hideDesktopIcons).font(.system(size: 12))
                    }
                    if let error = model.error {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            if model.permissionPane != nil { Button("打开权限设置", action: model.openPermissions).buttonStyle(.link) }
                        }
                    }
                }.padding(.horizontal, 26).padding(.bottom, 20)
                .disabled(model.isBusy)
            }.scrollIndicators(.hidden)
            VStack(spacing: 11) {
                Button(action: model.start) {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill")
                        Text(model.options.sourceKind == 2 ? "选择区域并录制" : "开始录制").fontWeight(.semibold)
                    }.frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(.borderedProminent).tint(RecordingPalette.accent).controlSize(.large)
                .keyboardShortcut(.defaultAction).disabled(model.isBusy || model.loading || !model.hasSource)
                Text("原片自动保存在「桌面 / LightSnap」").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 26).padding(.bottom, 22).padding(.top, 12)
        }
        .background(RecordingPalette.base).preferredColorScheme(.dark)
        .onChange(of: model.options.sourceKind) { _, _ in model.refreshThumbnail() }
        .onChange(of: model.displayID) { _, _ in model.refreshThumbnail() }
        .onChange(of: model.windowID) { _, _ in model.refreshThumbnail() }
        .onChange(of: model.options.hideDesktopIcons) { _, _ in model.refreshThumbnail() }
    }

    @ViewBuilder private var sourcePicker: some View {
        switch model.options.sourceKind {
        case 0:
            Picker("显示器", selection: $model.displayID) { ForEach(model.displays, id: \.displayID) { Text(model.displayName($0)).tag($0.displayID) } }
        case 1:
            Picker("窗口", selection: $model.windowID) { ForEach(model.windows, id: \.windowID) { Text(model.windowName($0)).tag($0.windowID) } }
        case 2:
            Text("点击开始后框选录制区域，也可单击定位窗口。").font(.system(size: 12)).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var sourcePreview: some View {
        ZStack {
            LinearGradient(colors: [.init(white: 0.17), .init(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = model.sourceImage, model.options.sourceKind < 2 {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(10)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "viewfinder").font(.system(size: 32, weight: .light)).foregroundStyle(RecordingPalette.accent)
                    Text(model.options.sourceKind == 2 ? "自由框选，专注想展示的内容" : "选择要录制的画面")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if model.loading { ProgressView().controlSize(.small) }
        }
        .frame(height: 146).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07)))
    }
}

struct RecordingHUDView: View {
    @ObservedObject var model: RecordingController

    var body: some View {
        HStack(spacing: 13) {
            if model.phase == .countdown {
                Text("\(model.countdown)").font(.system(size: 32, weight: .semibold, design: .rounded)).foregroundStyle(RecordingPalette.accent).frame(width: 40)
                Text("即将开始录制").font(.system(size: 14, weight: .medium))
                Spacer()
                Button("取消", action: model.cancelCountdown).buttonStyle(.borderless)
            } else if model.phase == .preparing || model.phase == .finishing {
                ProgressView().controlSize(.small)
                Text(model.phase == .finishing ? "正在保存录屏…" : "正在启动录制…").font(.system(size: 13))
                Spacer()
                if model.phase == .preparing { Button("取消", action: model.cancelCountdown).buttonStyle(.borderless) }
            } else {
                if let session = model.cameraSession { RecordingCameraView(session: session).frame(width: 44, height: 44).clipShape(Circle()) }
                Circle().fill(model.phase == .paused ? Color.orange : Color.red).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(RecordingController.timeLabel(model.seconds)).font(.system(size: 20, weight: .medium, design: .monospaced))
                    Text(model.phase == .paused ? "已暂停" : "正在录制").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Button(action: model.togglePause) { Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill").frame(width: 28, height: 30) }
                    .buttonStyle(.borderless).help(model.phase == .paused ? "继续录制" : "暂停录制")
                    .accessibilityLabel(model.phase == .paused ? "继续录制" : "暂停录制")
                Button { model.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 15)).foregroundStyle(.white).frame(width: 40, height: 40).background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).help("结束录屏").accessibilityLabel("结束录屏")
            }
        }
        .padding(.horizontal, 17).frame(height: 76)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
        .preferredColorScheme(.dark)
    }
}

struct RecordingPreviewView: View {
    @ObservedObject var model: RecordingController

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        RecordingPlayerView(player: model.player).aspectRatio(model.videoAspectRatio, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10)).padding(24)
                        if model.rebuilding {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("更新预览…").font(.system(size: 11)) }
                                .padding(10).background(.regularMaterial, in: Capsule()).padding(32)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    playback
                    if let error = model.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 24).padding(.bottom, 16)
                    } else if !model.message.isEmpty {
                        HStack {
                            Text(model.message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            if model.lastExport != nil {
                                Button("显示文件", action: model.revealExport).buttonStyle(.link)
                                Button("复制", action: model.copyExport).buttonStyle(.link)
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 16)
                    }
                }
                Divider().opacity(0.4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        canvasControls
                        if model.document?.manifest.pointers.isEmpty == false { motionControls }
                        if model.document?.manifest.hasCamera == true { cameraControls }
                        audioControls
                        exportControls
                        Button("保存为默认样式", action: model.savePreset).frame(maxWidth: .infinity).controlSize(.large)
                    }.padding(22)
                }.frame(width: 292).background(RecordingPalette.panel).disabled(model.phase == .exporting)
            }
        }
        .background(RecordingPalette.base).preferredColorScheme(.dark).tint(RecordingPalette.accent)
        .onChange(of: model.style) { _, _ in model.refreshPreview() }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "play.rectangle.fill").font(.system(size: 22)).foregroundStyle(RecordingPalette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.document?.manifest.title ?? "录屏预览").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("\(RecordingController.timeLabel(model.seconds)) · 原片已自动保存").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .exporting {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在导出 \(Int(model.exportProgress * 100))%").font(.system(size: 11)).monospacedDigit()
                    ProgressView(value: model.exportProgress).frame(width: 140)
                }
                Button("取消导出", action: model.cancelExport)
            } else {
                Button("再录一段", action: model.presentSetup)
                Menu {
                    Button("打开原片文件夹", action: model.revealOriginal)
                    Button("导出 GIF（30 秒以内）") { model.export(gif: true) }.disabled(model.seconds > 30)
                    if model.lastExport != nil {
                        Divider()
                        Button("复制导出文件", action: model.copyExport)
                        Button("在访达中显示", action: model.revealExport)
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("更多录屏操作")
                Button { model.export(gif: false) } label: { Label("导出 MP4", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.rebuilding)
            }
        }.padding(.leading, 24).padding(.trailing, 22).padding(.top, 36).padding(.bottom, 18)
    }

    private var playback: some View {
        HStack(spacing: 13) {
            Button(action: model.togglePlayback) { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 28, height: 28) }
                .buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).accessibilityLabel(model.isPlaying ? "暂停播放" : "播放录屏")
            Text(RecordingController.timeLabel(model.position)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.position }, set: { model.seek(to: $0) }), in: 0...max(0.01, model.seconds)).accessibilityLabel("播放进度")
            Text(RecordingController.timeLabel(model.seconds)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(.horizontal, 28).padding(.bottom, 22).disabled(model.rebuilding || model.phase == .exporting)
    }

    private var canvasControls: some View {
        RecordingSection("画布", symbol: "rectangle.on.rectangle") {
            Picker("比例", selection: $model.style.aspect) { ForEach(RecordingStyle.Aspect.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Text("背景").font(.system(size: 12)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(RecordingStyle.Background.allCases.filter { $0 != .custom }, id: \.self) { background in
                    Button { model.style.background = background } label: {
                        RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: RecordingPalette.colors(background), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 38)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.style.background == background ? RecordingPalette.accent : .white.opacity(0.1), lineWidth: model.style.background == background ? 2 : 1))
                            .overlay { if model.style.background == background { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(background == .white ? .black : .white) } }
                    }.buttonStyle(.plain).help(background.rawValue).accessibilityLabel("\(background.rawValue)背景")
                }
            }
            Menu {
                Button("选择背景图片…", action: model.chooseBackground)
                Button("使用当前桌面壁纸", action: model.useDesktopWallpaper)
            } label: { Text("背景图片…").font(.system(size: 11)) }.menuStyle(.borderlessButton).frame(maxWidth: .infinity, alignment: .leading)
            RecordingSlider("留白", value: $model.style.padding, range: 0...0.18, label: "\(Int(model.style.padding * 100))%")
            RecordingSlider("圆角", value: $model.style.cornerRadius, range: 0...48, label: "\(Int(model.style.cornerRadius))")
            RecordingSlider("阴影", value: $model.style.shadow, range: 0...0.8, label: "\(Int(model.style.shadow * 100))%")
        }
    }

    private var motionControls: some View {
        RecordingSection("镜头与鼠标", symbol: "cursorarrow.motionlines") {
            Toggle("自动缩放", isOn: $model.style.autoZoom)
            if model.style.autoZoom { RecordingSlider("放大倍数", value: $model.style.zoomAmount, range: 1.2...2.5, label: String(format: "%.1f×", model.style.zoomAmount)) }
            Toggle("平滑鼠标移动", isOn: $model.style.smoothCursor)
            RecordingSlider("鼠标大小", value: $model.style.cursorSize, range: 0...3, label: String(format: "%.1f×", model.style.cursorSize))
            Toggle("闲置时隐藏鼠标", isOn: $model.style.hideIdleCursor)
            Toggle("点击动效", isOn: $model.style.showClicks)
            if model.document?.manifest.shortcuts.isEmpty == false { Toggle("显示快捷键", isOn: $model.style.showShortcuts) }
        }
    }

    private var cameraControls: some View {
        RecordingSection("摄像头", symbol: "video") {
            Toggle("显示摄像头", isOn: $model.style.cameraVisible)
            if model.style.cameraVisible {
                Picker("位置", selection: $model.style.cameraPosition) { ForEach(RecordingStyle.CameraPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                RecordingSlider("大小", value: $model.style.cameraSize, range: 0.1...0.32, label: "\(Int(model.style.cameraSize * 100))%")
                Toggle("圆形画面", isOn: $model.style.roundCamera)
                Toggle("镜像", isOn: $model.style.mirrorCamera)
            }
        }
    }

    @ViewBuilder private var audioControls: some View {
        if model.document?.manifest.hasSystemAudio == true || model.document?.manifest.hasMicrophone == true {
            RecordingSection("声音", symbol: "waveform") {
                if model.document?.manifest.hasSystemAudio == true { RecordingSlider("系统声音", value: $model.style.systemVolume, range: 0...1, label: "\(Int(model.style.systemVolume * 100))%") }
                if model.document?.manifest.hasMicrophone == true { RecordingSlider("麦克风", value: $model.style.microphoneVolume, range: 0...1, label: "\(Int(model.style.microphoneVolume * 100))%") }
            }
        }
    }

    private var exportControls: some View {
        RecordingSection("导出", symbol: "square.and.arrow.up") {
            Picker("分辨率", selection: $model.style.longEdge) {
                Text("720p").tag(1280); Text("1080p").tag(1920); Text("1440p").tag(2560); Text("4K").tag(3840)
            }
            Picker("帧率", selection: $model.style.frameRate) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
            Text("GIF 使用 960 px / 15 fps，不含声音。").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct RecordingSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) { self.title = title; self.symbol = symbol; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
            content.font(.system(size: 12))
        }.toggleStyle(.checkbox)
    }
}

private struct RecordingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) { self.title = title; _value = value; self.range = range; self.label = label }

    var body: some View {
        VStack(spacing: 5) {
            HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(label).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: $value, in: range).controlSize(.small).accessibilityLabel(title)
        }.font(.system(size: 11))
    }
}

private struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

private struct RecordingCameraView: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view.layer as? AVCaptureVideoPreviewLayer)?.session = session }
}
