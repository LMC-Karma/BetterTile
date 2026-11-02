import BetterTileCore
import CoreGraphics
import CoreML
import Vision

enum SnapshotRecognitionError: Error, CustomStringConvertible {
    case timedOut
    case cpuUnavailable

    var description: String {
        switch self {
        case .timedOut:
            "Text recognition did not finish before its deadline. The test stopped waiting; a stuck Vision call is "
                + "left on its own dispatch thread and holds no test thread, main-actor work or UI resource."
        case .cpuUnavailable: "Vision offers no CPU device for a text-recognition stage."
        }
    }
}

func snapshotTextRequest(languageCorrection: Bool = true) throws -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = languageCorrection
    // Select CPU for the stages Vision exposes. The native engine can still
    // compile hardware models internally, so this does not replace the deadline.
    for (stage, devices) in try request.supportedComputeStageDevices {
        guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
            throw SnapshotRecognitionError.cpuUnavailable
        }
        request.setComputeDevice(cpu, for: stage)
    }
    return request
}

private actor RecognitionResult<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var deadline: Task<Void, Never>?
    private var finished = false

    func start(_ continuation: CheckedContinuation<Value, any Error>, clock: BetterTileClock,
               timeout: Duration, operation: @escaping @Sendable () throws -> Value) {
        guard !finished else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let limit = clock.now.advanced(by: timeout)
        // Vision's call blocks its thread until recognition ends, and on a stuck system it never ends. On a
        // cooperative-pool thread it would hold a thread every other test, deadline and test-runner task needs: a few
        // stuck calls on a 3-core runner freeze the whole process. A GCD dispatch thread keeps the call outside the pool, and
        // the deadline resumes the caller without ever waiting for it.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try operation() }
            Task { await self.finish(result) }
        }
        deadline = Task.detached {
            do {
                try await clock.sleep(until: limit)
                await self.finish(.failure(SnapshotRecognitionError.timedOut))
            } catch {}
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor func performSnapshotRecognition<Value: Sendable>(
    clock: BetterTileClock = .live, timeout: Duration = .seconds(15),
    operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    let result = RecognitionResult<Value>()
    // A structured task group would still join a native call that ignores cancellation.
    // Keep its work off the main actor and bound the caller independently.
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            Task { await result.start(continuation, clock: clock, timeout: timeout, operation: operation) }
        }
    } onCancel: {
        Task { await result.finish(.failure(CancellationError())) }
    }
}

@MainActor func snapshotRecognizedLines(in image: CGImage) async throws -> [String] {
    try await performSnapshotRecognition {
        let request = try snapshotTextRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
