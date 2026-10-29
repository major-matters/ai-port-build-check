# ai-port-build-check

A clean-room build check for the open-source game decompilations and ports listed on [reversedwithai.com](https://reversedwithai.com). Each project there reports its own status (Works, Partial, Research). This harness asks one narrow question about each repository: does it build, in a fresh Ubuntu machine, by following the repository's own files?

The answer for every repository becomes a dated public dataset published by [Major Labs](https://majorlabs.co).

## What this measures

One thing: whether a conventional build command, chosen from the build files in the repository (the root first, then up to three directory levels below it), finishes with exit code 0 on a clean `ubuntu-24.04` GitHub-hosted runner within a fixed time budget.

## What this does not measure

- Whether the game runs, renders, or plays. A successful build is a compile and link, nothing more.
- Whether the decompilation is accurate or matching.
- Anything about the quality, effort, or honesty of the project. A failed build here is very often an environment gap on our side (a console SDK that cannot be installed on a stock runner, a Windows-only toolchain, original game data that we never supply). The result vocabulary below keeps those cases separate from compile errors.
- Anything that needs the original game. The harness never downloads, holds, or supplies ROMs, ISOs, or extracted assets. Repositories that need them will show up as `missing_assets` or with `needs_assets: true`, and that is the expected outcome for a decompilation.

Per-repository results are published as a dataset so the method can be checked. No repository is singled out in prose. Aggregates (how many built, how many needed a toolchain, how many needed assets) are the finding.

## Method

1. A batch file under `batches/` lists repositories: `{id, repo, title, platform, outcome}`.
2. For each entry, a fresh runner checks that the repository still exists (`git ls-remote` plus the HTTP status), then shallow-clones it with submodules into `/tmp/target`, with a five-minute limit on the clone. Submodule URLs that use SSH (`git@github.com:`) are rewritten to HTTPS, because a runner holds no SSH key. If the recursive clone still fails, the harness falls back to a plain clone without submodules and records `submodules: "failed"`.
3. The runner installs a common set of Ubuntu packages (listed in `scripts/apt-packages.txt`: SDL2 and its satellite libraries, GLEW, GLFW, OpenAL, Vulkan, X11 and Wayland headers, audio, image and compression libraries, clang, lld, nasm, meson, ninja and more). This step is best effort, never fails the run, and happens before the build timer starts.
4. `scripts/detect-and-build.sh` then:
   - searches for build files from the root down to three directory levels, skipping `third_party`, `vendor`, `external`, `deps`, `node_modules`, `.git`, `test(s)`, `example(s)` and `doc(s)`. It picks the shallowest directory that has one; among files in the same directory it prefers `CMakeLists.txt`, then `meson.build`, `Makefile`, `Cargo.toml`, `go.mod`, `package.json` (only with a `build` script), `pyproject.toml` or `setup.py`, `build.gradle*`, `build.sh`, `build.zig`. The chosen directory is recorded as `build_dir`;
   - scans `README*`, `BUILD*`, `INSTALL*` and `docs/*.md` (at the root and in the chosen directory) for phrases that signal original game data is required, and records `needs_assets` and up to eight matched phrases;
   - records the first 40 entries of the chosen directory (`root_files`) and whether a README exists (`readme_present`), so a result can be audited without re-cloning;
   - runs one build command for the detected system (for example `cmake -S . -B /tmp/build -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/build`, `make -j$(nproc)`, or `bash build.sh`) under the time budget;
   - retries at most twice, and only when the log asks for it: if a configure step cannot find SDL3 (not packaged on Ubuntu 24.04), it builds SDL 3.2.x from the official release tarball into `/usr/local` and runs the build again; if the log says the project requires Clang, it runs the build again with `CC=clang CXX=clang++`. Each retry is recorded in `retries`;
   - classifies the result with `scripts/classify.py`, whose regexes live in `scripts/reason-patterns.json`, and prints one JSON object.
5. The workflow adds the commit SHA, last commit date, runner image, run id and timestamp, and stores the last 200 lines of build output per repository.
6. A final job merges everything into `results.json` and `summary.md`.

Nothing from the target repository is executed other than the build command. When a repository's only build entry is a `build.sh`, that script is the build command and it runs as-is. The harness never runs `npm start`, test suites, or any produced binary. The workflow has `contents: read` permission only and uses no secrets. All of this runs on GitHub-hosted runners, never on a personal machine, because the repositories are third-party code.

## Result vocabulary

Every result carries `schema_version: 2`.

| result | meaning |
|---|---|
| `built` | the build command exited 0 |
| `static_web` | no build files, but an `index.html` at the root or in `web/`, `public/` or `dist/`; nothing to build, so it counts as reproducible (`reason: no_build_step_needed`) |
| `build_failed` | the build command exited nonzero; see `reason` and `reason_detail` |
| `timeout` | the build ran past the budget (default 20 minutes, packages not included) |
| `no_build_system` | no recognized build files anywhere down to three directory levels. `reason` is `notes_only` (fewer than three source files by extension) or `sources_without_build_files` |
| `needs_toolchain` | a build system was found that a stock Ubuntu runner cannot drive: `windows_msbuild` (`.sln`/`.vcxproj`), `windows_script` (`build.bat`, `build.ps1` or `.cmd` only), `xcode`, `premake_or_scons`, `zig_not_installed`, `android_gradle` (an Android project without a Gradle wrapper), `gradle_wrapper_missing` |
| `clone_failed` | the repository could not be cloned: `repo_gone` (HTTP 404, 410 or 451), `clone_timeout`, or `git_exit_N` |
| `harness_error` | the harness itself failed to produce a result; treat as unknown |

For `build_failed`, `reason` is mined from the whole build log with the harness's own lines removed, using the regexes in `scripts/reason-patterns.json` in this priority order. The matched phrase is kept in `reason_detail` (at most 160 characters) and the apparent missing things in `missing_names` (at most six).

| reason | signal |
|---|---|
| `missing_assets` | a baserom, original game, game files, generated or recompiled game code, a regen step, or a `.bin`/`.rom`/`.iso`/`.img`/`.exe`/`.elf`/`.xex`/`.dol` input that is not there |
| `missing_toolchain` | a console SDK (devkitPro, Psy-Q, ps2sdk, vitasdk, wut, ReXGlue), a cross compiler (mips, powerpc-eabi, arm-none-eabi), MSVC or Visual Studio, Direct3D headers, zig, emscripten, CUDA, a linker or command that is not installed, or a message that the project targets Windows or requires Clang |
| `missing_dependency` | CMake, pkg-config or meson could not find a package, a header is missing, a subdirectory or source file the build files point at does not exist |
| `compile_error` | a compiler, rustc, MSVC or linker error line |
| `hardcoded_path` | the build writes to a path from the author's machine (for example a home directory that does not exist on the runner) |
| `unclassified` | none of the above matched; read the log |

The classification is heuristic. The log tail is kept next to every result so anyone can check the call, and `scripts/reclassify.py` re-runs the classifier over an existing `results.json` and its logs to show what a pattern change would do.

## Smoke run (optional runtime step)

With the `smoke` input set to `1`, a repository that builds is also launched. The harness finds the executables the build produced (ELF files newer than the clone, not libraries, tests or CMake probes), picks the most likely one (name matches the repository, then size), and runs it from its own directory under a virtual X display with dummy audio and no game files present, for at most 45 seconds. After 20 seconds it lists the X windows. The result is a `smoke` object on the row:

| outcome | meaning |
|---|---|
| `window_opened_kept_running` | a window was open at the 20-second check and the program was still running when the budget ended |
| `window_opened_exited_clean` | a window was seen, then the program exited with code 0 |
| `kept_running_no_window` | still running at the budget with no X window (a console program, or one waiting on something) |
| `exited_clean` | exit code 0 before the budget, no window |
| `exited_asking_for_files` | non-zero exit and the output names a ROM, disc image, asset or data file it could not find |
| `printed_usage` | the program is a command-line tool: it printed a usage screen and exited (a converter or extractor, not a game) |
| `vendored_tool_only` | the only executables the build produced live in a vendored or third-party directory (for example a bundled zlib), so the build compiled a dependency, not the project |
| `exited_with_error` | non-zero exit with no such message |
| `crashed` | killed by a signal (segmentation fault, abort, and the like) |
| `no_executable_found` | the build produced nothing launchable (a library, a Python package, a web app, or a make target that did nothing) |
| `not_built` | the build did not succeed on this run, so nothing was launched |

The object also carries the chosen executable (paths shortened to `<repo>` and `<build>`), the candidate count, exit code, whether the budget ran out, seconds alive, the window titles, whether the output asked for files, the file names it mentioned, and the last lines of stdout and stderr. `scripts/export-smoke.py` turns a smoke run into a dataset; it puts Python packages and web apps in a `no_native_program` bucket rather than counting them as failures.

What this proves: whether the program starts and what it does before a player adds their own copy of the game. What it does not prove: that the game is playable, that it runs on a desktop with a GPU, or anything about the files a player would have to supply.

## Fields in each result

`schema_version`, `id`, `repo`, `title`, `platform`, `outcome_reported`, `commit`, `last_commit_date`, `submodules` (`ok`, `failed` or `none`), `build_system`, `build_dir`, `build_command`, `root_files`, `readme_present`, `needs_assets`, `asset_signals`, `result`, `reason`, `reason_detail`, `missing_names`, `retries`, `duration_seconds`, `runner_image`, `run_id`, `checked_at`.

## Limitations

- A build file three levels down is found; one deeper is not. Build files under `vendor`, `third_party`, `tests` and similar directories are ignored on purpose.
- The shallowest directory wins. A root `build.sh` is chosen over a `src/CMakeLists.txt`, on the theory that the repository's own script knows how to drive its own tree.
- Only Ubuntu packages and SDL3 from source are supplied. Anything else a project needs (a console SDK, a Windows toolchain, Metal, the original game) shows up as `needs_toolchain`, `missing_toolchain` or `missing_assets`, which is the expected result for most decompilations.
- Retries are limited to the two cases above (SDL3, Clang). A project that needs a different compiler version, a nightly Rust, or a specific Python is reported as it failed, not fixed.
- The reason regexes are word lists. They over-match now and then (a stray "retail" or "wasm" in a log) and under-match when the real error scrolled past the 200-line tail, which lands in `unclassified`. After a run, `scripts/apply-reclassify.py` re-applies the current patterns to the kept log tails and writes `results-final.json`; it only ever replaces `unclassified` or `compile_error` with a more specific reason, never the other way, and each changed row carries `reason_source` and `reason_runner` so the change is visible.
- `needs_assets` comes from a phrase scan of the README and build docs and over-matches short words like "rom" and "iso"; `scripts/analyze.py` counts only the strict phrases.
- Nothing here says whether the built program runs, renders, or matches the original.

## How to run it

1. Put the project list in `data/projects.json` (array of `{slug, title, platform, outcome, model, repos}`). A three-entry `data/projects.sample.json` is included with two controls: a library expected to build (`fmt`) and a decompilation expected to need a ROM (`sm64`).
2. Generate batches:

   ```
   python3 scripts/make-batches.py                                   # from data/projects.json
   python3 scripts/make-batches.py --input data/projects.sample.json # from the sample
   ```

   This writes `batches/works.json`, `partial.json`, `research.json`, `all.json`, `no-repo.json` (and `control.json` when controls exist). Commit the batch files.

3. Dispatch the workflow:

   ```
   gh workflow run build-check.yml -f batch=all.json -f timeout_minutes=20
   gh run list --workflow build-check.yml --limit 1
   gh run download <run-id> -n results -D results/
   ```

   `results/results.json` is the dataset for that run; `results/summary.md` is the table; `results/logs/` holds the log tails.

GitHub matrices allow 256 jobs per run, so a batch larger than that must be split. Runs use `max-parallel: 20`.

## Local use

Only the pure-logic parts are meant to run on a laptop:

```
bash -n scripts/detect-and-build.sh                                  # syntax check
python3 -I scripts/reclassify.py results/works/results.json --show   # classifier before/after on existing logs
python3 scripts/analyze.py results/works/results.json                # tallies, reason_detail, static_web, submodules
python3 scripts/make-batches.py
```

Do not clone or build target repositories locally. The point of the harness is that third-party code runs on a disposable machine.

## License

Harness code: MIT. Results datasets: CC BY 4.0.
