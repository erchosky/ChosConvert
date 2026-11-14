import Foundation
import Observation

/// One queued conversion, observable by the UI.
@MainActor @Observable
public final class JobItem: Identifiable {
    public let id: UUID
    public let spec: JobSpec
    public let createdAt = Date()
    public private(set) var status: JobStatus = .waiting
    /// 0…1, or nil when the engine can't report exact progress (shown as indeterminate).
    public private(set) var fraction: Double?
    public private(set) var speed: Double?
    public private(set) var detail: ProgressDetail?
    public private(set) var outcome: JobOutcome?
    public private(set) var error: ChosError?
    public private(set) var startedAt: Date?
    public private(set) var completedAt: Date?
    public private(set) var notices: [String] = []

    @ObservationIgnored var task: Task<Void, Never>?

    init(spec: JobSpec) {
        id = spec.id
        self.spec = spec
    }

    public var fileName: String { spec.input.fileName }

    public var elapsed: TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Remaining time, only when progress is real and has advanced enough to extrapolate.
    public var eta: TimeInterval? {
        guard status == .processing, let f = fraction, f > 0.03, f < 1, let e = elapsed, e > 2 else { return nil }
        return e / f - e
    }

    func apply(_ update: JobUpdate) {
        switch update {
        case .status(let s):
            if s == .preparing, startedAt == nil { startedAt = Date() }
            if s != status { status = s }
            if s == .finalizing { fraction = nil }
        case .progress(let f, let sp, let d):
            fraction = f
            speed = sp
            detail = d
        case .log(let code, _):
            if code == "hardware_fallback" { notices.append(code) }
        }
    }

    func finish(_ result: Result<JobOutcome, ChosError>) {
        completedAt = Date()
        switch result {
        case .success(let o):
            outcome = o
            fraction = 1
            status = .completed
        case .failure(let e) where e.isCancellation:
            status = .cancelled
            fraction = nil
        case .failure(let e):
            error = e
            status = .failed
            fraction = nil
        }
    }

    func reset() {
        status = .waiting
        fraction = nil; speed = nil; detail = nil
        outcome = nil; error = nil; startedAt = nil; completedAt = nil
        notices = []
    }
}

/// Workload classes with separate concurrency limits (see core `jobs::recommended_concurrency`).
public enum WorkloadKind: String, Codable, Sendable {
    case image, audio, remux
    case videoSoftware = "video_software"
    case videoHardware = "video_hardware"
}

/// The conversion queue. Applies backpressure: jobs start only when a slot for their workload
/// kind is free, so a 5,000-file batch never spawns more than a handful of engines at once.
@MainActor @Observable
public final class JobQueue {
    public private(set) var items: [JobItem] = []
    /// User override for simultaneous jobs; nil = automatic.
    public var maxConcurrentOverride: Int? { didSet { pump() } }
    /// Called once per job when it reaches a terminal state.
    @ObservationIgnored public var onFinished: (@MainActor (JobItem) -> Void)?

    @ObservationIgnored private let runner: JobRunner
    @ObservationIgnored private let capabilities: @Sendable () async -> Capabilities
    @ObservationIgnored private var limits: [WorkloadKind: Int] = [:]

    public init(runner: JobRunner = JobRunner(),
                capabilities: @escaping @Sendable () async -> Capabilities = { await CapabilityService.shared.current() }) {
        self.runner = runner
        self.capabilities = capabilities
    }

    public var activeCount: Int { items.filter { $0.status.isActive }.count }
    public var waitingCount: Int { items.filter { $0.status == .waiting }.count }
    public var hasFinished: Bool { items.contains { $0.status.isTerminal } }

    @discardableResult
    public func enqueue(_ specs: [JobSpec]) -> [JobItem] {
        let new = specs.map(JobItem.init(spec:))
        items.append(contentsOf: new)
        pump()
        return new
    }

    public func cancel(_ item: JobItem) {
        if item.status == .waiting {
            item.finish(.failure(.cancelled))
            onFinished?(item)
        } else {
            item.task?.cancel()
        }
    }

    public func cancelAll() {
        for item in items where !item.status.isTerminal { cancel(item) }
    }

    public func retry(_ item: JobItem) {
        guard item.status == .failed || item.status == .cancelled else { return }
        item.reset()
        pump()
    }

    /// Re-runs a failed job forcing the software encoder.
    public func retryWithSoftwareEncoding(_ item: JobItem) {
        guard item.status.isTerminal else { return }
        var spec = item.spec
        spec.id = UUID()
        spec.options.encoder = .software
        items.removeAll { $0.id == item.id }
        enqueue([spec])
    }

    public func remove(_ item: JobItem) {
        guard item.status.isTerminal else { return }
        items.removeAll { $0.id == item.id }
    }

    public func clearFinished() {
        items.removeAll { $0.status.isTerminal }
    }

    public func retryFailed() {
        for item in items where item.status == .failed { item.reset() }
        pump()
    }

    // MARK: Scheduling

    nonisolated static func kind(for spec: JobSpec) -> WorkloadKind {
        switch spec.input.family {
        case .image: return .image
        case .audio: return .audio
        case .video:
            switch spec.intent {
            case .removeMetadata, .extractAudio: return .remux
            case .convert(let f) where f.family == .video: return .remux
            case .targetSize: return .videoSoftware
            default: return spec.options.encoder == .software ? .videoSoftware : .videoHardware
            }
        default: return .image
        }
    }

    private struct ConcurrencyInput: Encodable {
        var kind: WorkloadKind; var cpuCount: UInt32; var memoryBytes: UInt64; var queued: UInt32
    }

    private func limit(for kind: WorkloadKind) -> Int {
        if let o = maxConcurrentOverride, o > 0 { return o }
        if let cached = limits[kind] { return cached }
        let p = ProcessInfo.processInfo
        let n: Int = (try? CoreBridge.call("jobs.recommended_concurrency",
                                           ConcurrencyInput(kind: kind, cpuCount: UInt32(p.activeProcessorCount),
                                                            memoryBytes: p.physicalMemory, queued: 10_000))) ?? 1
        limits[kind] = max(1, n)
        return limits[kind] ?? 1
    }

    private func pump() {
        var running: [WorkloadKind: Int] = [:]
        for item in items where item.status.isActive || item.task != nil && !item.status.isTerminal && item.status != .waiting {
            running[Self.kind(for: item.spec), default: 0] += 1
        }
        for item in items where item.status == .waiting && item.task == nil {
            let kind = Self.kind(for: item.spec)
            guard running[kind, default: 0] < limit(for: kind) else { continue }
            running[kind, default: 0] += 1
            start(item)
        }
    }

    private func start(_ item: JobItem) {
        item.apply(.status(.preparing))
        let runner = self.runner
        let capabilities = self.capabilities
        let spec = item.spec
        item.task = Task { [weak self] in
            let (stream, continuation) = AsyncStream<JobUpdate>.makeStream(bufferingPolicy: .bufferingNewest(64))
            let work = Task.detached(priority: .userInitiated) { () -> Result<JobOutcome, ChosError> in
                defer { continuation.finish() }
                let caps = await capabilities()
                do throws(ChosError) {
                    return .success(try await runner.run(spec, capabilities: caps) { continuation.yield($0) })
                } catch {
                    return .failure(error)
                }
            }
            await withTaskCancellationHandler {
                for await update in stream { item.apply(update) }
            } onCancel: {
                work.cancel()
            }
            let result = await work.value
            item.finish(result)
            item.task = nil
            if case .failure(let e) = result, !e.isCancellation {
                Log.jobs.error("job \(spec.id, privacy: .public) failed: \(e.code, privacy: .public)")
            }
            self?.onFinished?(item)
            self?.pump()
        }
    }
}
