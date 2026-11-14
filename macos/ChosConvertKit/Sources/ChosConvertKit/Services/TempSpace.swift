import Foundation

/// The app's controlled temporary workspace. All intermediate files live in per-job
/// directories created and removed by the core, which refuses to delete anything else.
public struct TempSpace: Sendable {
    public let root: URL

    public static let shared = TempSpace(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("ChosConvert-Jobs", isDirectory: true))

    public init(root: URL) { self.root = root }

    struct CreateReq: Encodable { var root: String; var jobId: String }
    struct RemoveReq: Encodable { var root: String; var dir: String }
    struct CleanupReq: Encodable { var root: String; var minAgeS: UInt64; var active: [String] }

    public func createJobDirectory(id: UUID) throws(ChosError) -> URL {
        let dir: JobTempDir = try CoreBridge.call("temp.create_job_dir",
                                                  CreateReq(root: root.path, jobId: id.uuidString.lowercased()))
        return URL(fileURLWithPath: dir.path, isDirectory: true)
    }

    public func removeJobDirectory(_ dir: URL) {
        do {
            let _: Bool = try CoreBridge.call("temp.remove_job_dir", RemoveReq(root: root.path, dir: dir.path))
        } catch {
            Log.jobs.error("temp cleanup failed: \(error.code, privacy: .public)")
        }
    }

    /// Removes leftovers from previous runs (crash, force quit). Call at launch.
    @discardableResult
    public func cleanupStale(active: [UUID] = []) -> CleanupReport? {
        try? CoreBridge.call("temp.cleanup_stale",
                             CleanupReq(root: root.path, minAgeS: 0, active: active.map { $0.uuidString.lowercased() }))
    }
}
