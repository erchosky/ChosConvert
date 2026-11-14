import Foundation
import ImageIO
import Testing
@testable import ChosConvertKit

/// End-to-end conversions on the golden fixtures (fixtures/generated, see scripts/make-fixtures.sh).
@Suite(.serialized) struct EngineIntegrationTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/generated")

    let sandbox: URL
    let outDir: URL
    let runner: JobRunner

    init() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("cc-swift-it-\(UUID().uuidString)")
        outDir = sandbox.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        runner = JobRunner(temp: TempSpace(root: sandbox.appendingPathComponent("tmp")), access: OutputAccess())
    }

    func copyFixture(_ name: String, as newName: String? = nil) throws -> URL {
        let dst = sandbox.appendingPathComponent(newName ?? name)
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(name), to: dst)
        return dst
    }

    var policy: OutputPolicy { OutputPolicy(location: .custom(directory: outDir.path)) }

    static func capabilities(ffmpeg: Bool) async -> Capabilities {
        var caps = await CapabilityService.shared.current()
        if !ffmpeg { caps.ffmpeg = nil }
        return caps
    }

    func convert(_ url: URL, _ intent: Intent, ffmpeg: Bool = false, options: AdvancedOptions = AdvancedOptions()) async throws -> JobOutcome {
        let caps = await Self.capabilities(ffmpeg: ffmpeg)
        let info = try await Inspector.inspect(url, capabilities: caps)
        let spec = JobSpec(input: info, intent: intent, options: options, policy: policy)
        return try await runner.run(spec, capabilities: caps) { _ in }
    }

    func imageProps(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    }

    @Test func inspectsJpegWithGpsAndOrientation() async throws {
        let caps = await Self.capabilities(ffmpeg: false)
        let info = try await Inspector.inspect(Self.fixtures.appendingPathComponent("photo_gps.jpg"), capabilities: caps)
        #expect(info.detection.format == .jpeg)
        #expect(info.image?.hasGps == true)
        #expect(info.image?.orientation == 6)
        #expect(info.image.map { $0.displaySize.width } == 1200)
        #expect(info.metadata.contains { $0.key == "GPSPosition" && $0.sensitive })
    }

    @Test func heicToJpegKeepsOriginal() async throws {
        let src = try copyFixture("photo.heic")
        let before = try Data(contentsOf: src)
        let out = try await convert(src, .convert(.jpeg))
        let url = try #require(out.outputURL)
        #expect(url.pathExtension == "jpg")
        #expect(url.deletingLastPathComponent().standardizedFileURL == outDir.standardizedFileURL)
        let det = try await Inspector.detect(url)
        #expect(det.format == .jpeg)
        #expect(try Data(contentsOf: src) == before)
    }

    @Test func heicToWebPUsesCoreEncoder() async throws {
        let src = try copyFixture("photo.heic")
        let out = try await convert(src, .convert(.webp))
        #expect(out.encoder == "libwebp")
        let url = try #require(out.outputURL)
        #expect(try await Inspector.detect(url).format == .webp)
        let props = imageProps(url)
        #expect((props[kCGImagePropertyPixelWidth] as? Int) == 1600)
    }

    @Test func pngAlphaToJpegFlattens() async throws {
        let src = try copyFixture("logo_alpha.png")
        let out = try await convert(src, .convert(.jpeg))
        let props = imageProps(try #require(out.outputURL))
        #expect((props[kCGImagePropertyHasAlpha] as? Bool) != true)
    }

    @Test func webOptimizeResizesAndStripsMetadata() async throws {
        let src = try copyFixture("large.png")
        let out = try await convert(src, .webOptimize)
        let url = try #require(out.outputURL)
        let props = imageProps(url)
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        #expect(max(w, h) == 1920)
        #expect(out.outputBytes < out.inputBytes)
    }

    @Test func removeLocationIsLosslessAndKeepsOrientation() async throws {
        let src = try copyFixture("photo_gps.jpg")
        let out = try await convert(src, .removeMetadata(.location))
        #expect(out.reencoded == false)
        let props = imageProps(try #require(out.outputURL))
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect((props[kCGImagePropertyOrientation] as? Int) == 6)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifLensModel] != nil, "location-only removal keeps other EXIF")
    }

    @Test func removeAllMetadataStripsCameraData() async throws {
        let src = try copyFixture("photo_gps.jpg")
        let out = try await convert(src, .removeMetadata(.all))
        let props = imageProps(try #require(out.outputURL))
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifLensModel] == nil)
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect((props[kCGImagePropertyOrientation] as? Int) == 6)
    }

    @Test func collisionsAreNumbered() async throws {
        let src = try copyFixture("photo.heic")
        let a = try await convert(src, .convert(.png))
        let b = try await convert(src, .convert(.png))
        #expect(a.outputURL?.lastPathComponent == "photo.png")
        #expect(b.outputURL?.lastPathComponent == "photo (1).png")
    }

    @Test func nativeAvMakesVideoSmallerWithoutFFmpeg() async throws {
        let src = try copyFixture("video_h264_aac.mov", as: "clip.mov")
        let caps = await Self.capabilities(ffmpeg: false)
        let info = try await Inspector.inspect(src, capabilities: caps)
        #expect(info.inspector == "avfoundation")
        #expect(info.primaryVideo?.codec == "h264")
        #expect(abs((info.durationS ?? 0) - 3) < 0.1)
        let plan = try JobRunner.plan(JobSpec(input: info, intent: .convert(.mp4), policy: policy), capabilities: caps)
        #expect(plan.engine == .nativeAv)
        let out = try await convert(src, .convert(.mp4))
        let outInfo = try await Inspector.inspect(try #require(out.outputURL), capabilities: caps)
        #expect(outInfo.detection.format == .mp4)
    }

    @Test func nativeWavToAac() async throws {
        let src = try copyFixture("audio.wav")
        let out = try await convert(src, .convert(.m4a))
        let url = try #require(out.outputURL)
        #expect(url.pathExtension == "m4a")
        #expect(out.outputBytes < out.inputBytes)
    }

    @Test func ffmpegWavToMp3WhenAvailable() async throws {
        let caps = await Self.capabilities(ffmpeg: true)
        guard caps.ffmpeg != nil else { return }
        let src = try copyFixture("audio.wav")
        let out = try await convert(src, .convert(.mp3), ffmpeg: true)
        #expect(out.engine == .ffmpeg)
        let info = try await Inspector.inspect(try #require(out.outputURL), capabilities: caps)
        #expect(info.primaryAudio?.codec == "mp3")
    }

    @Test func ffmpegJobCancellationIsClean() async throws {
        let caps = await Self.capabilities(ffmpeg: true)
        guard caps.ffmpeg != nil else { return }
        let src = try copyFixture("video_h264_aac.mov", as: "cancel.mov")
        let info = try await Inspector.inspect(src, capabilities: caps)
        var options = AdvancedOptions()
        options.encoder = .software
        options.crf = 10
        let spec = JobSpec(input: info, intent: .makeSmaller(.high), options: options, policy: policy)
        let runner = self.runner
        let task = Task { try await runner.run(spec, capabilities: caps) { _ in } }
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            #expect((error as? ChosError)?.isCancellation == true)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.appendingPathComponent("tmp").path)
        #expect(leftovers.isEmpty, "job temp dirs removed: \(leftovers)")
    }

    @Test func corruptAndHostileFilesAreRejected() async throws {
        let caps = await Self.capabilities(ffmpeg: false)
        for (name, code) in [("corrupt_truncated.jpg", "corrupt_file"), ("renamed_executable.jpg", "executable_rejected"),
                             ("corrupt_invalid.pdf", "corrupt_file")] {
            do {
                _ = try await Inspector.inspect(Self.fixtures.appendingPathComponent(name), capabilities: caps)
                Issue.record("\(name) should fail")
                continue
            } catch {
                #expect(error.code == code, "\(name)")
            }
        }
    }
}
