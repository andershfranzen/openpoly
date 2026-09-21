import AppKit
import AVFoundation
import OpenPolyCore
import SwiftUI

struct CameraPreviewView: View {
    @State private var model: CameraPreviewModel
    @State private var mirrored = true

    init(store: ControlStore) {
        _model = State(initialValue: CameraPreviewModel(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CameraVideoSurface(session: model.capture.session, mirrored: mirrored)
                if !model.running {
                    VStack(spacing: 14) {
                        Image(systemName: model.permissionDenied ? "lock.shield" : "video")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(Studio.muted)
                        Text(model.message).font(.system(size: 12)).foregroundStyle(Studio.muted)
                            .multilineTextAlignment(.center).frame(maxWidth: 270)
                        if model.permissionDenied {
                            Button("Camera permissions") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
                            }.buttonStyle(StudioButtonStyle())
                        }
                        if model.message != "Starting camera…" {
                            Button("Retry") { Task { await model.start() } }.buttonStyle(StudioButtonStyle())
                        }
                    }.padding(20)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(.black)
            HStack {
                Circle().fill(model.running ? Studio.accent : Studio.muted).frame(width: 5, height: 5)
                Text(model.running ? "Live · Studio P21" : "Camera preview").font(.system(size: 11)).foregroundStyle(Studio.muted)
                Spacer()
                Toggle("Mirror", isOn: $mirrored).toggleStyle(.checkbox).font(.system(size: 11)).controlSize(.small)
            }.padding(16).background(Studio.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Studio.line))
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: model.capture.session)) { notification in
            model.running = false
            model.message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera unavailable. Retry to reconnect."
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification, object: model.capture.session)) { _ in
            model.running = false
            model.message = "Camera preview interrupted. Retry when the camera is available."
        }
    }
}

private struct CameraVideoSurface: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.configure(session: session, mirrored: mirrored)
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.mirrored = mirrored
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var mirrored = true { didSet { applyMirroring() } }
        private var sessionStartObserver: NSObjectProtocol?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspect
            layer = previewLayer
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func configure(session: AVCaptureSession, mirrored: Bool) {
            self.mirrored = mirrored
            previewLayer.session = session
            sessionStartObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.didStartRunningNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.applyMirroring()
            }
            applyMirroring()
        }

        private func applyMirroring() {
            guard let connection = previewLayer.connection,
                  connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
            applyMirroring()
        }

        deinit {
            if let sessionStartObserver {
                NotificationCenter.default.removeObserver(sessionStartObserver)
            }
        }
    }
}
