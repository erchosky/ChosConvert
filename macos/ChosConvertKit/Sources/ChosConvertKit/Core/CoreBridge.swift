import CChosConvertCore
import Foundation

/// JSON coding conventions shared with the Rust core (snake_case keys).
public enum CoreJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

/// Progress and status events from long-running core tasks.
public enum CoreTaskEvent: Sendable, Equatable {
    case status(phase: String)
    case progress(fraction: Double?, speed: Double?, pass: UInt32, passes: UInt32, attempt: UInt32)
    case log(level: String, code: String, message: String)
}

/// Thin, type-safe wrapper around the core's C ABI. All calls are thread-safe.
public enum CoreBridge {
    /// The ABI this build of the app was written against.
    public static let expectedABIVersion: UInt32 = 1

    public static var abiVersion: UInt32 { cc_abi_version() }

    public static var version: String { String(cString: cc_core_version()) }

    /// Verifies the linked core matches the app. Call once at launch.
    public static func checkCompatibility() throws(ChosError) {
        guard abiVersion == expectedABIVersion else {
            throw ChosError.internalError("core ABI \(abiVersion), expected \(expectedABIVersion)")
        }
    }

    private struct Envelope<T: Decodable>: Decodable {
        var ok: Bool
        var result: T?
        var error: ChosError?
    }

    public struct Empty: Encodable, Sendable { public init() {} }

    /// Synchronous call. Do not call on the main thread for methods that touch the file system
    /// or spawn processes (`media.probe`, `capabilities.probe_ffmpeg`).
    public static func call<R: Decodable>(_ method: String, _ payload: some Encodable = Empty(), as type: R.Type = R.self) throws(ChosError) -> R {
        let json: String
        do {
            json = String(decoding: try CoreJSON.encoder().encode(payload), as: UTF8.self)
        } catch {
            throw ChosError.internalError("encode \(method): \(error)")
        }
        guard let raw = method.withCString({ m in json.withCString { p in cc_call(m, p) } }) else {
            throw ChosError.internalError("core returned null for \(method)")
        }
        defer { cc_string_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        let env: Envelope<R>
        do {
            env = try CoreJSON.decoder().decode(Envelope<R>.self, from: data)
        } catch {
            throw ChosError.internalError("decode \(method): \(error)")
        }
        if env.ok, let r = env.result { return r }
        throw env.error ?? ChosError.internalError("\(method): malformed envelope")
    }

    // MARK: Tasks

    private final class TaskBox: @unchecked Sendable {
        let continuation: AsyncStream<Data>.Continuation
        init(_ c: AsyncStream<Data>.Continuation) { continuation = c }
    }

    private struct RawEvent: Decodable {
        var type: String
        var phase: String?
        var fraction: Double?
        var speed: Double?
        var pass: UInt32?
        var passes: UInt32?
        var attempt: UInt32?
        var level: String?
        var code: String?
        var message: String?
        var error: ChosError?
    }

    private struct Completed<R: Decodable>: Decodable { var result: R }

    private static let callback: cc_event_callback = { userData, _, eventJSON in
        guard let userData, let eventJSON else { return }
        let box = Unmanaged<TaskBox>.fromOpaque(userData).takeUnretainedValue()
        let data = Data(bytes: eventJSON, count: strlen(eventJSON))
        box.continuation.yield(data)
        // The terminal event is always last: release the box exactly once.
        if let type = try? JSONDecoder().decode([String: AnyDecodable].self, from: data)["type"]?.string,
           ["completed", "failed", "cancelled"].contains(type) {
            box.continuation.finish()
            Unmanaged<TaskBox>.fromOpaque(userData).release()
        }
    }

    /// Runs a long core task, forwarding progress events and honoring Swift task cancellation.
    public static func runTask<R: Decodable & Sendable>(
        _ method: String,
        _ payload: some Encodable,
        as type: R.Type = R.self,
        onEvent: @escaping @Sendable (CoreTaskEvent) -> Void
    ) async throws(ChosError) -> R {
        if Task.isCancelled { throw .cancelled }
        let json: String
        do {
            json = String(decoding: try CoreJSON.encoder().encode(payload), as: UTF8.self)
        } catch {
            throw ChosError.internalError("encode \(method): \(error)")
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let box = TaskBox(continuation)
        let opaque = Unmanaged.passRetained(box).toOpaque()
        let id = method.withCString { m in json.withCString { p in cc_task_start(m, p, callback, opaque) } }
        guard id != 0 else {
            Unmanaged<TaskBox>.fromOpaque(opaque).release()
            throw ChosError.internalError("core refused task \(method)")
        }

        let decoder = CoreJSON.decoder()
        let outcome: Result<R, ChosError> = await withTaskCancellationHandler {
            for await data in stream {
                guard let ev = try? decoder.decode(RawEvent.self, from: data) else { continue }
                switch ev.type {
                case "status":
                    onEvent(.status(phase: ev.phase ?? ""))
                case "progress":
                    onEvent(.progress(fraction: ev.fraction, speed: ev.speed, pass: ev.pass ?? 1,
                                      passes: ev.passes ?? 1, attempt: ev.attempt ?? 1))
                case "log":
                    onEvent(.log(level: ev.level ?? "info", code: ev.code ?? "", message: ev.message ?? ""))
                case "completed":
                    do {
                        return .success(try decoder.decode(Completed<R>.self, from: data).result)
                    } catch {
                        return .failure(ChosError.internalError("decode \(method) result: \(error)"))
                    }
                case "failed":
                    return .failure(ev.error ?? ChosError.internalError("\(method) failed"))
                case "cancelled":
                    return .failure(.cancelled)
                default:
                    continue
                }
            }
            return .failure(ChosError.internalError("\(method) ended without a result"))
        } onCancel: {
            _ = cc_task_cancel(id)
        }
        return try outcome.get()
    }

    // MARK: WebP

    /// Encodes straight-alpha RGBA8 pixels to WebP with the bundled libwebp.
    public static func encodeWebP(rgba: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                                  quality: Double, lossless: Bool) throws(ChosError) -> Data {
        guard let base = rgba.baseAddress?.assumingMemoryBound(to: UInt8.self),
              rgba.count >= bytesPerRow * height else {
            throw ChosError.internalError("webp: invalid pixel buffer")
        }
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        var err: UnsafeMutablePointer<CChar>?
        let rc = cc_webp_encode(base, UInt32(width), UInt32(height), UInt32(bytesPerRow),
                                Float(quality * 100), lossless, &out, &len, &err)
        if rc == 0, let out {
            defer { cc_buffer_free(out, len) }
            return Data(bytes: out, count: len)
        }
        if let err {
            defer { cc_string_free(err) }
            let data = Data(bytes: err, count: strlen(err))
            if let env = try? CoreJSON.decoder().decode(Envelope<String>.self, from: data), let e = env.error {
                throw e
            }
        }
        throw ChosError.engine("The WebP encoder failed.")
    }
}

/// Minimal JSON value used only to peek at an event's `type`.
struct AnyDecodable: Decodable {
    let string: String?
    init(from decoder: any Decoder) throws {
        string = try? decoder.singleValueContainer().decode(String.self)
    }
}
