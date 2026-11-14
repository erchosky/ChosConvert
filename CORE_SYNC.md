# Sharing the core between `chosconvert-macos` and `chosconvert-windows`

During development everything lives in one workspace. For publication the product becomes two
independently buildable repositories without a tangled dependency.

## Target layout

```
chosconvert-core      (Rust: core + ffi + schemas + fixtures + check scripts)   tagged core-vX.Y.Z
chosconvert-macos     core/ = git subtree of chosconvert-core at a tag; macos/; docs
chosconvert-windows   core/ = git subtree of chosconvert-core at a tag; windows/; docs
```

`git subtree` (not submodules) keeps each app repo self-contained: a plain clone builds.

## Rules
1. The core changes only in `chosconvert-core` (or in this workspace's `core/`, then pushed there).
2. Every core release bumps `version` in `core/Cargo.toml`; incompatible JSON shape changes bump
   `api::API_VERSION`; signature/ownership changes bump `CC_ABI_VERSION`.
3. Apps pin a core tag. Updating is an explicit commit:
   ```bash
   git subtree pull --prefix core https://github.com/chosconvert/chosconvert-core core-v0.2.0 --squash
   ```
4. Each app checks `cc_abi_version()` at launch (`CoreBridge.checkCompatibility()`), and its tests
   decode real core responses, so a mismatched subtree fails CI.
5. Fixtures and `scripts/check-l10n.py`-style contracts (error codes, plan steps, notes) live with
   the core; each app keeps its own localization files and must cover every code (CI).

## Splitting this workspace (one-time)
```bash
git subtree split --prefix core -b core-only
```
Push `core-only` to `chosconvert-core`, then in each new app repo add it back with
`git subtree add --prefix core <url> core-v0.1.0 --squash` and move `macos/` or `windows/`.
