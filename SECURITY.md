# Security

This repository is a clean-room build check for games rebuilt with coding agents. It clones third-party repositories and runs their build systems, so it treats every repository it touches as untrusted.

- **GitHub-hosted runners only.** Builds and smoke launches run inside GitHub Actions on fresh virtual machines that are discarded after the job. There is no script here for running a batch on a developer machine, and none should be added.
- **No game files.** The harness never supplies, downloads or stores a ROM, disc image, BIOS or any publisher asset. Projects that need one record the request and stop.
- **Bounded runs.** Every build has a time budget (20 minutes by default) and every smoke launch a 45 second budget under a virtual display with dummy audio.
- **Results are machine-written.** The JSON under `results/` is produced by the workflow from recorded logs. Rows are never edited by hand; corrections are made by rerunning.
- **No secrets.** The workflow uses the repository's default token with read access only, plus write access to commit results. No third-party credentials are involved.

Report a problem (a way to escape the runner, a path that could run a repository's code outside the job, a mistake in the recorded data) through GitHub's private vulnerability reporting on this repository, or open an issue for anything that is not sensitive.
