import Foundation

/// A structured, user-presentable error. Mirrors the core's `AppError` and is also used for
/// errors raised by native engines, so the UI has a single error type to present.
public struct ChosError: Error, Codable, Sendable, Hashable, LocalizedError {
    /// Stable identifier, e.g. `encoder_failed`. Localized via `error.<code>` keys.
    public var code: String
    public var category: String
    /// English fallback message.
    public var message: String
    public var recovery: [String]?
    /// Technical details shown behind "View technical details". Never file contents.
    public var details: String?

    public init(code: String, category: String, message: String, recovery: [String]? = nil, details: String? = nil) {
        self.code = code
        self.category = category
        self.message = message
        self.recovery = recovery
        self.details = details
    }

    public var errorDescription: String? { message }
    public var isCancellation: Bool { code == "cancelled" }

    public static let cancelled = ChosError(code: "cancelled", category: "cancelled", message: "The operation was cancelled.")

    public static func engine(_ message: String, details: String? = nil, recovery: [String]? = nil) -> ChosError {
        ChosError(code: "engine_failed", category: "engine", message: message, recovery: recovery, details: details)
    }

    public static func unsupported(_ message: String) -> ChosError {
        ChosError(code: "unsupported_operation", category: "unsupported", message: message, recovery: ["choose_other_format"])
    }

    public static func internalError(_ details: String) -> ChosError {
        ChosError(code: "internal", category: "internal", message: "Something went wrong inside ChosConvert.", details: details)
    }

    public static func outputInvalid(_ details: String) -> ChosError {
        ChosError(code: "output_invalid", category: "engine", message: "The converted file didn't pass verification.",
                  recovery: ["retry"], details: details)
    }

    /// Wraps any error into a ChosError, preserving cancellation.
    public static func wrap(_ error: any Error) -> ChosError {
        if let e = error as? ChosError { return e }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSUserCancelledError { return .cancelled }
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
            return ChosError(code: "output_not_writable", category: "permission",
                             message: "ChosConvert doesn't have permission to access this location.",
                             recovery: ["grant_folder_access", "choose_output_folder"], details: "\(ns.domain) \(ns.code)")
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
            return ChosError(code: "disk_full", category: "io", message: "There isn't enough disk space.", recovery: ["free_disk_space"])
        }
        return .engine("The conversion failed.", details: "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }
}
