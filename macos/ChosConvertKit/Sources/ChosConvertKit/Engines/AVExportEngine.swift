import AVFoundation
import Foundation

/// Native media engine based on AVAssetExportSession presets. Used when FFmpeg isn't part of
/// the distribution. Progress is real (`AVAssetExportSession.states`), cancellation follows
/// Swift task cancellation.
public enum AVExportEngine {
    static func fileType(_ f: FileFormat) -> AVFileType? {
        switch f {
        case .mp4: .mp4
        case .mov: .mov
        case .m4a: .m4a
        default: nil
        }
    }

    public static func run(_ job: NativeAvJob, input: URL, output: URL,
                           progress: @escaping @Sendable (Double?) -> Void) async throws(ChosError) {
        guard let type = fileType(job.fileType) else { throw .unsupported("This output format isn't supported by the system encoder.") }
        do {
            let asset = AVURLAsset(url: input)
            let source: AVAsset = job.stripMetadata ? try await mediaOnlyComposition(asset) : asset
            guard let session = AVAssetExportSession(asset: source, presetName: job.preset) else {
                throw ChosError.unsupported("The system encoder can't export this file with the chosen settings.")
            }
            guard await session.compatibleFileTypes.contains(type) else {
                throw ChosError.unsupported("The system encoder can't write this file type for this input.")
            }
            session.shouldOptimizeForNetworkUse = true
            if job.stripMetadata {
                session.metadata = []
                session.metadataItemFilter = .forSharing()
            }
            // AVAssetExportSession's async APIs are safe to observe while exporting.
            let observed = UncheckedSendable(session)
            let monitor = Task {
                for await state in observed.value.states(updateInterval: 0.2) {
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
            }
            defer { monitor.cancel() }
            try await session.export(to: output, as: type)
            progress(1)
        } catch let e as ChosError {
            throw e
        } catch {
            if Task.isCancelled || error is CancellationError { throw .cancelled }
            let ns = error as NSError
            throw ChosError(code: "encoder_failed", category: "engine",
                            message: "The system encoder couldn't convert this file.",
                            recovery: ["choose_other_format"], details: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
        }
    }

    /// Builds a composition with only audio and video tracks, which drops timed metadata
    /// tracks (e.g. per-frame location) that a passthrough export would otherwise copy.
    static func mediaOnlyComposition(_ asset: AVURLAsset) async throws -> AVAsset {
        let comp = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let ct = comp.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try ct.insertTimeRange(range, of: track, at: .zero)
            if track.mediaType == .video {
                ct.preferredTransform = try await track.load(.preferredTransform)
            }
        }
        return comp
    }
}
