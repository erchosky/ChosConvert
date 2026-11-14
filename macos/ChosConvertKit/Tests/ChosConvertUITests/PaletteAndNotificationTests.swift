@testable import ChosConvertKit
import Foundation
import Testing
@testable import ChosConvertUI

@MainActor @Suite struct CommandPaletteTests {
    func command(_ title: String, keywords: [String] = [], disabled: Bool = false) -> PaletteCommand {
        PaletteCommand(id: title, kind: .addFiles, title: title, symbol: "x", keywords: keywords,
                       disabledReason: disabled ? "no" : nil)
    }

    @Test func fuzzyMatching() {
        let webp = command("Convert to WebP", keywords: ["webp"])
        let smaller = command("Make smaller", keywords: ["compress", "comprimir"])
        let video = command("Comprimir vídeo", keywords: ["video"])
        let queue = command("Open Queue")
        let all = [webp, smaller, video, queue]
        #expect(PaletteSearch.filter("webp", all).first == webp)
        #expect(PaletteSearch.filter("cwebp", all) == [webp], "in-order characters")
        #expect(PaletteSearch.filter("compress", all).first == smaller, "synonyms in keywords")
        #expect(PaletteSearch.filter("VIDEO", all).first == video, "case and accent insensitive")
        #expect(PaletteSearch.filter("open q", all) == [queue], "every word must match")
        #expect(PaletteSearch.filter("zzz", all).isEmpty)
        #expect(PaletteSearch.filter("", all) == all, "empty query keeps the catalog order")
    }

    @Test func disabledCommandsSortLast() {
        let a = command("Convert to PNG", disabled: true)
        let b = command("Convert to JPEG")
        #expect(PaletteSearch.filter("convert", [a, b]) == [b, a])
    }

    @Test func intentsWithoutFilesAreSuggestionsThatAskForFiles() {
        let cmds = PaletteCatalog.intentCommands(actions: [], families: [], hasFiles: false)
        #expect(cmds.allSatisfy { $0.isEnabled })
        let titles = cmds.map(\.title)
        #expect(titles.contains(L.f("palette.convert_to", FileFormat.webp.displayName)))
        #expect(titles.contains(L.s("palette.compress_video")))
        #expect(titles.contains(L.s("palette.privacy_safe")))
    }

    @Test func intentsFollowTheLoadedFiles() throws {
        let videoActions = [
            SmartAction(id: .makeSmaller, primary: true, formats: nil),
            SmartAction(id: .convert, primary: true, formats: [.mp4, .webm]),
            SmartAction(id: .removeMetadata, primary: false, formats: nil),
        ]
        let video = PaletteCatalog.intentCommands(actions: videoActions, families: [.video], hasFiles: true)
        let compress = try #require(video.first { $0.kind == .intent(.compressVideo) })
        #expect(compress.isEnabled)
        #expect(video.filter { if case .intent(.action(.convert, _)) = $0.kind { true } else { false } }.map(\.title)
                == [FileFormat.mp4, .webm].map { L.f("palette.convert_to", $0.displayName) })
        #expect(video.first { $0.kind == .intent(.privacySafe) }?.isEnabled == true)
        #expect(video.first { $0.kind == .intent(.action(.extractAudio, format: nil)) }?.isEnabled == false,
                "listed, but disabled with a reason, when the planner doesn't offer it")

        let images = PaletteCatalog.intentCommands(actions: videoActions, families: [.image], hasFiles: true)
        #expect(images.first { $0.kind == .intent(.compressVideo) }?.disabledReason == L.s("palette.reason.video_only"))
    }

    @Test func paletteIntentOpensTheConfiguratorPreset() async throws {
        let (model, dir) = try AppFlowTests().makeModel()
        let src = dir.appendingPathComponent("photo.heic")
        try FileManager.default.copyItem(at: AppFlowTests.fixtures.appendingPathComponent("photo.heic"), to: src)
        await model.bootstrap()
        model.add(urls: [src])
        try await AppFlowTests().waitUntil { !model.isInspecting && !model.actions.isEmpty }
        model.performPaletteIntent(.action(.convert, format: .png))
        let request = try #require(model.activeAction)
        #expect(request.action.id == .convert)
        #expect(request.preferredFormat == .png)
        // Compress video does nothing for photos (it is shown disabled in the palette).
        model.activeAction = nil
        model.performPaletteIntent(.compressVideo)
        #expect(model.activeAction == nil)
        // The full command list includes navigation.
        let all = PaletteCatalog.commands(for: model)
        #expect(all.contains { $0.kind == .navigate(.queue) })
        #expect(all.first { $0.kind == .cancelAll }?.isEnabled == false)
    }
}

@MainActor @Suite(.serialized) struct CompletionNotifierTests {
    @Test func policy() {
        typealias N = CompletionNotifier
        #expect(N.shouldNotify(status: .completed, elapsed: 9, enabled: true, appActive: false))
        #expect(N.shouldNotify(status: .failed, elapsed: 30, enabled: true, appActive: false))
        #expect(!N.shouldNotify(status: .completed, elapsed: 3, enabled: true, appActive: false), "short jobs never notify")
        #expect(!N.shouldNotify(status: .completed, elapsed: 60, enabled: true, appActive: true), "not while the app is in front")
        #expect(!N.shouldNotify(status: .completed, elapsed: 60, enabled: false, appActive: false), "setting off")
        #expect(!N.shouldNotify(status: .cancelled, elapsed: 60, enabled: true, appActive: false), "the user cancelled it")
    }

    @Test func content() {
        let a = URL(fileURLWithPath: "/tmp/a.webp"), b = URL(fileURLWithPath: "/tmp/b.webp")
        let one = CompletionNotifier.content(for: .init(completed: [a]))
        #expect(one.title == L.s("notify.done.title") && one.body == "a.webp")
        #expect(CompletionNotifier.content(for: .init(completed: [a, b])).body == L.f("notify.done.many", 2))
        #expect(CompletionNotifier.content(for: .init(failed: ["x.mov"])).title == L.s("notify.failed.title"))
        #expect(CompletionNotifier.content(for: .init(completed: [a], failed: ["x"])).body == L.f("notify.mixed.body", 1, 1))
    }

    @Test func jobsFinishingTogetherAreCoalesced() async throws {
        let (model, dir) = try AppFlowTests().makeModel()
        var urls: [URL] = []
        for i in 0..<3 {
            let u = dir.appendingPathComponent("logo \(i).png")
            try FileManager.default.copyItem(at: AppFlowTests.fixtures.appendingPathComponent("logo_alpha.png"), to: u)
            urls.append(u)
        }
        var posted: [CompletionNotifier.Summary] = []
        model.notifier.minimumDuration = 0
        model.notifier.isAppActive = { false }
        model.notifier.post = { posted.append($0) }
        await model.bootstrap()
        model.add(urls: urls)
        try await AppFlowTests().waitUntil { !model.isInspecting && !model.actions.isEmpty }
        model.start(.convert(.jpeg), options: AdvancedOptions(), files: model.readyFiles)
        try await AppFlowTests().waitUntil { model.queue.items.allSatisfy { $0.status.isTerminal } }
        try await AppFlowTests().waitUntil(.seconds(5)) { !posted.isEmpty }
        #expect(posted.count == 1)
        #expect(posted.first?.completed.count == 3)
        #expect(model.recentResults.count == 3)
    }
}
