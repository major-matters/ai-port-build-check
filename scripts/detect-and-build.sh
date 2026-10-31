#!/usr/bin/env bash
# detect-and-build.sh <dir>            probe one checked-out repository, print one JSON object
# detect-and-build.sh --install-packages   install scripts/apt-packages.txt (best effort), nothing else
#
# Clean-room build probe for one checked-out repository. Meant to run on a
# disposable GitHub-hosted Ubuntu runner. It:
#   1. scans README/BUILD/docs files for signs that original game data is needed
#   2. finds build files up to three directory levels below the root and picks one directory
#   3. runs ONE conventional build command there under a time budget, with at most two
#      targeted retries (SDL3 built from source, or CC=clang) when the log asks for them
#   4. classifies the outcome with scripts/classify.py (regexes in scripts/reason-patterns.json)
#   5. prints a single JSON object (schema_version 2) to stdout
#
# Package installation is NOT part of the budget: the workflow runs
# `--install-packages` as its own step before this script starts, and the
# in-script fallback (when SKIP_APT is unset) also runs before the timer starts.
#
# Build output goes to $BUILD_LOG (default /tmp/build.log). Nothing from the
# target repository is executed except the chosen build command (which, for a
# repository whose only build entry is build.sh, is that script).
#
# Environment:
#   BUILD_TIMEOUT_MINUTES  budget for the build and its retries (default 20)
#   BUILD_LOG              build log path (default /tmp/build.log)
#   SKIP_APT               set to 1 to skip the in-script apt step
#   SDL3_VERSION           SDL 3.2.x release to build when a configure asks for SDL3 (default 3.2.30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${BUILD_LOG:-/tmp/build.log}"
APT_LOG="${APT_LOG:-/tmp/apt.log}"
SDL3_LOG="${SDL3_LOG:-/tmp/sdl3.log}"

export CI=true
export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0
export NPM_CONFIG_FUND=false
export NPM_CONFIG_AUDIT=false
export NPM_CONFIG_PROGRESS=false
export CARGO_TERM_COLOR=never
export GRADLE_OPTS="-Dorg.gradle.daemon=false"

SUDO=""
if [ "$(id -u)" != "0" ]; then SUDO="sudo -n"; fi

log() { printf '[harness] %s\n' "$*" | tee -a "$LOG" >&2; }

# ---------------------------------------------------------------------------
# 0. Package installation (best effort, never fatal, never inside the budget)
# ---------------------------------------------------------------------------
install_packages() {
  command -v apt-get >/dev/null 2>&1 || { echo "apt-get not available; skipping" >&2; return 0; }
  local pkgs
  pkgs=$(grep -v -E '^\s*(#|$)' "$SCRIPT_DIR/apt-packages.txt" | tr '\n' ' ')
  (
    $SUDO apt-get update -qq
    # shellcheck disable=SC2086
    $SUDO apt-get install -y -qq --no-install-recommends $pkgs
  ) > "$APT_LOG" 2>&1 || echo "apt step reported errors (ignored); see $APT_LOG" >&2
  return 0
}

if [ "${1:-}" = "--install-packages" ]; then
  install_packages
  exit 0
fi

if [ -z "${1:-}" ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "usage: $0 <checked-out-repository-dir> | --install-packages" >&2
  exit 2
fi

# Everything below runs a third-party repository's build system. That only ever happens on a
# disposable GitHub-hosted runner (SECURITY.md); a developer machine is refused outright.
# (`bash -n` for a syntax check, `--help` and `--install-packages` never reach this line.)
if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "detect-and-build.sh: refusing to run outside GitHub Actions (GITHUB_ACTIONS is not \"true\"); this script runs untrusted third-party build systems" >&2
  exit 2
fi

DIR="${1:-}"
if [ ! -d "$DIR" ]; then
  echo "usage: $0 <checked-out-repository-dir> | --install-packages" >&2
  exit 2
fi
DIR="$(cd "$DIR" && pwd)"
: > "$LOG"

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

if [ "${SKIP_APT:-0}" != "1" ]; then
  log "installing common packages with apt (failures ignored, outside the budget)"
  install_packages
fi

# ---------------------------------------------------------------------------
# 1. Build-file search (up to three directory levels below the root)
# ---------------------------------------------------------------------------
# Directories never searched: vendored code, tests, examples and docs.
PRUNE=( -type d \( -name third_party -o -name vendor -o -name external -o -name deps -o -name node_modules \
        -o -name .git -o -name test -o -name tests -o -name example -o -name examples -o -name doc -o -name docs \) -prune )

find_files() {
  # find_files <name-test>... : print files matching the name tests, pruned, up to depth 4 (3 dirs down)
  find "$DIR" -mindepth 1 -maxdepth 4 \( "${PRUNE[@]}" \) -o -type f \( "$@" \) -print 2>/dev/null
}

has_npm_build_script() {
  python3 -I - "$1" <<'PY' 2>/dev/null
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

rel_of() { printf '%s' "${1#"$DIR"/}"; }
depth_of() { local r; r=$(rel_of "$1"); printf '%s' "$r" | awk -F/ '{print NF}'; }

ZIG_OK=0
if command -v zig >/dev/null 2>&1; then ZIG_OK=1; fi

# Rank: lower wins inside one directory depth. Secondary files (build.sh, build.zig) come last.
rank_of() {
  case "$1" in
    CMakeLists.txt) echo 1 ;;
    meson.build) echo 2 ;;
    Makefile|GNUmakefile|makefile) echo 3 ;;
    Cargo.toml) echo 4 ;;
    go.mod) echo 5 ;;
    package.json) echo 6 ;;
    pyproject.toml|setup.py) echo 7 ;;
    build.gradle|build.gradle.kts|settings.gradle|settings.gradle.kts) echo 8 ;;
    build.sh) echo 9 ;;
    build.zig) echo 10 ;;
    *) echo 99 ;;
  esac
}

CANDIDATES=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  name=$(basename "$f")
  rel=$(rel_of "$f")
  case "$name" in
    package.json) has_npm_build_script "$f" || continue ;;
    build.sh) case "/$rel" in */tools/*|*/test/*|*/tests/*) continue ;; esac ;;
    build.zig) [ "$ZIG_OK" = "1" ] || continue ;;
  esac
  CANDIDATES+="$(depth_of "$f") $(rank_of "$name") $rel"$'\n'
done < <(find_files -name CMakeLists.txt -o -name meson.build -o -name Makefile -o -name GNUmakefile -o -name makefile \
           -o -name Cargo.toml -o -name go.mod -o -name package.json -o -name pyproject.toml -o -name setup.py \
           -o -name 'build.gradle*' -o -name 'settings.gradle*' -o -name build.sh -o -name build.zig)

CHOSEN=""
if [ -n "$CANDIDATES" ]; then
  CHOSEN=$(printf '%s' "$CANDIDATES" | sort -k1,1n -k2,2n -k3,3 | head -n 1)
fi

BUILD_SYSTEM="none"
BUILD_DIR="."
BUILD_CMD=""
RESULT=""
REASON=""

count_sources() {
  # Source files by extension across the tree (vendored dirs and .git excluded).
  find "$DIR" \( -type d \( -name .git -o -name node_modules \) -prune \) -o -type f \( \
    -iname '*.c' -o -iname '*.cpp' -o -iname '*.cc' -o -iname '*.h' -o -iname '*.hpp' -o -iname '*.rs' \
    -o -iname '*.go' -o -iname '*.js' -o -iname '*.ts' -o -iname '*.py' -o -iname '*.cs' -o -iname '*.asm' -o -iname '*.s' \
    \) -print 2>/dev/null | head -n 1000 | wc -l | tr -d ' '
}

if [ -n "$CHOSEN" ]; then
  rel=$(printf '%s' "$CHOSEN" | cut -d' ' -f3-)
  name=$(basename "$rel")
  BUILD_DIR=$(dirname "$rel")
  case "$name" in
    CMakeLists.txt)
      BUILD_SYSTEM="cmake"
      BUILD_CMD="cmake -S . -B /tmp/build -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/build -j$JOBS" ;;
    meson.build)
      BUILD_SYSTEM="meson"
      BUILD_CMD="meson setup /tmp/build && meson compile -C /tmp/build -j $JOBS" ;;
    Makefile|GNUmakefile|makefile)
      BUILD_SYSTEM="make"
      BUILD_CMD="make -j$JOBS" ;;
    Cargo.toml)
      BUILD_SYSTEM="cargo"
      BUILD_CMD="cargo build --release" ;;
    go.mod)
      BUILD_SYSTEM="go"
      BUILD_CMD="go build ./..." ;;
    package.json)
      BUILD_SYSTEM="npm"
      BUILD_CMD="(npm ci || npm install) && npm run build" ;;
    pyproject.toml|setup.py)
      BUILD_SYSTEM="python"
      BUILD_CMD="python3 -m venv /tmp/venv && /tmp/venv/bin/python -m pip install --upgrade pip && /tmp/venv/bin/python -m pip install ." ;;
    build.gradle|build.gradle.kts|settings.gradle|settings.gradle.kts)
      BUILD_SYSTEM="gradle"
      # Wrapper: in the chosen directory or any ancestor up to the root. Run it from where it lives.
      wrapper_dir=""
      d="$BUILD_DIR"
      while :; do
        if [ -f "$DIR/$d/gradlew" ]; then wrapper_dir="$d"; break; fi
        [ "$d" = "." ] && break
        d=$(dirname "$d")
      done
      android=0
      if [ -n "$(find "$DIR/$BUILD_DIR" -maxdepth 4 -name AndroidManifest.xml -print 2>/dev/null | head -n 1)" ] \
         || grep -q -s -l 'com\.android' "$DIR/$BUILD_DIR"/build.gradle* "$DIR/$BUILD_DIR"/settings.gradle* "$DIR/$BUILD_DIR"/app/build.gradle* 2>/dev/null \
         || [[ "/$BUILD_DIR/" == *"/android/"* ]]; then
        android=1
      fi
      if [ -n "$wrapper_dir" ]; then
        BUILD_DIR="$wrapper_dir"
        BUILD_CMD="chmod +x ./gradlew && ./gradlew assemble --no-daemon"
      elif [ "$android" = "1" ]; then
        RESULT="needs_toolchain"; REASON="android_gradle"
      elif command -v gradle >/dev/null 2>&1; then
        BUILD_CMD="gradle assemble --no-daemon"
      else
        RESULT="needs_toolchain"; REASON="gradle_wrapper_missing"
      fi ;;
    build.sh)
      BUILD_SYSTEM="build_sh"
      BUILD_CMD="bash build.sh" ;;
    build.zig)
      BUILD_SYSTEM="zig"
      BUILD_CMD="zig build" ;;
  esac
else
  # No buildable candidate. Say what is there instead, most specific first.
  if [ -n "$(find_files -name build.zig | head -n 1)" ]; then
    BUILD_SYSTEM="zig"; BUILD_DIR=$(dirname "$(rel_of "$(find_files -name build.zig | sort | head -n 1)")")
    RESULT="needs_toolchain"; REASON="zig_not_installed"
  elif [ -n "$(find_files -name premake5.lua -o -name SConstruct | head -n 1)" ]; then
    BUILD_SYSTEM="premake_or_scons"; BUILD_DIR=$(dirname "$(rel_of "$(find_files -name premake5.lua -o -name SConstruct | sort | head -n 1)")")
    RESULT="needs_toolchain"; REASON="premake_or_scons"
  elif [ -n "$(find_files -name '*.sln' -o -name '*.vcxproj' | head -n 1)" ]; then
    BUILD_SYSTEM="msbuild"; BUILD_DIR=$(dirname "$(rel_of "$(find_files -name '*.sln' -o -name '*.vcxproj' | sort | head -n 1)")")
    RESULT="needs_toolchain"; REASON="windows_msbuild"
  elif [ -n "$(find "$DIR" -mindepth 1 -maxdepth 4 \( "${PRUNE[@]}" \) -o -type d -name '*.xcodeproj' -print 2>/dev/null | head -n 1)" ]; then
    BUILD_SYSTEM="xcode"; BUILD_DIR=$(dirname "$(rel_of "$(find "$DIR" -mindepth 1 -maxdepth 4 \( "${PRUNE[@]}" \) -o -type d -name '*.xcodeproj' -print 2>/dev/null | sort | head -n 1)")")
    RESULT="needs_toolchain"; REASON="xcode"
  elif [ -n "$(find_files -name build.bat -o -name build.ps1 -o -name '*.cmd' | head -n 1)" ]; then
    BUILD_SYSTEM="windows_script"; BUILD_DIR=$(dirname "$(rel_of "$(find_files -name build.bat -o -name build.ps1 -o -name '*.cmd' | sort | head -n 1)")")
    RESULT="needs_toolchain"; REASON="windows_script"
  elif [ -f "$DIR/index.html" ] || [ -f "$DIR/web/index.html" ] || [ -f "$DIR/public/index.html" ] || [ -f "$DIR/dist/index.html" ]; then
    BUILD_SYSTEM="none"
    for d in . web public dist; do [ -f "$DIR/$d/index.html" ] && { BUILD_DIR="$d"; break; }; done
    RESULT="static_web"; REASON="no_build_step_needed"
  else
    BUILD_SYSTEM="none"
    if [ "$(count_sources)" -lt 3 ]; then
      RESULT="no_build_system"; REASON="notes_only"
    else
      RESULT="no_build_system"; REASON="sources_without_build_files"
    fi
  fi
fi
BUILD_PATH="$DIR/$BUILD_DIR"
log "build system: $BUILD_SYSTEM in $BUILD_DIR"

ROOT_FILES=$(ls -A1 "$BUILD_PATH" 2>/dev/null | head -n 40 || true)
README_PRESENT=false
if [ -n "$(find "$DIR" "$BUILD_PATH" -maxdepth 1 -type f -iname 'README*' 2>/dev/null | head -n 1)" ]; then
  README_PRESENT=true
fi

# ---------------------------------------------------------------------------
# 2. Asset scan (root docs plus the chosen directory's docs)
# ---------------------------------------------------------------------------
ASSET_PATTERN='original game|copy of the game|rom|iso|baserom|extract the assets|game files|game data|original disc|retail|legally obtained|dump'
NEEDS_ASSETS=false
ASSET_SIGNALS=""

doc_files=$( {
  find "$DIR" "$BUILD_PATH" -maxdepth 1 -type f \( -iname 'README*' -o -iname 'BUILD*' -o -iname 'BUILDING*' -o -iname 'INSTALL*' -o -iname 'COMPIL*' \) 2>/dev/null
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
# 3. Build under the time budget (the timer starts here)
# ---------------------------------------------------------------------------
START_TS=$(date +%s)
BUDGET_MIN="${BUILD_TIMEOUT_MINUTES:-20}"
BUILD_STATUS=""
RETRIES=""

remaining_budget() {
  local elapsed budget
  elapsed=$(( $(date +%s) - START_TS ))
  budget=$(( BUDGET_MIN * 60 - elapsed - 20 ))
  if [ "$budget" -lt 60 ]; then budget=60; fi
  printf '%s' "$budget"
}

run_build() {
  # run_build [VAR=value ...] : run $BUILD_CMD in $BUILD_PATH with the given env, output appended to $LOG
  local budget status
  budget=$(remaining_budget)
  log "running: $BUILD_CMD (dir $BUILD_DIR, budget ${budget}s, jobs $JOBS${*:+, env $*})"
  # Callers wrap this in set +e / set -e; nothing here may toggle errexit.
  if [ -n "$TIMEOUT_BIN" ]; then
    ( cd "$BUILD_PATH" && env "$@" "$TIMEOUT_BIN" --kill-after=15s "${budget}s" bash -o pipefail -c "$BUILD_CMD" ) >> "$LOG" 2>&1
  else
    ( cd "$BUILD_PATH" && env "$@" bash -o pipefail -c "$BUILD_CMD" ) >> "$LOG" 2>&1
  fi
  status=$?
  log "build exit status: $status"
  return $status
}

log_trigger() { python3 -I "$SCRIPT_DIR/classify.py" --log "$LOG" --trigger "$1"; }

install_sdl3() {
  # Build SDL 3.2.x from the official GitHub release tarball into /usr/local (no tests, no examples).
  local v="${SDL3_VERSION:-3.2.30}" url budget
  url="https://github.com/libsdl-org/SDL/releases/download/release-$v/SDL3-$v.tar.gz"
  budget=$(remaining_budget)
  if [ "$budget" -gt 600 ]; then budget=600; fi
  log "building SDL3 $v from $url (budget ${budget}s); output in $SDL3_LOG"
  local steps
  steps="set -e
rm -rf /tmp/sdl3 && mkdir -p /tmp/sdl3 && cd /tmp/sdl3
curl -fsSL --retry 3 -o sdl3.tar.gz '$url'
tar xzf sdl3.tar.gz
cmake -S 'SDL3-$v' -B build -DCMAKE_BUILD_TYPE=Release -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF -DCMAKE_INSTALL_PREFIX=/usr/local
cmake --build build -j$JOBS
$SUDO cmake --install build
$SUDO ldconfig"
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" --kill-after=15s "${budget}s" bash -c "$steps" > "$SDL3_LOG" 2>&1
  else
    bash -c "$steps" > "$SDL3_LOG" 2>&1
  fi
}

reset_build_tree() {
  case "$BUILD_SYSTEM" in cmake|meson) rm -rf /tmp/build ;; esac
}

if [ -n "$BUILD_CMD" ]; then
  set +e
  run_build; BUILD_STATUS=$?
  set -e

  if [ "$BUILD_STATUS" != "0" ] && [ "$BUILD_STATUS" != "124" ] && [ "$BUILD_STATUS" != "137" ] && log_trigger sdl3; then
    RETRIES+="sdl3"$'\n'
    if install_sdl3; then log "SDL3 installed"; else log "SDL3 build failed (see $SDL3_LOG); retrying anyway"; fi
    log "retry: sdl3"
    reset_build_tree
    set +e
    run_build; BUILD_STATUS=$?
    set -e
  fi

  if [ "$BUILD_STATUS" != "0" ] && [ "$BUILD_STATUS" != "124" ] && [ "$BUILD_STATUS" != "137" ] && log_trigger clang; then
    RETRIES+="clang"$'\n'
    log "retry: clang"
    reset_build_tree
    set +e
    run_build CC=clang CXX=clang++; BUILD_STATUS=$?
    set -e
  fi
fi

# ---------------------------------------------------------------------------
# 4. Classify
# ---------------------------------------------------------------------------
REASON_DETAIL=""
MISSING_NAMES=""
if [ -z "$RESULT" ]; then
  case "$BUILD_STATUS" in
    0)   RESULT="built"; REASON="exit_0" ;;
    124|137) RESULT="timeout"; REASON="build_exceeded_budget" ;;
    *)
      RESULT="build_failed"
      CLASS_JSON=$(python3 -I "$SCRIPT_DIR/classify.py" --log "$LOG" 2>/dev/null || echo '{}')
      REASON=$(printf '%s' "$CLASS_JSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("reason") or "unclassified")')
      REASON_DETAIL=$(printf '%s' "$CLASS_JSON" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("reason_detail") or "")')
      MISSING_NAMES=$(printf '%s' "$CLASS_JSON" | python3 -I -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("missing_names") or []))')
      ;;
  esac
fi

COMMIT=$(git -C "$DIR" rev-parse HEAD 2>/dev/null || echo "")
LAST_COMMIT_DATE=$(git -C "$DIR" log -1 --format=%cI 2>/dev/null || echo "")
DURATION=$(( $(date +%s) - START_TS ))
log "result: $RESULT ($REASON) after ${DURATION}s"

# ---------------------------------------------------------------------------
# 5. Emit JSON (python3 handles all quoting)
# ---------------------------------------------------------------------------
R_BUILD_SYSTEM="$BUILD_SYSTEM" R_BUILD_DIR="$BUILD_DIR" R_NEEDS_ASSETS="$NEEDS_ASSETS" R_ASSET_SIGNALS="$ASSET_SIGNALS" \
R_RESULT="$RESULT" R_REASON="$REASON" R_REASON_DETAIL="$REASON_DETAIL" R_MISSING_NAMES="$MISSING_NAMES" \
R_RETRIES="$RETRIES" R_ROOT_FILES="$ROOT_FILES" R_README_PRESENT="$README_PRESENT" \
R_DURATION="$DURATION" R_COMMIT="$COMMIT" R_LAST_COMMIT_DATE="$LAST_COMMIT_DATE" \
R_BUILD_STATUS="$BUILD_STATUS" R_BUILD_CMD="$BUILD_CMD" \
python3 -I - <<'PY'
import json, os
e = os.environ
def lines(key): return [s for s in e.get(key, "").split("\n") if s.strip()]
status = e.get("R_BUILD_STATUS", "")
print(json.dumps({
    "schema_version": 2,
    "build_system": e.get("R_BUILD_SYSTEM"),
    "build_dir": e.get("R_BUILD_DIR") or ".",
    "build_command": e.get("R_BUILD_CMD") or None,
    "root_files": lines("R_ROOT_FILES")[:40],
    "readme_present": e.get("R_README_PRESENT") == "true",
    "needs_assets": e.get("R_NEEDS_ASSETS") == "true",
    "asset_signals": lines("R_ASSET_SIGNALS"),
    "result": e.get("R_RESULT"),
    "reason": e.get("R_REASON"),
    "reason_detail": (e.get("R_REASON_DETAIL") or None),
    "missing_names": lines("R_MISSING_NAMES")[:6],
    "retries": lines("R_RETRIES"),
    "build_exit_status": int(status) if status.isdigit() else None,
    "duration_seconds": int(e.get("R_DURATION", "0")),
    "commit": e.get("R_COMMIT") or None,
    "last_commit_date": e.get("R_LAST_COMMIT_DATE") or None,
}, indent=2))
PY
exit 0
