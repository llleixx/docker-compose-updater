#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ROOT="/opt/docker"
ROOT_DIR="${1:-$DEFAULT_ROOT}"

if [[ ! -d "$ROOT_DIR" ]]; then
  echo "Error: directory not found: $ROOT_DIR" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is not installed or not in PATH." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Error: docker compose is not available (docker compose version failed)." >&2
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

find_compose_projects() {
  local file dir prio
  declare -gA DIR_TO_FILE
  declare -gA DIR_TO_PRIO

  while IFS= read -r -d '' file; do
    dir="$(dirname "$file")"
    prio="$(compose_priority "$file")"
    if [[ -z "${DIR_TO_PRIO[$dir]+set}" || "$prio" -lt "${DIR_TO_PRIO[$dir]}" ]]; then
      DIR_TO_PRIO[$dir]="$prio"
      DIR_TO_FILE[$dir]="$file"
    fi
  done < <(
    find "$ROOT_DIR" -type f \( \
      -name 'compose.yml' -o -name 'compose.yaml' -o \
      -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
    \) -print0
  )
}

list_services() {
  local file
  file="$1"

  docker compose -f "$file" config --services | xargs
}

print_projects() {
  local -n dirs_ref=$1
  local -n updates_ref=$2
  local i dir

  echo "Projects:"
  for i in "${!dirs_ref[@]}"; do
    dir="${dirs_ref[$i]}"
    printf "  [%d] %s\n      services: %s\n" "$((i + 1))" "$dir" "${updates_ref[$i]}"
  done
}

select_projects() {
  local -n dirs_ref=$1
  local -n selection_ref=$2
  local input

  read -r -p "Select projects to update (comma-separated, or 'a' for all): " input

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
        echo "Invalid range: $token" >&2
        exit 1
      fi
      for ((i=start; i<=end; i++)); do
        selection_ref+=("$i")
      done
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      selection_ref+=("$token")
    else
      echo "Invalid selection: $token" >&2
      exit 1
    fi
  done

  for i in "${!selection_ref[@]}"; do
    selection_ref[$i]=$((selection_ref[$i] - 1))
    if (( selection_ref[$i] < 0 || selection_ref[$i] >= ${#dirs_ref[@]} )); then
      echo "Selection out of range: $((selection_ref[$i] + 1))" >&2
      exit 1
    fi
  done
}

update_project() {
  local dir file
  dir="$1"
  file="$2"

  echo "Updating $dir"
  docker compose -f "$file" pull
  docker compose -f "$file" up -d
}

find_compose_projects

if [[ ${#DIR_TO_FILE[@]} -eq 0 ]]; then
  echo "No docker compose projects found in $ROOT_DIR"
  exit 0
fi

PROJECT_DIRS=()
PROJECT_FILES=()
PROJECT_UPDATES=()

while IFS= read -r dir; do
  file="${DIR_TO_FILE[$dir]}"
  services="$(list_services "$file")"
  PROJECT_DIRS+=("$dir")
  PROJECT_FILES+=("$file")
  PROJECT_UPDATES+=("$services")
  unset file services
done < <(printf '%s\n' "${!DIR_TO_FILE[@]}" | sort)

print_projects PROJECT_DIRS PROJECT_UPDATES

SELECTED=()
select_projects PROJECT_DIRS SELECTED

for idx in "${SELECTED[@]}"; do
  update_project "${PROJECT_DIRS[$idx]}" "${PROJECT_FILES[$idx]}"
  echo
done

echo "Update complete."
