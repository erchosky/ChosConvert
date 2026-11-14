#!/usr/bin/env bash
# Fails if networking APIs or network-capable dependencies appear in ChosConvert's code.
# Part of the privacy guarantee "Your files never leave your computer" (ADR-0016).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
status=0

swift_hits=$(grep -rnE '\b(URLSession|NWConnection|NWPathMonitor|NWBrowser|CFSocket|CFStream|WKWebView|import Network\b|URLRequest)\b' \
  "$ROOT/macos" --include='*.swift' || true)
rust_hits=$(grep -rnE '(std::net::|TcpStream|UdpSocket|reqwest|hyper::|ureq::|tokio::net)' \
  "$ROOT/core" --include='*.rs' --exclude-dir=target || true)
dep_hits=$(grep -nE '^name = "(reqwest|hyper|ureq|curl|isahc|surf|attohttpc)"' "$ROOT/core/Cargo.lock" || true)
cs_hits=$(grep -rnE '\b(HttpClient|WebClient|Socket|TcpClient|WebView2)\b' "$ROOT/windows" --include='*.cs' 2>/dev/null || true)
ent_hits=$(grep -n 'network' "$ROOT/macos/App/Sources/ChosConvert.entitlements" | grep -v '<!--' || true)

for label in swift_hits rust_hits dep_hits cs_hits ent_hits; do
  if [ -n "${!label}" ]; then
    echo "✗ networking found ($label):"; echo "${!label}"; status=1
  fi
done
[ $status -eq 0 ] && echo "✓ no networking APIs, dependencies or entitlements"
exit $status
