# Third-party notices

ChosConvert includes or links the components below. This file is regenerated as part of every
release (RELEASE.md); versions here match `core/Cargo.lock` on 2026-10-18.

## Linked into the application

| Component | Version | License | Source |
| --- | --- | --- | --- |
| libwebp (vendored in libwebp-sys) | 1.x (bundled by libwebp-sys 0.14.4) | BSD-3-Clause, Copyright (c) 2010 Google Inc. | https://chromium.googlesource.com/webm/libwebp |
| libwebp-sys | 0.14.4 | MIT | https://github.com/NoXF/libwebp-sys |
| serde, serde_core, serde_derive | 1.0.229 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_json | 1.0.154 | MIT OR Apache-2.0 | https://github.com/serde-rs/json |
| thiserror, thiserror-impl | 2.0.21 | MIT OR Apache-2.0 | https://github.com/dtolnay/thiserror |
| uuid | 1.28.0 | Apache-2.0 OR MIT | https://github.com/uuid-rs/uuid |
| getrandom | 0.4.3 | MIT OR Apache-2.0 | https://github.com/rust-random/getrandom |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 | https://github.com/rust-lang/cfg-if |
| libc | 0.2.191 | MIT OR Apache-2.0 | https://github.com/rust-lang/libc |
| itoa | 1.0.18 | MIT OR Apache-2.0 | https://github.com/dtolnay/itoa |
| memchr | 2.8.3 | Unlicense OR MIT | https://github.com/BurntSushi/memchr |
| zmij | 1.0.23 | MIT | crates.io |
| Rust standard library | 1.99.1 | MIT OR Apache-2.0 | https://github.com/rust-lang/rust |

Build-time only (not shipped): cc, find-msvc-tools, shlex, pkg-config, glob, proc-macro2, quote,
syn, unicode-ident (MIT/Apache-2.0, Unicode-3.0).

The BSD-3-Clause notice for libwebp:

> Copyright (c) 2010, Google Inc. All rights reserved. Redistribution and use in source and binary
> forms, with or without modification, are permitted provided that the following conditions are
> met: redistributions of source code must retain the above copyright notice, this list of
> conditions and the following disclaimer; redistributions in binary form must reproduce the above
> copyright notice, this list of conditions and the following disclaimer in the documentation
> and/or other materials provided with the distribution; neither the name of Google nor the names
> of its contributors may be used to endorse or promote products derived from this software
> without specific prior written permission. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS
> AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.

## FFmpeg

Current builds **do not bundle FFmpeg**. Debug builds may use an FFmpeg installed by the developer.
When the Direct distribution bundles FFmpeg (ADR-0005) this section will record: exact version,
full `configure` line (LGPL-only: no `--enable-gpl`, no `--enable-nonfree`), the enabled external
libraries and their licenses (libopus BSD, libvpx BSD, LAME LGPL, SVT-AV1 BSD-3-Clause-Clear,
dav1d BSD), the LGPL-2.1 text and a written offer / link to the exact corresponding source.

## Apple frameworks
ImageIO, AVFoundation, VideoToolbox, PDFKit, QuickLookThumbnailing and SwiftUI are part of macOS
and used under the Apple SDK license.
