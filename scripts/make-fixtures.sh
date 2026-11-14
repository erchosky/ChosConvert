#!/usr/bin/env bash
# Regenerates the golden fixtures in fixtures/generated.
# All fixtures are synthesized locally (test patterns, sine tones, drawn shapes), so they are
# original works released under CC0-1.0. Requires FFmpeg (any build) and Swift (macOS).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/fixtures/generated"
FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"
mkdir -p "$OUT"
cd "$OUT"
ff() { "$FFMPEG" -hide_banner -loglevel error -y "$@"; }

# Video: 3 s, 640x360, 30 fps, H.264 + AAC in QuickTime, with a location tag.
ff -f lavfi -i "testsrc2=size=640x360:rate=30:duration=3" \
   -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3" \
   -c:v libx264 -preset veryfast -crf 26 -pix_fmt yuv420p -c:a aac -b:a 96k \
   -metadata "location=+40.4168-003.7038/" -metadata "title=ChosConvert fixture" \
   -movflags +use_metadata_tags video_h264_aac.mov
# Video: HEVC MP4, 2 s, portrait (rotation via display matrix).
ff -f lavfi -i "testsrc2=size=360x640:rate=25:duration=2" -c:v libx265 -preset fast -crf 30 \
   -x265-params log-level=error -tag:v hvc1 -pix_fmt yuv420p video_hevc_portrait.mp4
# Video: MKV with VP9 + Opus + SRT subtitle.
printf '1\n00:00:00,000 --> 00:00:01,500\nHola, ñandú\n' > subs.srt
ff -f lavfi -i "testsrc2=size=320x240:rate=24:duration=2" \
   -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=2" -i subs.srt \
   -map 0 -map 1 -map 2 -c:v libvpx-vp9 -b:v 200k -deadline realtime -c:a libopus -b:a 48k \
   -c:s srt video_vp9_opus_subs.mkv
rm subs.srt
# Audio
ff -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=3" -ac 2 -c:a pcm_s16le audio.wav
ff -f lavfi -i "sine=frequency=523:sample_rate=48000:duration=3" -c:a pcm_s24le audio_24bit.wav
ff -f lavfi -i "sine=frequency=330:sample_rate=44100:duration=3" -c:a libmp3lame -b:a 128k \
   -metadata artist="Fixture Artist" audio.mp3

# Corrupted / hostile
head -c 20000 video_h264_aac.mov > corrupt_truncated.mov
printf '%%PDF-1.7\nthis is not a valid pdf body\n' > corrupt_invalid.pdf
printf 'MZ\x90\x00\x03\x00\x00\x00\x04\x00\x00\x00\xff\xff' > renamed_executable.jpg

# Images (ImageIO): JPEG with EXIF+GPS, PNG with alpha, HEIC, large-ish PNG.
swift "$ROOT/scripts/fixtures/make_images.swift" "$OUT"
head -c 3000 photo_gps.jpg > corrupt_truncated.jpg

ls -la "$OUT"
