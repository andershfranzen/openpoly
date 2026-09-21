import AVFoundation
import Foundation
import Observation
import OpenPolyCore

/// Capture configuration and start/stop are serialized off the UI thread.
final class CameraCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.openpoly.camera", qos: .userInitiated)
    /// Accessed only on `queue`. It records whether this capture generation ever
    /// reached a running session, even if AVFoundation later interrupts it.
    private var started = false

    func start(completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        queue.async { [self] in
            do {
                if session.inputs.isEmpty {
                    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
                        .filter { $0.localizedName.localizedCaseInsensitiveContains("P21") }
                    guard devices.count == 1, let camera = devices.first else {
                        throw PreviewError.message(devices.isEmpty ? "Connect the P21 camera to see its preview." : "More than one P21 camera is connected.")
                    }
                    let input = try AVCaptureDeviceInput(device: camera)
                    session.beginConfiguration()
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        throw PreviewError.message("The P21 camera is unavailable. Close other camera apps and retry.")
                    }
                    session.addInput(input)
                    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                    session.commitConfiguration()
                }
                session.startRunning()
                guard session.isRunning else { throw PreviewError.message("The camera could not start. Close other camera apps and retry.") }
                started = true
                completion(.success("Poly Studio P21"))
            } catch { completion(.failure(error)) }
        }
    }

    func stop(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        queue.async { [self] in
            let didStart = started
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
            started = false
            completion(didStart)
        }
    }

    enum PreviewError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}

@MainActor @Observable
final class CameraPreviewModel {
    let capture = CameraCapture()
    var running = false
    var message = "Starting camera…"
    var permissionDenied = false
    private let store: ControlStore
    private var requestID: UUID?
    private var previewToken: ControlStore.CameraPreviewToken?

    init(store: ControlStore) {
        self.store = store
    }

    func start() async {
        if previewToken != nil { stop() }
        let id = UUID()
        requestID = id
        running = false
        message = "Starting camera…"
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard requestID == id, !Task.isCancelled else { return }
        permissionDenied = !authorized
        guard authorized else {
            message = "Allow camera access in System Settings to see the preview."
            return
        }
        let token = store.prepareCameraPreview()
        previewToken = token
        capture.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    guard self.requestID == id, self.previewToken == token else { return }
                    self.running = true
                    self.message = ""
                case .failure(let error):
                    self.store.cancelCameraPreview(token)
                    guard self.requestID == id, self.previewToken == token else { return }
                    self.previewToken = nil
                    self.running = false
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func stop() {
        requestID = nil
        running = false
        let token = previewToken
        previewToken = nil
        let store = store
        capture.stop { didStart in
            guard let token else { return }
            Task { @MainActor in
                await store.cameraPreviewDidStop(token, captureStarted: didStart)
            }
        }
    }

    isolated deinit {
        let token = previewToken
        let store = store
        capture.stop { didStart in
            guard let token else { return }
            Task { @MainActor in
                await store.cameraPreviewDidStop(token, captureStarted: didStart)
            }
        }
    }
}
