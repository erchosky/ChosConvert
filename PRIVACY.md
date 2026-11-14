# Privacy

**Your files never leave your computer.**

- **Processing is local.** Every inspection and conversion runs on your Mac with built-in macOS
  frameworks and, in some editions, a bundled copy of FFmpeg. Nothing is uploaded.
- **No account, no login, no tracking.** ChosConvert contains no analytics, telemetry,
  advertising or crash-reporting SDKs and makes no network requests. Release builds are
  sandboxed without the network entitlement, so macOS itself blocks connections.
- **No hidden copies.** Intermediate files live in a private temporary folder for the duration of
  a conversion and are deleted afterwards (and at the next launch if the app was interrupted).
- **Originals are never modified or deleted.** Results are saved as new files.
- **Settings stay on this Mac** (UserDefaults). Folder permissions you grant are stored as macOS
  security-scoped bookmarks and can be reset in Settings ▸ Advanced.
- **Logs** use the system log; file paths are marked private and redacted in collected logs.
  File contents and passwords are never logged.
- **Permissions are asked only when needed:** access to a folder is requested the first time you
  save into it; no other permission is requested.
- **History** (coming in a later version) will be local only, optional, and clearable.

How this is enforced in code: see ADR-0016 and `scripts/check-offline.sh` (runs in CI).
