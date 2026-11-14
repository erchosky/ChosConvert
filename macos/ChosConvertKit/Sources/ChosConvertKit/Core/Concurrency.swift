import Foundation

/// Runs blocking work off the caller's executor, preserving typed `ChosError`s and
/// propagating cancellation into the detached task.
public func offMain<T: Sendable>(priority: TaskPriority = .userInitiated,
                                 _ body: @escaping @Sendable () throws(ChosError) -> T) async throws(ChosError) -> T {
    let task = Task.detached(priority: priority) { () -> Result<T, ChosError> in
        do throws(ChosError) { return .success(try body()) } catch { return .failure(error) }
    }
    let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    return try result.get()
}

/// Wraps a value whose type isn't annotated Sendable but is documented as thread-safe.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
