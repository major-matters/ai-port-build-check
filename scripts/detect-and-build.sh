#!/usr/bin/env bash
# detect-and-build.sh <dir>
#
# Clean-room build probe for one checked-out repository. Meant to run on a
# disposable GitHub-hosted Ubuntu runner. It:
#   1. scans the README/BUILD/docs files for signs that original game data is needed
#   2. detects the build system from the repository root
#   3. installs a common set of apt packages (failures ignored)
#   4. runs ONE conventional build command under a time budget
#   5. classifies the outcome and prints a single JSON object to stdout
#
# Build output goes to $BUILD_LOG (default /tmp/build.log). Nothing from the
# target repository is executed except the build commands listed below.
#
# Environment:
#   BUILD_TIMEOUT_MINUTES  total budget for apt + build (default 20)
#   BUILD_LOG              build log path (default /tmp/build.log)
#   SKIP_APT               set to 1 to skip the apt step
set -euo pipefail

DIR="${1:-}"
if [ -z "$DIR" ] || [ ! -d "$DIR" ]; then
  echo "usage: $0 <checked-out-repository-dir>" >&2
  exit 2
fi
DIR="$(cd "$DIR" && pwd)"

START_TS=$(date +%s)
BUDGET_MIN="${BUILD_TIMEOUT_MINUTES:-20}"
LOG="${BUILD_LOG:-/tmp/build.log}"
APT_LOG="${APT_LOG:-/tmp/apt.log}"
: > "$LOG"

export CI=true
export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0
export NPM_CONFIG_FUND=false
export NPM_CONFIG_AUDIT=false
export NPM_CONFIG_PROGRESS=false
export CARGO_TERM_COLOR=never
export GRADLE_OPTS="-Dorg.gradle.daemon=false"

if command -v nproc >/dev/null 2>&1; then
  JOBS=$(nproc)
else
  JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
fi

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

log() { printf '[harness] %s\n' "$*" | tee -a "$LOG" >&2; }

# ---------------------------------------------------------------------------
# 1. Asset scan
# ---------------------------------------------------------------------------
ASSET_PATTERN='original game|copy of the game|rom|iso|baserom|extract the assets|game files|game data|original disc|retail|legally obtained|dump'
NEEDS_ASSETS=false
ASSET_SIGNALS=""

doc_files=$( {
  find "$DIR" -maxdepth 1 -type f \( -iname 'README*' -o -iname 'BUILD*' -o -iname 'BUILDING*' -o -iname 'INSTALL*' -o -iname 'COMPIL*' \) 2>/dev/null
  find "$DIR/docs" "$DIR/doc" -maxdepth 1 -type f -iname '*.md' 2>/dev/null
} | sort -u || true )

if [ -n "$doc_files" ]; then
  ASSET_SIGNALS=$(printf '%s\n' "$doc_files" \
    | xargs -I{} grep -o -h -i -E "\\b($ASSET_PATTERN)\\b" "{}" 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' | sort -u | head -n 8 || true)
  if [ -n "$ASSET_SIGNALS" ]; then
    NEEDS_ASSETS=true
  fi
fi
log "asset scan: needs_assets=$NEEDS_ASSETS signals=[$(printf '%s' "$ASSET_SIGNALS" | tr '\n' ',')]"

# ---------------------------------------------------------------------------
# 2. Build-system detection (repository root, priority order)
# ---------------------------------------------------------------------------
BUILD_SYSTEM="none"
BUILD_CMD=""
RESULT=""
REASON=""

has_npm_build_script() {
  python3 - "$DIR/package.json" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    scripts = data.get("scripts") or {}
    sys.exit(0 if isinstance(scripts, dict) and "build" in scripts else 1)
except Exception:
    sys.exit(1)
PY
}

if [ -f "$DIR/CMakeLists.txt" ]; then
  BUILD_SYSTEM="cmake"
  BUILD_CMD="cmake -S . -B /tmp/build -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/build -j$JOBS"
elif [ -f "$DIR/meson.build" ]; then
  BUILD_SYSTEM="meson"
  BUILD_CMD="meson setup /tmp/build && meson compile -C /tmp/build -j $JOBS"
elif [ -f "$DIR/Makefile" ] || [ -f "$DIR/GNUmakefile" ] || [ -f "$DIR/makefile" ]; then
  BUILD_SYSTEM="make"
  BUILD_CMD="make -j$JOBS"
elif [ -f "$DIR/Cargo.toml" ]; then
  BUILD_SYSTEM="cargo"
  BUILD_CMD="cargo build --release"
elif [ -f "$DIR/go.mod" ]; then
  BUILD_SYSTEM="go"
  BUILD_CMD="go build ./..."
elif [ -f "$DIR/package.json" ] && has_npm_build_script; then
  BUILD_SYSTEM="npm"
  BUILD_CMD="(npm ci || npm install) && npm run build"
elif [ -f "$DIR/pyproject.toml" ] || [ -f "$DIR/setup.py" ]; then
  BUILD_SYSTEM="python"
  BUILD_CMD="python3 -m venv /tmp/venv && /tmp/venv/bin/python -m pip install --upgrade pip && /tmp/venv/bin/python -m pip install ."
elif ls "$DIR"/build.gradle* "$DIR"/settings.gradle* >/dev/null 2>&1; then
  BUILD_SYSTEM="gradle"
  if [ -f "$DIR/gradlew" ]; then
    BUILD_CMD="chmod +x ./gradlew && ./gradlew assemble --no-daemon"
  elif command -v gradle >/dev/null 2>&1; then
    BUILD_CMD="gradle assemble --no-daemon"
  else
    RESULT="needs_toolchain"; REASON="gradle_wrapper_missing"
  fi
elif [ -n "$(find "$DIR" -maxdepth 3 -type f \( -name '*.sln' -o -name '*.vcxproj' \) 2>/dev/null | head -n 1)" ]; then
  BUILD_SYSTEM="msbuild"
  RESULT="needs_toolchain"; REASON="windows_msbuild"
elif [ -n "$(find "$DIR" -maxdepth 3 -type d -name '*.xcodeproj' 2>/dev/null | head -n 1)" ]; then
  BUILD_SYSTEM="xcode"
  RESULT="needs_toolchain"; REASON="xcode"
else
  BUILD_SYSTEM="none"
  RESULT="no_build_system"; REASON="no_recognized_build_files_in_root"
fi
log "build system: $BUILD_SYSTEM"

# ---------------------------------------------------------------------------
# 3. Common dependencies via apt (best effort, output kept out of the build log)
# ---------------------------------------------------------------------------
if [ -n "$BUILD_CMD" ] && [ "${SKIP_APT:-0}" != "1" ] && command -v apt-get >/dev/null 2>&1; then
  SUDO=""
  if [ "$(id -u)" != "0" ]; then SUDO="sudo -n"; fi
  log "installing common packages with apt (failures ignored)"
  (
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq --no-install-recommends \
      build-essential cmake ninja-build meson pkg-config clang \
      python3-pip python3-venv python3-setuptools \
      libsdl2-dev libsdl2-mixer-dev libsdl2-image-dev libsdl2-ttf-dev libsdl2-net-dev \
      libglew-dev libglfw3-dev libopenal-dev zlib1g-dev libpng-dev libjpeg-dev \
      libgl1-mesa-dev libglu1-mesa-dev libx11-dev libxext-dev libvorbis-dev libogg-dev \
      libfreetype-dev libcapstone-dev
  ) > "$APT_LOG" 2>&1 || log "apt step reported errors (ignored); see $APT_LOG"
fi

# ---------------------------------------------------------------------------
# 4. Build under the remaining time budget
# ---------------------------------------------------------------------------
BUILD_STATUS=""
if [ -n "$BUILD_CMD" ]; then
  elapsed=$(( $(date +%s) - START_TS ))
  budget=$(( BUDGET_MIN * 60 - elapsed - 20 ))
  if [ "$budget" -lt 60 ]; then budget=60; fi
  log "running: $BUILD_CMD (budget ${budget}s, jobs $JOBS)"
  set +e
  if [ -n "$TIMEOUT_BIN" ]; then
    ( cd "$DIR" && "$TIMEOUT_BIN" --kill-after=15s "${budget}s" bash -o pipefail -c "$BUILD_CMD" ) >> "$LOG" 2>&1
  else
    ( cd "$DIR" && bash -o pipefail -c "$BUILD_CMD" ) >> "$LOG" 2>&1
  fi
  BUILD_STATUS=$?
  set -e
  log "build exit status: $BUILD_STATUS"
fi

# ---------------------------------------------------------------------------
# 5. Classify
# ---------------------------------------------------------------------------
classify_failure() {
  # Reads the last 400 lines of the build log and prints one reason token.
  local tail_log
  tail_log=$(tail -n 400 "$LOG" | tr '[:upper:]' '[:lower:]')

  if printf '%s' "$tail_log" | grep -q -E \
      'baserom|\b(rom|iso|game files|game data|original game)\b[^\n]*(not found|missing|could not|cannot find|does not exist|no such file|not present)|(not found|missing|could not find|cannot find|no such file)[^\n]*\b(rom|iso|game files|game data)\b|\.(z64|n64|v64|iso|gcm|wbfs|nds|gba|sfc|smc|nes)\b[^\n]*(not found|no such file|missing|does not exist)|(place|put|copy|provide) (your|the|a) [^\n]*\b(rom|iso|game files|game data)\b'; then
    echo "missing_assets"; return
  fi

  if printf '%s' "$tail_log" | grep -q -E \
      '[a-z0-9_./+-]*(gcc|g\+\+|clang|clang\+\+|\bcc|\bas|\bld|objcopy|armips|ccpsx|psyq|mwcc|mwld|ee-gcc|iop-gcc|arm-none-eabi|devkit|wine|dosbox|ninja|cmake|meson|cargo|rustc|\bgo|javac|gradle|msbuild|xcodebuild)[a-z0-9_./+-]*: (command )?not found|make(\[[0-9]+\])?: [^ :]+: no such file or directory|could not find[^\n]*(mips|psyq|psx|psp|devkitpro|devkitppc|devkitarm|ps2sdk|ps2dev|vitasdk|wiiu|wut|toolchain|cross|compiler|assembler)|(devkitpro|devkitppc|devkitarm|ps2sdk|ps2dev|vitasdk|wut|psyq|psy-q|mwcc|wine)[^\n]*(not (found|set|installed|defined)|is missing|could not|cannot|unable|please install)|cmake_c(xx)?_compiler not set|no cmake_c(xx)?_compiler could be found|the c(xx)? compiler[^\n]*is not able to compile|cannot execute[^\n]*(gcc|g\+\+|clang|cc1|as\b|ld\b)|(unknown|unrecognized|invalid) (target|architecture|command[- ]line option)'; then
    echo "missing_toolchain"; return
  fi

  if printf '%s' "$tail_log" | grep -q -E \
      'could not find a package configuration file|could not find (package|module|library|dependency)|could not find [a-z0-9_+.-]+ \(missing|by not providing "find|no package .[a-z0-9_+.-]+. found|was not found in the pkg-config search path|pkg-config[^\n]*not found|fatal error: [^ ]+\.(h|hpp|hh|hxx|inc): no such file|cannot find -l[a-z0-9_+.-]+|dependency "?[a-z0-9_+.-]+"? not found|dependency lookup for [a-z0-9_+.-]+[^\n]*failed|could not find native static library|failed to run custom build command|modulenotfounderror|no module named|npm err! (code e404|404)|unable to locate package|no matching distribution found'; then
    echo "missing_dependency"; return
  fi

  echo "compile_error"
}

if [ -z "$RESULT" ]; then
  case "$BUILD_STATUS" in
    0)   RESULT="built"; REASON="exit_0" ;;
    124|137) RESULT="timeout"; REASON="build_exceeded_budget" ;;
    *)   RESULT="build_failed"; REASON="$(classify_failure)" ;;
  esac
fi

COMMIT=$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo "")
LAST_COMMIT_DATE=$(git -C "$DIR" log -1 --format=%cI 2>/dev/null || echo "")
DURATION=$(( $(date +%s) - START_TS ))
log "result: $RESULT ($REASON) after ${DURATION}s"

# ---------------------------------------------------------------------------
# 6. Emit JSON (python3 handles all quoting)
# ---------------------------------------------------------------------------
R_BUILD_SYSTEM="$BUILD_SYSTEM" R_NEEDS_ASSETS="$NEEDS_ASSETS" R_ASSET_SIGNALS="$ASSET_SIGNALS" \
R_RESULT="$RESULT" R_REASON="$REASON" R_DURATION="$DURATION" R_COMMIT="$COMMIT" \
R_LAST_COMMIT_DATE="$LAST_COMMIT_DATE" R_BUILD_STATUS="$BUILD_STATUS" R_BUILD_CMD="$BUILD_CMD" \
python3 - <<'PY'
import json, os
e = os.environ
signals = [s for s in e.get("R_ASSET_SIGNALS", "").split("\n") if s.strip()]
status = e.get("R_BUILD_STATUS", "")
print(json.dumps({
    "build_system": e.get("R_BUILD_SYSTEM"),
    "build_command": e.get("R_BUILD_CMD") or None,
    "needs_assets": e.get("R_NEEDS_ASSETS") == "true",
    "asset_signals": signals,
    "result": e.get("R_RESULT"),
    "reason": e.get("R_REASON"),
    "build_exit_status": int(status) if status.isdigit() else None,
    "duration_seconds": int(e.get("R_DURATION", "0")),
    "commit": e.get("R_COMMIT") or None,
    "last_commit_date": e.get("R_LAST_COMMIT_DATE") or None,
}, indent=2))
PY
exit 0
