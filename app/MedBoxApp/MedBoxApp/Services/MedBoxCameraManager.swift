import Combine
import Foundation
import NetworkExtension
import UIKit

enum CameraConnectionState: Equatable {
    case idle
    case requestingWiFi
    case connectingStream
    case streaming
    case failed(String)

    func label(language: AppLanguage) -> String {
        switch self {
        case .idle:
            language.text("Not connected", "未连接")
        case .requestingWiFi:
            language.text("Waiting for Wi-Fi approval", "正在等待 Wi-Fi 授权")
        case .connectingStream:
            language.text("Connecting to camera", "正在连接相机")
        case .streaming:
            language.text("Camera connected", "相机已连接")
        case let .failed(message):
            message
        }
    }

    var isStreaming: Bool { self == .streaming }

    var isConnecting: Bool {
        switch self {
        case .requestingWiFi, .connectingStream: true
        case .idle, .streaming, .failed: false
        }
    }
}

enum MedBoxCameraError: LocalizedError {
    case invalidStreamResponse
    case streamEnded
    case firstFrameTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidStreamResponse:
            "The MedBox camera returned an invalid stream response."
        case .streamEnded:
            "The MedBox camera stream ended unexpectedly."
        case .firstFrameTimedOut:
            "The camera connected, but no image arrived. Check that no browser or Mac is using the stream."
        }
    }
}

@MainActor
final class MedBoxCameraManager: ObservableObject {
    static let ssid = "MedBox-Camera-Test"
    static let streamURL = URL(string: "http://192.168.4.1/stream")!

    @Published private(set) var state: CameraConnectionState = .idle
    @Published private(set) var latestFrame: UIImage?
    @Published private(set) var inferenceState: CameraInferenceState = .idle

    var onVisionResult: ((VisionResult) -> Void)?

    private var streamClient: MJPEGStreamClient?
    private var streamError: Error?
    private let inferenceEngine = CameraActionInferenceEngine()
    private var scheduledDisconnect: Task<Void, Never>?

    init() {
        inferenceEngine.onStateChange = { [weak self] state in
            self?.inferenceState = state
        }
        inferenceEngine.onPrediction = { [weak self] prediction in
            self?.onVisionResult?(VisionResult(
                eventID: prediction.eventID,
                action: prediction.action,
                confidence: prediction.confidence
            ))
        }
    }

    func connectAndStart() async throws {
        if state.isStreaming { return }

        stopStream()
        scheduledDisconnect?.cancel()
        scheduledDisconnect = nil
        latestFrame = nil
        streamError = nil
        state = .requestingWiFi

        let configuration = NEHotspotConfiguration(ssid: Self.ssid)
        configuration.joinOnce = true

        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
        } catch {
            guard isAlreadyAssociated(error) else {
                state = .failed(error.localizedDescription)
                throw error
            }
        }

        state = .connectingStream
        let client = MJPEGStreamClient(url: Self.streamURL)
        client.onFrame = { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self else { return }
                latestFrame = image
                state = .streaming
                inferenceEngine.consume(image)
            }
        }
        client.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                streamError = error
                latestFrame = nil
                state = .failed(error.localizedDescription)
            }
        }
        streamClient = client
        client.start()

        do {
            try await waitForFirstFrame()
        } catch {
            stopStream()
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: Self.ssid)
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() {
        scheduledDisconnect?.cancel()
        scheduledDisconnect = nil
        inferenceEngine.endEvent()
        stopStream()
        latestFrame = nil
        streamError = nil
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: Self.ssid)
        state = .idle
    }

    func beginActionRecognition(eventID: Int) {
        scheduledDisconnect?.cancel()
        scheduledDisconnect = nil
        inferenceEngine.beginEvent(eventID: eventID)
    }

    func finishActionRecognition(after delay: Duration = .seconds(3)) {
        scheduledDisconnect?.cancel()
        scheduledDisconnect = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.disconnect()
        }
    }

    private func waitForFirstFrame() async throws {
        for _ in 0..<150 {
            try Task.checkCancellation()
            if state == .idle { throw CancellationError() }
            if latestFrame != nil { return }
            if let streamError { throw streamError }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MedBoxCameraError.firstFrameTimedOut
    }

    private func stopStream() {
        streamClient?.stop()
        streamClient = nil
    }

    private func isAlreadyAssociated(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NEHotspotConfigurationErrorDomain
            && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
    }
}

private final class MJPEGStreamClient: NSObject, URLSessionDataDelegate {
    var onFrame: ((UIImage) -> Void)?
    var onError: ((Error) -> Void)?

    private let url: URL
    private var parser = MJPEGFrameParser()
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var wasStopped = false

    init(url: URL) {
        self.url = url
        super.init()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60 * 60

        let delegateQueue = OperationQueue()
        delegateQueue.name = "MedBox.MJPEGStream"
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    func start() {
        wasStopped = false
        parser.reset()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("multipart/x-mixed-replace", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request)
        task?.resume()
    }

    func stop() {
        wasStopped = true
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
            onError?(MedBoxCameraError.invalidStreamResponse)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for frameData in parser.append(data) {
            if let image = UIImage(data: frameData) {
                onFrame?(image)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !wasStopped else { return }
        onError?(error ?? MedBoxCameraError.streamEnded)
    }
}
