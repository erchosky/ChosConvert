import AppKit
import ChosConvertKit
import Foundation
import UserNotifications

/// Posts a local notification when long conversions finish while the user is elsewhere.
///
/// - Only jobs that ran for at least `threshold` seconds count (short jobs finish before anyone
///   looks away).
/// - Nothing is posted while ChosConvert is the active app: the queue is already on screen.
/// - Permission is requested the first time a notification is actually needed, never at launch.
/// - Jobs finishing close together are coalesced into one notification.
@MainActor
final class CompletionNotifier: NSObject {
    nonisolated static let threshold: TimeInterval = 8
    static let coalesceDelay: Duration = .milliseconds(1500)

    struct Summary: Equatable {
        var completed: [URL] = []
        var failed: [String] = []
        var isEmpty: Bool { completed.isEmpty && failed.isEmpty }
    }

    private let settings: AppSettings
    private var pending = Summary()
    private var flushTask: Task<Void, Never>?
    /// Notification Center needs a real app bundle; it is unavailable under `swift test`.
    private let isAvailable: Bool
    /// Overridable for tests.
    var minimumDuration: TimeInterval = CompletionNotifier.threshold
    var isAppActive: @MainActor () -> Bool = { NSApp?.isActive ?? false }
    var post: (@MainActor (Summary) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        isAvailable = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
        super.init()
        if isAvailable { UNUserNotificationCenter.current().delegate = self }
    }

    /// Decision for one finished job. Pure, unit-tested.
    nonisolated static func shouldNotify(status: JobStatus, elapsed: TimeInterval?, enabled: Bool, appActive: Bool,
                                         threshold: TimeInterval = threshold) -> Bool {
        guard enabled, !appActive, status == .completed || status == .failed else { return false }
        return (elapsed ?? 0) >= threshold
    }

    func jobFinished(_ item: JobItem) {
        guard Self.shouldNotify(status: item.status, elapsed: item.elapsed, enabled: settings.notifyOnCompletion,
                                appActive: isAppActive(), threshold: minimumDuration) else { return }
        if item.status == .completed, let url = item.outcome?.outputURL {
            pending.completed.append(url)
        } else if item.status == .failed {
            pending.failed.append(item.fileName)
        } else {
            return
        }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard let self, !Task.isCancelled else { return }
            let summary = self.pending
            self.pending = Summary()
            if let post = self.post { post(summary) } else { await self.deliver(summary) }
        }
    }

    /// Localized title and body for a summary. Pure, unit-tested.
    static func content(for s: Summary) -> (title: String, body: String) {
        if s.failed.isEmpty, s.completed.count == 1, let url = s.completed.first {
            return (L.s("notify.done.title"), url.lastPathComponent)
        }
        if s.failed.isEmpty {
            return (L.s("notify.done.title"), L.f("notify.done.many", s.completed.count))
        }
        if s.completed.isEmpty, s.failed.count == 1, let name = s.failed.first {
            return (L.s("notify.failed.title"), name)
        }
        return (L.s("notify.mixed.title"), L.f("notify.mixed.body", s.completed.count, s.failed.count))
    }

    private func deliver(_ summary: Summary) async {
        guard isAvailable, !summary.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            // First time a notification is needed: ask now, in context.
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            status = granted ? .authorized : .denied
        }
        guard status == .authorized || status == .provisional else { return }
        let (title, body) = Self.content(for: summary)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if summary.completed.count == 1, summary.failed.isEmpty, let url = summary.completed.first {
            content.userInfo = ["path": url.path]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            Log.app.error("notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension CompletionNotifier: UNUserNotificationCenterDelegate {
    /// Clicking a single-result notification shows the file in Finder; otherwise opens the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String
        await MainActor.run {
            if let path, FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                NSApp.activate()
            }
        }
    }
}
