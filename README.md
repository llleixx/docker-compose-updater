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
