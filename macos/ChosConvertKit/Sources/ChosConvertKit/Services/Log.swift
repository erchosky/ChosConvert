import Foundation
import os

/// Structured logging. Paths and file names are logged with `.private` privacy so they are
/// redacted in collected logs; file contents and passwords are never logged.
public enum Log {
    public static let subsystem = Bundle.main.bundleIdentifier ?? "app.chosconvert"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let capabilities = Logger(subsystem: subsystem, category: "capabilities")
    public static let inspect = Logger(subsystem: subsystem, category: "inspect")
    public static let jobs = Logger(subsystem: subsystem, category: "jobs")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let output = Logger(subsystem: subsystem, category: "output")
}
