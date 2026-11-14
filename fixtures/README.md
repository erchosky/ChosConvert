# Golden fixtures

Small, redistributable test files used by the Rust and Swift integration tests.

| File | What it exercises |
| --- | --- |
| `video_h264_aac.mov` | QuickTime H.264 + AAC, 640×360, 3 s, with `location`/`title` tags |
| `video_hevc_portrait.mp4` | HEVC (`hvc1`), portrait 360×640, 2 s |
| `video_vp9_opus_subs.mkv` | Matroska VP9 + Opus + SRT subtitle with non-ASCII text |
| `audio.wav` / `audio_24bit.wav` | PCM 16-bit stereo / 24-bit mono |
| `audio.mp3` | MP3 128 kb/s with an `artist` tag |
| `photo_gps.jpg` | JPEG with EXIF, GPS, camera make/model and orientation 6 |
| `photo.heic` | HEIC with GPS |
| `logo_alpha.png` | PNG with transparency |
| `large.png` | 3000×2000 PNG (web-optimize / resize paths) |
| `corrupt_truncated.mov`, `corrupt_truncated.jpg`, `corrupt_invalid.pdf` | damaged inputs |
| `renamed_executable.jpg` | PE header renamed to `.jpg` (must be rejected) |

**Origin and license.** Every file is synthesized locally by `scripts/make-fixtures.sh` (FFmpeg
test patterns and sine tones, Core Graphics drawings). They contain no third-party content and
are dedicated to the public domain under **CC0-1.0**. Regenerate with:

```bash
scripts/make-fixtures.sh
```

Large inputs (e.g. the 100 MB → 10 MB acceptance test) are generated at test time in a temp
directory and never committed.
