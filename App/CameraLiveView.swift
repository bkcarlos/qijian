import SwiftUI
import HomeKit

@MainActor
final class CameraLiveSession: NSObject, ObservableObject, HMCameraStreamControlDelegate {
    @Published private(set) var stream: HMCameraStream?
    @Published private(set) var connecting = false
    @Published private(set) var message = "点击查看实时画面"
    private var control: HMCameraStreamControl?
    private var timeout: Task<Void, Never>?

    func start(_ candidate: HMCameraStreamControl) {
        guard control == nil else { return }
        guard candidate.streamState == .notStreaming else {
            message = "摄像头正在连接或被占用，请稍后重试。"
            return
        }
        control = candidate
        connecting = true
        message = "正在连接摄像头…"
        candidate.delegate = self
        candidate.startStream()
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            guard let self, self.connecting else { return }
            self.stop()
            self.message = "连接超时，请检查摄像头及视频桥接服务后重试。"
        }
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        let previous = control
        control = nil
        previous?.delegate = nil
        stream = nil
        connecting = false
        previous?.stopStream()
        message = "画面已停止"
    }

    nonisolated func cameraStreamControlDidStartStream(_ cameraStreamControl: HMCameraStreamControl) {
        Task { @MainActor [weak self] in
            guard let self, self.control === cameraStreamControl else { return }
            guard let stream = cameraStreamControl.cameraStream else {
                self.stop()
                self.message = "摄像头未返回视频流，请重试。"
                return
            }
            // Viewing never enables the phone's microphone or two-way talk.
            do { try await stream.updateAudioStreamSetting(.muted) }
            catch {
                guard self.control === cameraStreamControl else { return }
                self.stop()
                self.message = "无法设置静音：\(error.localizedDescription)"
                return
            }
            guard self.control === cameraStreamControl, cameraStreamControl.streamState == .streaming else { return }
            self.timeout?.cancel()
            self.timeout = nil
            self.stream = stream
            self.connecting = false
            self.message = "实时画面"
        }
    }

    nonisolated func cameraStreamControl(_ cameraStreamControl: HMCameraStreamControl, didStopStreamWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.control === cameraStreamControl else { return }
            self.timeout?.cancel()
            self.timeout = nil
            self.control = nil
            cameraStreamControl.delegate = nil
            self.stream = nil
            self.connecting = false
            self.message = error.map { "无法播放：\($0.localizedDescription)" } ?? "画面已停止"
        }
    }
}

private struct HomeKitCameraSurface: UIViewRepresentable {
    let stream: HMCameraStream?
    func makeUIView(context: Context) -> HMCameraView {
        let view = HMCameraView()
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ uiView: HMCameraView, context: Context) { uiView.cameraSource = stream }
    static func dismantleUIView(_ uiView: HMCameraView, coordinator: ()) { uiView.cameraSource = nil }
}

struct CameraLiveView: View {
    let control: HMCameraStreamControl
    @StateObject private var session = CameraLiveSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("实时画面", systemImage: "video.fill").font(.headline)
                Spacer()
                if session.connecting || session.stream != nil {
                    Button("停止") { session.stop() }
                } else {
                    Button("查看画面") { session.start(control) }
                        .disabled(scenePhase != .active)
                }
            }
            ZStack {
                Color.black
                if session.stream != nil {
                    HomeKitCameraSurface(stream: session.stream)
                } else {
                    VStack(spacing: 12) {
                        if session.connecting { ProgressView().tint(.white) }
                        else { Image(systemName: "video").font(.title) }
                        Text(session.message).multilineTextAlignment(.center)
                    }.foregroundStyle(.white).padding()
                }
            }.aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("离开页面或切换到后台会停止播放。画面默认静音。").font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { phase in if phase != .active { session.stop() } }
    }
}
