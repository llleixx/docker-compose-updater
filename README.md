A simple shell script to selectively and conveniently update containers in Docker Compose files.

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
