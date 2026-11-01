A simple shell script to selectively and conveniently update containers in Docker Compose files.

## Quick Start

Run directly from GitHub without downloading:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/llleixx/docker-compose-updater/main/compose-updater.sh)
```

## Usage

```bash
./compose-updater.sh /opt/docker
```

If no directory is provided, the script will discover running Compose projects from Docker metadata, regardless of where their compose files are stored.

### Options

```
-a, --all         Update all projects without prompting.
--check          Check image tags, then select projects with updates.
--json           With --check, output JSON only; never update.
--timeout SEC    Registry query timeout in seconds (default: 15).
-d, --dir DIR     Root directory to scan (if omitted, auto-discover running projects).
-h, --help        Show help text.
```

You can also pass the root directory as a positional argument (for example,
`./compose-updater.sh /opt/docker`).

Examples:

```bash
# Non-interactive update of all running compose projects discovered from Docker
./compose-updater.sh --all

# Restrict scanning to a specific root directory
./compose-updater.sh --dir /srv/compose
```

Requirements: `docker`, `docker compose`.

### Check before updating

```bash
# Check running containers, then choose projects to update
./compose-updater.sh --check

# Limit checks to projects discovered under this directory
./compose-updater.sh --check --dir /opt/docker

# Machine-readable report, no prompt or updates
./compose-updater.sh --check --json
```

Check mode additionally requires `jq` and GNU `timeout` (on Debian/Ubuntu:
`apt-get install jq coreutils`). It fetches registry metadata through
`docker manifest inspect --verbose`, using Docker's configured registry credentials.
It compares the running container with the remote image for the same
OS/architecture/variant, without downloading image layers. With the classic image
store it compares config digests; with the containerd store it compares the running
container's platform manifest digest. Manifest/index IDs are never compared with
config digests. If the running platform manifest is unavailable for a manifest-based
image ID, the result is `unknown`.
Each query has a 15-second default timeout; a CLI process that ignores termination
is forcibly killed after a further 2 seconds. `--timeout` overrides the query limit.

Each container is reported as `update`, `latest`, `unknown`, or `skipped`.
Only projects with detected updates are offered for selection. Press Enter to
leave everything unchanged; selection uses the number/range syntax below.
Selected projects run the normal `pull` and `up -d` commands for the whole project,
with the recorded project name preserved. Projects started with multiple Compose
files, missing file metadata, or a different file from the discovered one are
reported but require manual updates with their original invocation.

`--check --json` always reports only. Without a terminal on stdin, `--check` also
reports only. `--check --all` is rejected to avoid implicitly approving updates.
The existing update commands without `--check` retain their behavior.

The check covers **running containers and their existing image tags**, not stopped
services, edits to Compose files, or newer version tags (for example, it does not
suggest changing `postgres:17.6` to another version). Digest-pinned references and
images with no registry digest, such as local builds, are skipped. Registry errors,
timeouts and ambiguous/missing platform matches are `unknown`, never `latest`.

JSON has `containers` and `projects` arrays. Projects include their directory,
Compose file, selectable flag, and `updates`, `unknown`, and `skipped` service lists.
An `update` project can still contain unknown services; inspect those lists for a
complete result. `latest` means checked services match; skipped services remain
listed separately. Empty discovery produces empty arrays.

Check exit codes: `0` for a completed check (including updates found), `2` if any
container could not be checked, and `1` for usage/dependency or command errors.
An update command failure returns that command's nonzero status.

Run integration tests on Linux with `bash tests/test-check.sh`. They use a fake
Docker CLI, including for interactive update tests; no real containers are changed.

The script will:

1. If `--dir` is provided, recursively scan that directory for Docker Compose files.
2. If `--dir` is omitted, discover running compose projects from Docker container labels (`com.docker.compose.project.*`).
3. Keep only projects that currently have running containers (`docker compose ps --status running`).
4. List active projects and their services.
5. Prompt for selecting one, many, or all active projects.
6. Pull new images and recreate containers for the selected projects.

### Selection syntax

When prompted, you can choose projects using:

- Single numbers (e.g. `1,3`)
- Ranges with `-` (e.g. `2-5`)
- Mixes of numbers and ranges (e.g. `1,3-4,7`)
- `a` or `A` for all projects
