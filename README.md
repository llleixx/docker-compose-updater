A simple shell script to selectively and conveniently update containers in Docker Compose files.

## Quick Start

Run directly from GitHub without downloading:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/llleixx/docker-compose-updater/main/compose-updater.sh)
```

## Usage

```bash
./compose-update.sh /opt/docker
```

If no directory is provided, the script defaults to `/opt/docker`.

Requirements: `docker`, `docker compose`.

The script will:

1. Recursively scan the directory for Docker Compose files.
2. List projects and their services.
3. Prompt for selecting one, many, or all projects.
4. Pull new images and recreate containers for the selected projects.

### Selection syntax

When prompted, you can choose projects using:

- Single numbers (e.g. `1,3`)
- Ranges with `-` (e.g. `2-5`)
- Mixes of numbers and ranges (e.g. `1,3-4,7`)
- `a` or `A` for all projects
