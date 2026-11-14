# Security

## Reporting
Please report vulnerabilities privately via GitHub Security Advisories on the repository (or the
contact listed in `branding/brand.json` once published). Do not open public issues for security
problems. We aim to acknowledge within 3 working days.

## Threat model
Every input file is untrusted. Defenses implemented today:

| Threat | Mitigation | Where |
| --- | --- | --- |
| Command injection via file names (`;rm.mov`, `--help.mov`, `$HOME.mov`, quotes, Unicode) | FFmpeg is spawned with an argument vector, never a shell; paths only fill whole-argument placeholders and are passed as `file:` URLs (blocks `concat:`/protocol names and option parsing) | `core/src/ffmpeg/mod.rs`, tests `hostile_names_*` |
| Renamed executables / format spoofing | Content sniffing (magic bytes, brands); executables rejected before any engine sees them | `detect.rs` |
| Truncated/corrupt media | End-marker checks, probe failures mapped to `corrupt_file`, outputs re-verified | `detect.rs`, `executor.rs`, `ImageIOEngine.verify` |
| Decompression bombs | 400 MP pixel limit before decode; downsampled decode; WebP 16383 px limit | `planner/image.rs`, `ImageIOEngine` |
| Malicious metadata / huge probe output | ffprobe stdout capped at 32 MB, 30 s timeout | `executor::probe` |
| Temp-file attacks / deleting the wrong thing | Private 0700 job dirs with marker; deletion only of marked direct children, never through symlinks | `temp.rs` |
| Clobbering / race on output | Atomic no-clobber claim (hard link / `O_EXCL`), staged on the destination volume; the source is never a target | `output.rs` |
| Path traversal in names | Stem sanitization (separators, control chars, reserved Windows names, length) | `output.rs` |
| Resource exhaustion | Per-workload concurrency limits; bounded inspection parallelism; bounded stderr capture | `jobs.rs`, `JobQueue`, `runner.rs` |
| Privilege | App Sandbox in Release, user-selected file access only, no admin rights, no network | entitlements |
| FFI memory safety | Ownership rules documented in the header; panics caught at the boundary | `chosconvert-ffi` |

Planned: fuzzing of `detect_bytes` and `parse_ffprobe` (cargo-fuzz), PDF password handling that
never stores passwords.
