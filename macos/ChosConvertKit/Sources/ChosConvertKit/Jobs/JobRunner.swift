import Foundation

/// Everything needed to run one conversion.
public struct JobSpec: Sendable, Hashable {
    public var id: UUID
    public var input: MediaInfo
    public var intent: Intent
    public var options: AdvancedOptions
    public var policy: OutputPolicy

    public init(id: UUID = UUID(), input: MediaInfo, intent: Intent, options: AdvancedOptions = AdvancedOptions(),
                policy: OutputPolicy = OutputPolicy()) {
        self.id = id; self.input = input; self.intent = intent; self.options = options; self.policy = policy
    }
}

public struct JobOutcome: Sendable, Hashable {
    public var outputURL: URL?
    public var skippedBecauseExists: URL?
    public var inputBytes: UInt64
    public var outputBytes: UInt64
    public var outputFormat: FileFormat
    public var engine: EngineKind
    public var encoder: String?
    public var hardware: Bool
    public var fallbackReason: String?
    public var attempts: UInt32
    public var reencoded: Bool
    public var outputInfo: MediaInfo?

    /// Negative when the output is smaller.
    public var sizeChange: Double {
        guard inputBytes > 0 else { return 0 }
        return (Double(outputBytes) - Double(inputBytes)) / Double(inputBytes)
    }
}

public enum JobUpdate: Sendable, Equatable {
    case status(JobStatus)
    /// `nil` fraction means indeterminate progress.
    case progress(fraction: Double?, speed: Double?, detail: ProgressDetail?)
    case log(code: String, message: String)
}

public enum JobStatus: String, Sendable, Codable, Hashable {
    case waiting, inspecting, preparing, processing, finalizing, completed, cancelled, failed

    public var isTerminal: Bool { [.completed, .cancelled, .failed].contains(self) }
    public var isActive: Bool { [.inspecting, .preparing, .processing, .finalizing].contains(self) }
}

public struct ProgressDetail: Sendable, Equatable, Hashable {
    public var pass: UInt32
    public var passes: UInt32
    public var attempt: UInt32
}

/// Executes a JobSpec end-to-end: plan → engine → verify → finalize → cleanup.
public struct JobRunner: Sendable {
    public var temp: TempSpace
    public var access: OutputAccess

    public init(temp: TempSpace = .shared, access: OutputAccess = .shared) {
        self.temp = temp
        self.access = access
    }

    struct ExecuteRequest: Encodable { var planRequest: PlanRequest; var jobDir: String }
    struct FinalizeRequest: Encodable {
        var source: String; var `extension`: String; var policy: OutputPolicy; var tempFile: String
    }

    public static func plan(_ spec: JobSpec, capabilities: Capabilities) throws(ChosError) -> ConversionPlan {
        try CoreBridge.call("plan.create", PlanRequest(input: spec.input, intent: spec.intent,
                                                       options: spec.options, capabilities: capabilities))
    }

    public func run(_ spec: JobSpec, capabilities: Capabilities,
                    onUpdate: @escaping @Sendable (JobUpdate) -> Void) async throws(ChosError) -> JobOutcome {
        onUpdate(.status(.preparing))
        let plan = try Self.plan(spec, capabilities: capabilities)
        let jobDir = try temp.createJobDirectory(id: spec.id)
        defer { temp.removeJobDirectory(jobDir) }
        let input = spec.input.url
        Log.jobs.info("job \(spec.id, privacy: .public) engine=\(plan.engine.rawValue, privacy: .public) reencode=\(plan.reencode)")

        onUpdate(.status(.processing))
        var tempOutput: URL
        var encoder: String?
        var hardware = false
        var fallbackReason: String?
        var attempts: UInt32 = 1
        var outputInfo: MediaInfo?

        switch plan.engine {
        case .nativeImage:
            guard let job = plan.image else { throw .internalError("image plan without job") }
            tempOutput = jobDir.appendingPathComponent("out-\(UUID().uuidString).\(plan.outputExtension)")
            onUpdate(.progress(fraction: nil, speed: nil, detail: nil))
            let out = tempOutput
            try await offMain { () throws(ChosError) in
                try ImageIOEngine.run(job, input: input, output: out)
            }
            encoder = job.encoder == .coreWebp ? "libwebp" : "ImageIO"
        case .nativeAv:
            guard let job = plan.nativeAv else { throw .internalError("native plan without job") }
            tempOutput = jobDir.appendingPathComponent("out-\(UUID().uuidString).\(plan.outputExtension)")
            try await AVExportEngine.run(job, input: input, output: tempOutput) { f in
                onUpdate(.progress(fraction: f, speed: nil, detail: nil))
            }
            encoder = job.preset
        case .ffmpeg:
            let result = try await CoreBridge.runTask(
                "media.execute",
                ExecuteRequest(planRequest: PlanRequest(input: spec.input, intent: spec.intent, options: spec.options,
                                                        capabilities: capabilities),
                               jobDir: jobDir.path),
                as: ExecuteResult.self
            ) { event in
                switch event {
                case .progress(let fraction, let speed, let pass, let passes, let attempt):
                    onUpdate(.progress(fraction: fraction, speed: speed,
                                       detail: ProgressDetail(pass: pass, passes: passes, attempt: attempt)))
                case .status(let phase):
                    if phase == "verifying" { onUpdate(.status(.finalizing)) }
                    if phase == "processing" || phase == "refining" { onUpdate(.status(.processing)) }
                case .log(_, let code, let message):
                    onUpdate(.log(code: code, message: message))
                }
            }
            tempOutput = URL(fileURLWithPath: result.tempOutput)
            encoder = result.encoder
            hardware = result.hardware
            fallbackReason = result.fallbackReason
            attempts = result.attempts
            outputInfo = result.outputInfo
        }
        if Task.isCancelled { throw .cancelled }

        onUpdate(.status(.finalizing))
        let size = (try? FileManager.default.attributesOfItem(atPath: tempOutput.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if plan.engine != .ffmpeg, let limit = plan.verify.mustBeSmallerThan, size >= limit {
            throw ChosError(code: "not_smaller", category: "engine",
                            message: "This file is already well compressed; the result wasn't smaller.",
                            recovery: ["reduce_quality", "choose_other_format"])
        }

        let outputDir: URL = switch spec.policy.location {
        case .sameFolder: input.deletingLastPathComponent()
        case .custom(let d): URL(fileURLWithPath: d, isDirectory: true)
        }
        let request = FinalizeRequest(source: input.path, extension: plan.outputExtension, policy: spec.policy,
                                      tempFile: tempOutput.path)
        let outcome: FinalizeOutcome = try await access.withAccess(to: outputDir) { () throws(ChosError) -> FinalizeOutcome in
            try CoreBridge.call("output.finalize", request)
        }

        switch outcome {
        case .written(let path, let bytes, _):
            Log.output.info("job \(spec.id, privacy: .public) wrote \(bytes) bytes")
            return JobOutcome(outputURL: URL(fileURLWithPath: path), skippedBecauseExists: nil, inputBytes: spec.input.sizeBytes,
                              outputBytes: bytes, outputFormat: plan.outputFormat, engine: plan.engine, encoder: encoder,
                              hardware: hardware, fallbackReason: fallbackReason, attempts: attempts,
                              reencoded: plan.reencode, outputInfo: outputInfo)
        case .skipped(let existing):
            return JobOutcome(outputURL: nil, skippedBecauseExists: URL(fileURLWithPath: existing), inputBytes: spec.input.sizeBytes,
                              outputBytes: 0, outputFormat: plan.outputFormat, engine: plan.engine, encoder: encoder,
                              hardware: hardware, fallbackReason: fallbackReason, attempts: attempts,
                              reencoded: plan.reencode, outputInfo: nil)
        }
    }
}
