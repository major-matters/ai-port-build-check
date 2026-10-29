#!/usr/bin/env bash
# Runtime smoke test for a repository the harness has just built.
#
# Finds the executables the build produced, launches the most likely one under a virtual
# X display with no game files present, and records what happened: a window opened,
# the program kept running, it exited cleanly, it exited asking for files, or it crashed.
# Nothing is installed or run from the network; the program runs for at most SMOKE_SECONDS.
#
# Usage: smoke-run.sh <checkout-dir> <clone-marker-file>   (writes JSON to stdout, log to stderr)
set -u
DIR=${1:-/tmp/target}
MARKER=${2:-/tmp/clone.log}
SECONDS_BUDGET=${SMOKE_SECONDS:-45}
WINDOW_WAIT=${SMOKE_WINDOW_WAIT:-20}
LOG=/tmp/smoke.log
: > "$LOG"
log() { printf '[smoke] %s\n' "$*" | tee -a "$LOG" >&2; }

# 1. Candidate executables: ELF files with the execute bit, newer than the clone marker,
#    under the checkout or the out-of-tree build directory. Exclude shared objects, CMake's
#    compiler probes and anything that looks like a test or example.
cands=()
while IFS= read -r f; do
  case "$f" in
    *CMakeFiles/*|*/CompilerId*|*/cmTC_*|*.so|*.so.*|*.o|*.a|*/node_modules/*|*/.git/*) continue ;;
    */target/release/build/*|*/target/debug/build/*|*/target/release/deps/*|*/target/debug/deps/*|*/build-script-build) continue ;;
  esac
  base=$(basename "$f" | tr '[:upper:]' '[:lower:]')
  case "$base" in
    *test*|*tests*|*example*|*bench*|*.sh|*.py|*.pl|*.rb|*.js|conftest|*.cmake) continue ;;
  esac
  if file -b "$f" 2>/dev/null | grep -q "ELF .* executable\|ELF .* shared object" ; then
    # "shared object" also covers PIE executables; drop real libraries by name above.
    if file -b "$f" | grep -q "pie executable\|executable"; then cands+=("$f"); fi
  fi
done < <(find "$DIR" /tmp/build -xdev -type f -perm -u+x -newer "$MARKER" -size +20k 2>/dev/null | sort -u)

printf '%s\n' "${cands[@]:-}" | sed '/^$/d' > /tmp/smoke-candidates.txt
log "candidates: $(wc -l < /tmp/smoke-candidates.txt)"

if [ ! -s /tmp/smoke-candidates.txt ]; then
  python3 -I - <<'PY'
import json; print(json.dumps({"outcome":"no_executable_found","candidates":[],"executable":None}))
PY
  exit 0
fi

# 2. Pick: prefer a name that matches the repository directory or a game-ish word, then the largest.
pick=$(python3 -I - "$DIR" <<'PY'
import os, sys
d = sys.argv[1].rstrip('/')
name = os.path.basename(d).lower()
cands = [l.strip() for l in open('/tmp/smoke-candidates.txt') if l.strip()]
def score(p):
    b = os.path.basename(p).lower()
    s = 0
    if name and (b in name or name in b): s += 100
    for w in ("game", "main", "run", "launch", "play", "recomp", "port", "pc", "linux"):
        if w in b: s += 10
    if "/tmp/build/" in p: s += 5
    try: s += min(os.path.getsize(p) // (256*1024), 20)
    except OSError: pass
    return s
VENDORED = ("/zlib/", "/third_party/", "/thirdparty/", "/vendor/", "/external/", "/extern/", "/deps/", "/dependencies/", "/libs/", "/lib/", "/tools/", "/contrib/", "/subprojects/")
def vendored(p): return any(v in p.lower() for v in VENDORED)
cands.sort(key=lambda p: (vendored(p), -score(p)))
print(cands[0])
PY
)
case "$(printf '%s' "$pick" | tr '[:upper:]' '[:lower:]')" in
  */zlib/*|*/third_party/*|*/thirdparty/*|*/vendor/*|*/external/*|*/extern/*|*/deps/*|*/dependencies/*|*/libs/*|*/lib/*|*/tools/*|*/contrib/*|*/subprojects/*) VENDORED_ONLY=1 ;;
  *) VENDORED_ONLY=0 ;;
esac
export VENDORED_ONLY
log "picked: $pick"

# 3. Run it under Xvfb with dummy audio, from its own directory, for a bounded time.
#    A helper counts X windows after WINDOW_WAIT seconds so a game that opens a window and
#    then waits for input is told apart from one that just sits in a loop.
export SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null PULSE_SERVER=none
cd "$(dirname "$pick")" || true
start=$(date +%s)
cat > /tmp/smoke-inner.sh <<INNER
#!/usr/bin/env bash
"$pick" > /tmp/smoke.stdout 2> /tmp/smoke.stderr &
pid=\$!
sleep $WINDOW_WAIT
if kill -0 \$pid 2>/dev/null; then
  xwininfo -root -tree 2>/dev/null | grep -E '^\s+0x[0-9a-f]+ ' | grep -v 'has no name' | sed -E 's/^\s+0x[0-9a-f]+ //' | head -n 10 > /tmp/smoke.windows || true
  printf 'alive_at_window_check\n' > /tmp/smoke.alive
fi
wait \$pid
echo \$? > /tmp/smoke.exit
INNER
chmod +x /tmp/smoke-inner.sh
: > /tmp/smoke.windows; rm -f /tmp/smoke.alive; : > /tmp/smoke.exit
timeout --kill-after=10s "${SECONDS_BUDGET}s" xvfb-run -a -s "-screen 0 1280x720x24" /tmp/smoke-inner.sh
tstatus=$?
end=$(date +%s)
exitcode=$(cat /tmp/smoke.exit 2>/dev/null | tr -dc '0-9')
[ "$tstatus" = "124" ] || [ "$tstatus" = "137" ] && exitcode="" && timed_out=1 || timed_out=0

# 4. Classify.
python3 -I - "$pick" "$exitcode" "$timed_out" "$((end-start))" <<'PY'
import json, os, re, sys
pick, exitcode, timed_out, alive = sys.argv[1], sys.argv[2], sys.argv[3] == "1", int(sys.argv[4])
def tail(p, n=40):
    try:
        with open(p, errors="replace") as fh: return [l.rstrip("\n") for l in fh.readlines()[-n:]]
    except OSError: return []
out, err = tail("/tmp/smoke.stdout"), tail("/tmp/smoke.stderr")
text = "\n".join(out + err)
windows = [w.strip() for w in tail("/tmp/smoke.windows", 10) if w.strip()]
alive_at_check = os.path.exists("/tmp/smoke.alive")
cands = [l.strip() for l in open("/tmp/smoke-candidates.txt") if l.strip()]
low = text.lower()
asks = re.search(r"\b(rom|iso|bin|baserom|disc|game (data|files?|directory|folder)|assets?|data files?|original (game|files)|not found|no such file|could not (open|find|load|read)|cannot (open|find|load|read)|failed to (open|find|load|read)|missing|unable to (open|find|load|read)|place .* (in|into|next to)|copy .* (in|into|next to)|data_files|--data\b)\b|данные игры|не найден|файл", low)
missing_lib = re.search(r"error while loading shared libraries|could not be loaded|cannot open shared object file|libxkbcommon|\blib[a-z0-9_.-]+\.so[.0-9]*\b.*(not found|could not|cannot)", low)
mentioned = sorted(set(m.group(0) for m in re.finditer(r"[\w./-]+\.(z64|n64|v64|sfc|smc|gba|gb|gbc|nds|iso|bin|cue|img|wad|pak|pk3|rom|dat|big|bsa|arc|exe|dll|so|cfg|ini|json|xml|txt)\b", text, re.I)))[:12]
ec = int(exitcode) if exitcode.isdigit() else None
if timed_out and windows:
    outcome = "window_opened_kept_running"
elif timed_out:
    outcome = "kept_running_no_window"
elif ec == 0 and windows:
    outcome = "window_opened_exited_clean"
elif ec == 0:
    outcome = "exited_clean"
elif ec in (134, 136, 139, 132, 133, 135, 137, 138, 143) or ec is not None and ec > 128:
    outcome = "crashed"
elif missing_lib and ec not in (0,):
    outcome = "missing_runtime_library"
elif (re.search(r"(^|\n)\s*usage:|\busage:\s|--help\b.*(print|show)|print help|(^|\n)\s*\w[\w-]* (?:\w+\|){2,}\w+", low)) and (ec in (1, 2) or ec is None):
    outcome = "printed_usage"
elif asks:
    outcome = "exited_asking_for_files"
else:
    outcome = "exited_with_error"
vendored_only = os.environ.get("VENDORED_ONLY") == "1"
if vendored_only and outcome not in ("crashed",):
    outcome = "vendored_tool_only"
print(json.dumps({
    "outcome": outcome,
    "executable": pick.replace("/tmp/target", "<repo>").replace("/tmp/build", "<build>"),
    "candidates": [c.replace("/tmp/target", "<repo>").replace("/tmp/build", "<build>") for c in cands[:10]],
    "exit_code": ec,
    "timed_out": timed_out,
    "seconds_alive": alive,
    "alive_at_window_check": alive_at_check,
    "windows": windows,
    "asked_for_files": bool(asks),
    "vendored_only": vendored_only,
    "mentioned_files": mentioned,
    "stdout_tail": out[-15:],
    "stderr_tail": err[-15:],
}))
PY
exit 0
