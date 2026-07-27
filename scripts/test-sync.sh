#!/usr/bin/env bash
#
# Gainmap sync backend — emulator test harness (P0).
#
#   scripts/test-sync.sh            run everything
#   scripts/test-sync.sh rules      run only the security-rules suite
#   scripts/test-sync.sh functions  run only the Cloud Functions suite
#
# Boots the auth/firestore/storage emulators against the throwaway project id
# `demo-gainmap` (the `demo-` prefix guarantees the CLI never contacts a real
# project), runs the node:test suites, and tears the emulators down. Exits
# non-zero if any test fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- Java (the Firestore + Storage emulators are JVM processes) --------------
# Homebrew's openjdk formulae are keg-only, so a working JDK is frequently
# installed but absent from PATH. Find one rather than failing spuriously.
# NOTE: macOS ships a /usr/bin/java *stub* that exists but fails with "Unable to
# locate a Java Runtime", so `command -v java` is not a usable check — actually
# run it.
java_works() { java -version >/dev/null 2>&1; }

if ! java_works; then
  for candidate in \
    /opt/homebrew/opt/openjdk@21/bin \
    /opt/homebrew/opt/openjdk@17/bin \
    /opt/homebrew/opt/openjdk/bin \
    /usr/local/opt/openjdk@21/bin \
    /usr/local/opt/openjdk/bin
  do
    if [ -x "$candidate/java" ] && "$candidate/java" -version >/dev/null 2>&1; then
      export PATH="$candidate:$PATH"
      break
    fi
  done
fi

if ! java_works; then
  echo "ERROR: no working Java runtime found. The Firestore and Storage emulators require one." >&2
  echo "       Install with:  brew install openjdk@21" >&2
  exit 1
fi
echo "java: $(java -version 2>&1 | head -1)"

# --- deps -------------------------------------------------------------------
if [ ! -d functions/node_modules ]; then
  echo "Installing functions dependencies..."
  ( cd functions && npm install --no-audit --no-fund )
fi

# --- which suites -----------------------------------------------------------
case "${1:-all}" in
  rules)     SUITES="functions/test/rules.test.mjs" ;;
  functions) SUITES="functions/test/functions.test.mjs" ;;
  all)       SUITES="functions/test/rules.test.mjs functions/test/functions.test.mjs" ;;
  *) echo "usage: $0 [all|rules|functions]" >&2; exit 2 ;;
esac

# --- ports ------------------------------------------------------------------
# firebase.json pins the canonical ports, but developer machines routinely have
# something else on 8080. Fall back to the next free port and hand the CLI a
# throwaway config rather than failing (or, worse, killing someone's server).
port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1; }
pick_port() {
  local p="$1"
  while ! port_free "$p"; do p=$((p + 1)); done
  echo "$p"
}
AUTH_PORT="$(pick_port "${GAINMAP_AUTH_PORT:-9099}")"
FS_PORT="$(pick_port "${GAINMAP_FIRESTORE_PORT:-8080}")"
ST_PORT="$(pick_port "${GAINMAP_STORAGE_PORT:-9199}")"

# The emulators drop *-debug.log files in the project root; they are pure noise
# in `git status`, so sweep them (and any temp config) on the way out.
TMP_CONFIG=""
cleanup() {
  [ -n "$TMP_CONFIG" ] && rm -f "$TMP_CONFIG"
  rm -f "$ROOT"/firestore-debug.log "$ROOT"/storage-debug.log \
        "$ROOT"/ui-debug.log "$ROOT"/firebase-debug.log
  return 0
}
trap cleanup EXIT

CONFIG_ARGS=()
if [ "$AUTH_PORT" != "9099" ] || [ "$FS_PORT" != "8080" ] || [ "$ST_PORT" != "9199" ]; then
  echo "note: default emulator ports busy — using auth=$AUTH_PORT firestore=$FS_PORT storage=$ST_PORT"
  TMP_CONFIG="$ROOT/.firebase.test-sync.json"   # must live at the project root so
                                                # the rules paths still resolve
  node -e '
    const fs = require("fs");
    const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    cfg.emulators.auth.port = Number(process.argv[3]);
    cfg.emulators.firestore.port = Number(process.argv[4]);
    cfg.emulators.storage.port = Number(process.argv[5]);
    fs.writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2));
  ' "$ROOT/firebase.json" "$TMP_CONFIG" "$AUTH_PORT" "$FS_PORT" "$ST_PORT"
  CONFIG_ARGS=(--config "$TMP_CONFIG")
fi

# --- run --------------------------------------------------------------------
command -v firebase >/dev/null 2>&1 || {
  echo "ERROR: firebase CLI not found (npm i -g firebase-tools)." >&2; exit 1; }

# ${CONFIG_ARGS[@]+...}: macOS bash 3.2 treats expanding an EMPTY array as an
# unbound variable under `set -u`; this idiom expands to nothing instead.
firebase emulators:exec \
  --project demo-gainmap \
  --only auth,firestore,storage \
  ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"} \
  "node --test --test-reporter=spec --test-concurrency=1 $SUITES"
