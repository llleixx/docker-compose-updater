#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ROOT="/opt/docker"
ROOT_DIR=""
ROOT_DIR_SET=false
ALL=false

if [[ -t 1 ]]; then
  COLOR_RED=$'\033[0;31m'
  COLOR_GREEN=$'\033[0;32m'
  COLOR_YELLOW=$'\033[0;33m'
  COLOR_BLUE=$'\033[0;34m'
  COLOR_BOLD=$'\033[1m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_BOLD=""
  COLOR_RESET=""
fi

info() {
  echo "${COLOR_BLUE}ℹ${COLOR_RESET} $*"
}

success() {
  echo "${COLOR_GREEN}✔${COLOR_RESET} $*"
}

warn() {
  echo "${COLOR_YELLOW}⚠${COLOR_RESET} $*"
}

error() {
  echo "${COLOR_RED}✖${COLOR_RESET} $*" >&2
}

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options] [root_dir]

Options:
  -a, --all         Update all projects without prompting.
  -d, --dir DIR     Root directory to scan.
                    If omitted, discover running compose projects via Docker labels.
  -h, --help        Show this help message.
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)
      ALL=true
      shift
      ;;
    -d|--dir)
      if [[ $# -lt 2 ]]; then
        error "Missing argument for $1"
        usage
        exit 1
      fi
      ROOT_DIR="$2"
      ROOT_DIR_SET=true
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      error "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ "$ROOT_DIR_SET" == true ]]; then
        error "Unexpected argument: $1"
        usage
        exit 1
      fi
      ROOT_DIR="$1"
      ROOT_DIR_SET=true
      shift
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  error "Docker is not installed or not in PATH."
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  error "Docker compose is not available (docker compose version failed)."
  exit 1
fi

if [[ "$ROOT_DIR_SET" == true && ! -d "$ROOT_DIR" ]]; then
  error "Directory not found: $ROOT_DIR"
  exit 1
fi

compose_priority() {
  local base
  base="$(basename "$1")"
  case "$base" in
    compose.yml) echo 1 ;;
    compose.yaml) echo 2 ;;
    docker-compose.yml) echo 3 ;;
    docker-compose.yaml) echo 4 ;;
    *) echo 99 ;;
  esac
}

pick_compose_file_in_dir() {
  local dir candidate best_file="" best_prio=999

  for candidate in \
    "$dir/compose.yml" \
    "$dir/compose.yaml" \
    "$dir/docker-compose.yml" \
    "$dir/docker-compose.yaml"; do
    if [[ -f "$candidate" ]]; then
      local prio
      prio="$(compose_priority "$candidate")"
      if (( prio < best_prio )); then
        best_prio="$prio"
        best_file="$candidate"
      fi
    fi
  done

  if [[ -n "$best_file" ]]; then
    echo "$best_file"
  fi
}

set_project_file() {
  local dir file prio
  dir="$1"
  file="$2"
  prio="$(compose_priority "$file")"

  if [[ -z "${DIR_TO_PRIO[$dir]+set}" || "$prio" -lt "${DIR_TO_PRIO[$dir]}" ]]; then
    DIR_TO_PRIO[$dir]="$prio"
    DIR_TO_FILE[$dir]="$file"
  fi
}

find_compose_projects() {
  local file dir
  declare -gA DIR_TO_FILE
  declare -gA DIR_TO_PRIO

  while IFS= read -r -d '' file; do
    dir="$(dirname "$file")"
    set_project_file "$dir" "$file"
  done < <(
    find "$ROOT_DIR" -type f \( \
      -name 'compose.yml' -o -name 'compose.yaml' -o \
      -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
    \) -print0
  )
}

find_running_compose_projects() {
  local row working_dir config_files selected_file raw_file resolved_file
  declare -gA DIR_TO_FILE
  declare -gA DIR_TO_PRIO

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue

    working_dir="${row%%|*}"
    config_files="${row#*|}"

    [[ -z "$working_dir" ]] && continue

    selected_file=""
    IFS=',' read -r -a config_file_arr <<< "$config_files"
    for raw_file in "${config_file_arr[@]}"; do
      [[ -z "$raw_file" ]] && continue
      if [[ "$raw_file" = /* ]]; then
        resolved_file="$raw_file"
      else
        resolved_file="$working_dir/$raw_file"
      fi

      if [[ -f "$resolved_file" ]]; then
        if [[ -z "$selected_file" ]]; then
          selected_file="$resolved_file"
        elif [[ "$(compose_priority "$resolved_file")" -lt "$(compose_priority "$selected_file")" ]]; then
          selected_file="$resolved_file"
        fi
      fi
    done

    if [[ -z "$selected_file" ]]; then
      selected_file="$(pick_compose_file_in_dir "$working_dir")"
    fi

    if [[ -n "$selected_file" ]]; then
      set_project_file "$working_dir" "$selected_file"
    fi
  done < <(docker ps --filter status=running --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}' | sort -u)
}

list_services() {
  local file
  file="$1"

  docker compose -f "$file" config --services | xargs
}

is_project_running() {
  local file running_services
  file="$1"

  running_services="$(docker compose -f "$file" ps --status running --services | xargs || true)"
  [[ -n "$running_services" ]]
}

print_projects() {
  local -n dirs_ref=$1
  local -n updates_ref=$2
  local i dir

  echo "${COLOR_BOLD}Projects:${COLOR_RESET}"
  for i in "${!dirs_ref[@]}"; do
    dir="${dirs_ref[$i]}"
    printf "  ${COLOR_GREEN}[%d]${COLOR_RESET} %s\n      ${COLOR_YELLOW}services:${COLOR_RESET} %s\n" \
      "$((i + 1))" "$dir" "${updates_ref[$i]}"
  done
}

select_projects() {
  local -n dirs_ref=$1
  local -n selection_ref=$2
  local input start end i token

  read -r -p "Select projects to update (comma-separated, ranges with '-', or 'a' for all; use -a to skip prompt): " input

  if [[ "$input" =~ ^[aA]$ ]]; then
    selection_ref=("${!dirs_ref[@]}")
    return
  fi

  IFS=',' read -r -a raw_selection <<< "$input"
  selection_ref=()
  for token in "${raw_selection[@]}"; do
    token="${token//[[:space:]]/}"
    if [[ -z "$token" ]]; then
      continue
    fi
    if [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
      start="${token%-*}"
      end="${token#*-}"
      if (( start > end )); then
        error "Invalid range: $token"
        exit 1
      fi
      for ((i=start; i<=end; i++)); do
        selection_ref+=("$i")
      done
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      selection_ref+=("$token")
    else
      error "Invalid selection: $token"
      exit 1
    fi
  done

  for i in "${!selection_ref[@]}"; do
    selection_ref[$i]=$((selection_ref[$i] - 1))
    if (( selection_ref[$i] < 0 || selection_ref[$i] >= ${#dirs_ref[@]} )); then
      error "Selection out of range: $((selection_ref[$i] + 1))"
      exit 1
    fi
  done
}

update_project() {
  local dir file
  dir="$1"
  file="$2"

  info "Updating ${COLOR_BOLD}$dir${COLOR_RESET}"
  docker compose -f "$file" pull
  docker compose -f "$file" up -d
  success "Updated $dir"
}

if [[ "$ROOT_DIR_SET" == true ]]; then
  info "Scanning for docker compose projects under ${COLOR_BOLD}$ROOT_DIR${COLOR_RESET}..."
  find_compose_projects
else
  info "No scan directory provided, discovering running compose projects via Docker labels..."
  find_running_compose_projects
fi

if [[ ${#DIR_TO_FILE[@]} -eq 0 ]]; then
  if [[ "$ROOT_DIR_SET" == true ]]; then
    warn "No docker compose projects found in $ROOT_DIR"
  else
    warn "No running docker compose projects found via Docker labels"
  fi
  exit 0
fi

PROJECT_DIRS=()
PROJECT_FILES=()
PROJECT_UPDATES=()

while IFS= read -r dir; do
  file="${DIR_TO_FILE[$dir]}"

  if ! is_project_running "$file"; then
    info "Skipping inactive project: ${COLOR_BOLD}$dir${COLOR_RESET}"
    unset file
    continue
  fi

  services="$(list_services "$file")"
  PROJECT_DIRS+=("$dir")
  PROJECT_FILES+=("$file")
  PROJECT_UPDATES+=("$services")
  unset file services
done < <(printf '%s\n' "${!DIR_TO_FILE[@]}" | sort)

if [[ ${#PROJECT_DIRS[@]} -eq 0 ]]; then
  warn "No running docker compose projects found"
  exit 0
fi

print_projects PROJECT_DIRS PROJECT_UPDATES

SELECTED=()
if [[ "$ALL" == true ]]; then
  SELECTED=("${!PROJECT_DIRS[@]}")
else
  select_projects PROJECT_DIRS SELECTED
fi

for idx in "${SELECTED[@]}"; do
  update_project "${PROJECT_DIRS[$idx]}" "${PROJECT_FILES[$idx]}"
  echo
done

success "Update complete."
