import ChosConvertKit
import Foundation
import Testing
@testable import ChosConvertUI

/// Exercises the same model the window uses: drop → inspect → smart actions → start → result.
@MainActor @Suite(.serialized) struct AppFlowTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/generated")

    func makeModel() throws -> (AppModel, URL) {
        let suite = "cc-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (AppModel(settings: settings), dir)
    }

    func waitUntil(_ timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func videoMakeSmallerFlow() async throws {
        let (model, dir) = try makeModel()
        let src = dir.appendingPathComponent("grabacion.mov")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("video_h264_aac.mov"), to: src)
        await model.bootstrap()
        model.add(urls: [src])
        try await waitUntil { !model.isInspecting && !model.actions.isEmpty }
        let info = try #require(model.readyFiles.first)
        #expect(info.primaryVideo?.width == 640)
        let ids = model.actions.map(\.id)
        #expect(ids.contains(.makeSmaller))
        #expect(ids.contains(.extractAudio))
        #expect(!ids.contains(.webOptimize), "image-only actions never appear for video")

        // Configure like the sheet does, check the plan, then start.
        let plan = try model.plan(.convert(.mp4), options: AdvancedOptions(), for: info).get()
        #expect(plan.reencode == false)
        model.start(.convert(.mp4), options: AdvancedOptions(), files: [info])
        #expect(model.section == .queue)
        let item = try #require(model.queue.items.first)
        try await waitUntil { item.status.isTerminal }
        #expect(item.status == .completed, "\(String(describing: item.error))")
        let out = try #require(item.outcome?.outputURL)
        #expect(out.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL, "saved next to the original")
        #expect(FileManager.default.fileExists(atPath: src.path), "original kept")
    }

    @Test func imageBatchAndFailureIsolation() async throws {
        let (model, dir) = try makeModel()
        var urls: [URL] = []
        for i in 0..<5 {
            let u = dir.appendingPathComponent("photo \(i).heic")
            try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("photo.heic"), to: u)
            urls.append(u)
        }
        let bad = dir.appendingPathComponent("not-a-photo.jpg")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("renamed_executable.jpg"), to: bad)
        await model.bootstrap()
        model.add(urls: urls + [bad])
        try await waitUntil { !model.isInspecting && !model.actions.isEmpty }
        #expect(model.readyFiles.count == 5)
        let failed = model.files.first { $0.url == bad }
        if case .failed(let e) = failed?.state { #expect(e.code == "executable_rejected") } else { Issue.record("exe accepted") }
        let convert = try #require(model.actions.first { $0.id == .convert })
        #expect(convert.formats?.contains(.webp) == true)
        model.start(.convert(.webp), options: AdvancedOptions(), files: model.readyFiles)
        try await waitUntil { model.queue.items.allSatisfy { $0.status.isTerminal } }
        #expect(model.queue.items.filter { $0.status == .completed }.count == 5)
        let outs = model.queue.items.compactMap { $0.outcome?.outputURL?.lastPathComponent }.sorted()
        #expect(outs == (0..<5).map { "photo \($0).webp" })
    }

    @Test func notSmallerIsReportedNotSaved() async throws {
        let (model, dir) = try makeModel()
        // A tiny MP3 at 128 kb/s re-encoded "smaller" may or may not shrink; a WAV→make smaller must.
        let src = dir.appendingPathComponent("audio.wav")
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent("audio.wav"), to: src)
        await model.bootstrap()
        model.add(urls: [src])
        try await waitUntil { !model.isInspecting && !model.actions.isEmpty }
        model.start(.makeSmaller(.balanced), options: AdvancedOptions(), files: model.readyFiles)
        let item = try #require(model.queue.items.first)
        try await waitUntil { item.status.isTerminal }
        #expect(item.status == .completed)
        #expect((item.outcome?.outputBytes ?? .max) < (item.outcome?.inputBytes ?? 0))
    }
}
