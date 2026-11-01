#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ROOT="/opt/docker"
ROOT_DIR=""
ROOT_DIR_SET=false
ALL=false
CHECK=false
JSON=false
CHECK_TIMEOUT=15

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
  --check          Check tags, then select projects to update (blank = none).
  --json           With --check, output JSON only; never update.
  --timeout SEC    Registry query timeout in check mode (default: 15).
  -d, --dir DIR     Root directory to scan.
                    If omitted, discover running compose projects via Docker labels.
  -h, --help        Show this help message.
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=true; shift ;;
    --json) JSON=true; shift ;;
    --timeout) CHECK_TIMEOUT=${2:?Missing timeout}; shift 2 ;;
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

if [[ "$JSON" == true && "$CHECK" != true ]]; then
  error "--json requires --check"; exit 1
fi
if [[ "$CHECK" == true && "$ALL" == true ]]; then
  error "--check cannot be combined with --all; select projects interactively."; exit 1
fi
if [[ ! "$CHECK_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  error "Invalid timeout"; exit 1
fi
if [[ "$JSON" == true ]]; then
  info() { echo "$*" >&2; }
  warn() { echo "$*" >&2; }
fi

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

  read -r -p "Select projects to update (comma-separated, ranges with '-', 'a' for all, blank for none): " input || input=""

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
      if (( ${#start} > 8 || ${#end} > 8 )); then
        error "Selection out of range: $token"; exit 1
      fi
      start=$((10#$start)); end=$((10#$end))
      if (( start < 1 || end > ${#dirs_ref[@]} || start > end )); then
        error "Invalid range: $token"
        exit 1
      fi
      for ((i=start; i<=end; i++)); do
        selection_ref+=("$i")
      done
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      if (( ${#token} > 8 )); then
        error "Selection out of range: $token"; exit 1
      fi
      selection_ref+=("$((10#$token))")
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
  local -a compose_args=(-f "$file")
  if [[ -n ${3:-} ]]; then compose_args=(-p "$3" "${compose_args[@]}"); fi
  docker compose "${compose_args[@]}" pull
  docker compose "${compose_args[@]}" up -d
  success "Updated $dir"
}


# Check running image config digests against registry metadata; never pull here.
check_projects() (
  tmp=$(mktemp -d)
  trap 'rm -rf -- "$tmp"' EXIT
  declare -A cached
  counter=0
  rows="$tmp/rows"
  : > "$rows"
  emit() {
    jq -cn --arg project "$p" --arg service "$service" --arg container "$name" \
      --arg image "$ref" --arg status "$1" --arg reason "$2" \
      --arg directory "$working_dir" --arg file "$compose_file" --argjson selectable "$selectable" --arg current "$current" --arg remote "${3:-}" \
      '{directory:$directory,file:$file,selectable:$selectable,project:$project,service:$service,container:$container,image:$image,status:$status,reason:$reason,current:$current,remote:$remote}' >> "$rows"
  }
  docker ps -q --filter label=com.docker.compose.project > "$tmp/ids"
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    docker inspect "$id" > "$tmp/container"
    p=$(jq -r '.[0].Config.Labels["com.docker.compose.project"]' "$tmp/container")
    working_dir=$(jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // ""' "$tmp/container")
    [[ -n $working_dir && ${DIR_TO_FILE[$working_dir]+yes} ]] || continue
    compose_file=${DIR_TO_FILE[$working_dir]}
    config_files=$(jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // ""' "$tmp/container")
    selectable=true
    # Multiple files need the original invocation, not a guessed single file.
    [[ $config_files != *,* && -n $config_files ]] || selectable=false
    if [[ $selectable == true ]]; then
      recorded_file=$config_files
      [[ $recorded_file == /* ]] || recorded_file="$working_dir/$recorded_file"
      [[ $recorded_file == "$compose_file" ]] || selectable=false
    fi
    service=$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // ""' "$tmp/container")
    name=$(jq -r '.[0].Name | ltrimstr("/")' "$tmp/container")
    ref=$(jq -r '.[0].Config.Image' "$tmp/container")
    current=$(jq -r '.[0].Image' "$tmp/container")
    if [[ $ref == *@sha256:* ]]; then
      emit skipped 'Digest-pinned image; no floating tag to check'; continue
    fi
    if ! docker image inspect "$current" > "$tmp/image" 2> "$tmp/error"; then
      emit unknown 'Cannot inspect running image'; continue
    fi
    if [[ $(jq '.[0].RepoDigests // [] | length' "$tmp/image") == 0 ]]; then
      emit skipped 'No registry digest (possibly a local build)'; continue
    fi
    os=$(jq -r '.[0].Os' "$tmp/image")
    arch=$(jq -r '.[0].Architecture' "$tmp/image")
    variant=$(jq -r '.[0].Variant // ""' "$tmp/image")
    if [[ ! ${cached[$ref]+yes} ]]; then
      file="$tmp/manifest-$counter"
      counter=$((counter + 1))
      # Docker CLI negotiates registry auth and fetches metadata only, not layers.
    if timeout --kill-after=2s "${CHECK_TIMEOUT}s" docker manifest inspect --verbose "$ref" > "$file" 2> "$file.err"; then
        cached[$ref]=$file
      else
        rc=$?
        cached[$ref]="$file.failed"
      if [[ $rc == 124 || $rc == 137 ]]; then
          printf 'Timed out after %ss\n' "$CHECK_TIMEOUT" > "$file.err"
        elif [[ ! -s $file.err ]]; then
          printf 'docker manifest inspect exited with code %s\n' "$rc" > "$file.err"
        fi
        mv "$file.err" "$file.failed"
      fi
    fi
    file=${cached[$ref]}
    if [[ $file == *.failed ]]; then
      emit unknown "Registry query failed: $(head -c 400 "$file")"; continue
    fi
    # Container Image is the image config digest, not the manifest/index digest.
    # Select the running platform first; ignore attestations and other platforms.
    if ! remote=$(jq -er --arg os "$os" --arg arch "$arch" --arg variant "$variant" '
      (if type == "array" then .[] else . end)
      | select(.Descriptor.platform.os == $os and .Descriptor.platform.architecture == $arch)
      | select($variant == "" or (.Descriptor.platform.variant // "") == $variant)
      | (.OCIManifest // .SchemaV2Manifest // (try (.Raw | @base64d | fromjson) catch null))
      | .config.digest // empty' "$file" | sort -u); then
      emit unknown 'No matching platform/config digest in registry response'; continue
    fi
    if [[ $remote == *$'\n'* ]]; then
      emit unknown 'Multiple matching platform digests; cannot compare safely'; continue
    fi
    if [[ $current == "$remote" ]]; then
      emit latest 'Running image matches remote tag' "$remote"
    else
      emit update 'Remote tag points to a different image' "$remote"
    fi
  done < "$tmp/ids"

  jq -s '{containers:., projects:(group_by([.project,.directory]) | map({project:.[0].project,
    directory:.[0].directory,file:.[0].file,selectable:all(.[]; .selectable),
    status:(if any(.[]; .status == "update") then "update" elif any(.[]; .status == "unknown") then "unknown" elif all(.[]; .status == "skipped") then "skipped" else "latest" end),
    updates:([.[] | select(.status == "update") | .service] | unique),
    unknown:([.[] | select(.status == "unknown") | .service] | unique),
    skipped:([.[] | select(.status == "skipped") | .service] | unique)}))}' "$rows" > "$tmp/result"
  check_rc=0
  if jq -e 'any(.containers[]; .status == "unknown")' "$tmp/result" >/dev/null; then check_rc=2; fi
  if [[ "$JSON" == true ]]; then
    cat "$tmp/result"
    exit "$check_rc"
  fi
  printf 'PROJECT\tSERVICE\tSTATUS\tIMAGE\n'
  jq -r '.containers[] | [.project,.service,.status,.image] | @tsv' "$tmp/result"
  jq -r '.containers[] | select(.status == "unknown" or .status == "skipped") | "\(.container): \(.reason)"' "$tmp/result" >&2
  jq -r '.projects[] | select(.selectable | not) | "Manual update required (multiple/custom Compose files): \(.project)"' "$tmp/result" >&2
  CHECK_DIRS=()
  CHECK_FILES=()
  CHECK_NAMES=()
  CHECK_SERVICES=()
  while IFS= read -r item; do
    CHECK_DIRS+=("$(jq -r '.directory' <<< "$item")")
    CHECK_FILES+=("$(jq -r '.file' <<< "$item")")
    CHECK_NAMES+=("$(jq -r '.project' <<< "$item")")
    CHECK_SERVICES+=("$(jq -r '.updates | join(" ")' <<< "$item")")
  done < <(jq -c '.projects[] | select(.status == "update" and .selectable)' "$tmp/result")
  if [[ ${#CHECK_DIRS[@]} -eq 0 ]]; then
    info "No projects with detected updates available for selection."
    exit "$check_rc"
  fi
  print_projects CHECK_DIRS CHECK_SERVICES
  if [[ ! -t 0 ]]; then
    info "Non-interactive input: report only; no projects updated."
    exit "$check_rc"
  fi
  SELECTED=()
  select_projects CHECK_DIRS SELECTED
  # De-duplicate selections so overlapping ranges cannot repeat an update.
  declare -A done_projects
  for idx in "${SELECTED[@]}"; do
    [[ ! ${done_projects[$idx]+yes} ]] || continue
    done_projects[$idx]=1
    update_project "${CHECK_DIRS[$idx]}" "${CHECK_FILES[$idx]}" "${CHECK_NAMES[$idx]}"
  done
  exit "$check_rc"
)

if [[ "$ROOT_DIR_SET" == true ]]; then
  ROOT_DIR="$(cd "$ROOT_DIR" && pwd -P)"
  info "Scanning for docker compose projects under ${COLOR_BOLD}$ROOT_DIR${COLOR_RESET}..."
  find_compose_projects
else
  info "No scan directory provided, discovering running compose projects via Docker labels..."
  find_running_compose_projects
fi

if [[ "$CHECK" == true ]]; then
  for tool in jq timeout; do
    command -v "$tool" >/dev/null || { error "Missing check dependency: $tool"; exit 1; }
  done
  check_projects
  exit $?
fi

if [[ -z ${DIR_TO_FILE[*]+set} ]]; then
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
