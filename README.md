# ai-port-build-check

A clean-room build check for the open-source game decompilations and ports listed on [reversedwithai.com](https://reversedwithai.com). Each project there reports its own status (Works, Partial, Research). This harness asks one narrow question about each repository: does it build, in a fresh Ubuntu machine, by following the repository's own files?

The answer for every repository becomes a dated public dataset published by [Major Labs](https://majorlabs.co).

## What this measures

One thing: whether a conventional build command, chosen from the files in the repository root, finishes with exit code 0 on a clean `ubuntu-24.04` GitHub-hosted runner within a fixed time budget.

## What this does not measure

- Whether the game runs, renders, or plays. A successful build is a compile and link, nothing more.
- Whether the decompilation is accurate or matching.
- Anything about the quality, effort, or honesty of the project. A failed build here is very often an environment gap on our side (a console SDK that cannot be installed on a stock runner, a Windows-only toolchain, original game data that we never supply). The result vocabulary below keeps those cases separate from compile errors.
- Anything that needs the original game. The harness never downloads, holds, or supplies ROMs, ISOs, or extracted assets. Repositories that need them will show up as `missing_assets` or with `needs_assets: true`, and that is the expected outcome for a decompilation.

Per-repository results are published as a dataset so the method can be checked. No repository is singled out in prose. Aggregates (how many built, how many needed a toolchain, how many needed assets) are the finding.

## Method

1. A batch file under `batches/` lists repositories: `{id, repo, title, platform, outcome}`.
2. For each entry, a fresh runner shallow-clones the repository (with submodules) into `/tmp/target`, with a five-minute limit on the clone.
3. `scripts/detect-and-build.sh` then:
   - scans `README*`, `BUILD*`, `INSTALL*` and `docs/*.md` for phrases that signal original game data is required ("original game", "copy of the game", "rom", "iso", "baserom", "extract the assets", "game files", "retail", "legally obtained", "dump"), and records `needs_assets` and up to eight matched phrases;
   - detects the build system from the repository root, in this priority order: `CMakeLists.txt`, `meson.build`, `Makefile`, `Cargo.toml`, `go.mod`, `package.json` with a `build` script, `pyproject.toml` or `setup.py`, `build.gradle*`, then Visual Studio or Xcode project files;
   - installs a common set of Ubuntu packages (SDL2, GLEW, GLFW, OpenAL, zlib, libpng, ninja, meson, clang, pip, and a few others) without failing the run if that step has problems;
   - runs exactly one build command for the detected system (for example `cmake -S . -B /tmp/build -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/build`, or `make -j$(nproc)`) under the remaining time budget;
   - classifies the result and prints one JSON object.
4. The workflow adds the commit SHA, last commit date, runner image, run id and timestamp, and stores the last 200 lines of build output per repository.
5. A final job merges everything into `results.json` and `summary.md`.

Nothing from the target repository is executed other than the build command. The harness never runs `npm start`, test suites, or any produced binary. The workflow has `contents: read` permission only and uses no secrets. All of this runs on GitHub-hosted runners, never on a personal machine, because the repositories are third-party code.

## Result vocabulary

| result | meaning |
|---|---|
| `built` | the build command exited 0 |
| `build_failed` | the build command exited nonzero; see `reason` |
| `timeout` | the build ran past the budget (default 20 minutes including package install) |
| `no_build_system` | no recognized build files in the repository root |
| `needs_toolchain` | a build system was found that a stock Ubuntu runner cannot drive (`windows_msbuild`, `xcode`, `gradle_wrapper_missing`) |
| `clone_failed` | the repository could not be cloned within five minutes |
| `harness_error` | the harness itself failed to produce a result; treat as unknown |

For `build_failed`, `reason` is mined from the last 400 lines of the log:

| reason | signal |
|---|---|
| `missing_assets` | the log mentions a baserom, ROM, ISO or game files that were not found |
| `missing_toolchain` | a compiler, assembler or console SDK (mips, psyq, devkitPro, ps2sdk, vitasdk, wut, and so on) was not found |
| `missing_dependency` | CMake, pkg-config, meson, cargo, pip or npm could not find a library or package |
| `compile_error` | none of the above matched; the code or its build files failed on their own terms |

The classification is heuristic. The log tail is kept next to every result so anyone can check the call.

## Fields in each result

`id`, `repo`, `title`, `platform`, `outcome_reported`, `commit`, `last_commit_date`, `build_system`, `needs_assets`, `asset_signals`, `result`, `reason`, `duration_seconds`, `runner_image`, `run_id`, `checked_at`.

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

Only the pure-logic parts are meant to run on a laptop: `scripts/make-batches.py` and syntax checks. Do not clone or build target repositories locally. The point of the harness is that third-party code runs on a disposable machine.

## License

Harness code: MIT. Results datasets: CC BY 4.0.
