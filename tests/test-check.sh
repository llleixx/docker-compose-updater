#!/usr/bin/env bash
# Integration tests with a fake Docker CLI: no real containers are changed.
set -euo pipefail
source_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export TEST_ROOT="$tmp" CASE=update
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin" "$tmp/project" "$tmp/other"
touch "$tmp/project/compose.yml"
export UPDATER="$source_dir/compose-updater.sh"
cat > "$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TEST_ROOT/calls"
case "$1 $2" in
  'compose version') exit 0 ;;
  'ps --filter')
    [[ $CASE != empty ]] || exit 0
    echo "$TEST_ROOT/project|$TEST_ROOT/project/compose.yml" ;;
  'ps -q') [[ $CASE == empty ]] || echo c1 ;;
  'inspect c1')
    ref=example/app:latest
    [[ $CASE != pinned ]] || ref=example/app@sha256:fixed
    configs="$TEST_ROOT/project/compose.yml"
    [[ $CASE != multifile ]] || configs+=",$TEST_ROOT/project/override.yml"
    jq -cn --arg dir "$TEST_ROOT/project" --arg ref "$ref" --arg configs "$configs" \
      '[{Name:"/app",Image:"sha256:old",Config:{Image:$ref,Labels:{"com.docker.compose.project":"custom-name","com.docker.compose.service":"web","com.docker.compose.project.working_dir":$dir,"com.docker.compose.project.config_files":$configs}}}]' ;;
  'image inspect')
    digests='["example/app@sha256:manifest"]'
    [[ $CASE != local ]] || digests='[]'
    jq -cn --argjson digests "$digests" '[{Os:"linux",Architecture:"amd64",RepoDigests:$digests}]' ;;
  'manifest inspect')
    [[ $CASE != stubborn ]] || { trap '' TERM; sleep 30; exit 1; }
    [[ $CASE != timeout ]] || { sleep 3; exit 1; }
    [[ $CASE != auth ]] || { echo unauthorized >&2; exit 1; }
    digest=sha256:new
    [[ $CASE != latest ]] || digest=sha256:old
    arch=amd64
    [[ $CASE != platform ]] || arch=arm64
    # Other platform and attestation must not affect comparison.
    jq -cn --arg digest "$digest" --arg arch "$arch" \
      '[{Descriptor:{platform:{os:"linux",architecture:$arch}},OCIManifest:{config:{digest:$digest}}},{Descriptor:{platform:{os:"linux",architecture:"arm"}},OCIManifest:{config:{digest:"sha256:other"}}},{Descriptor:{platform:{os:"unknown",architecture:"unknown"}},OCIManifest:{config:{digest:"sha256:attestation"}}}]' ;;
  compose*)
    case "${*: -1}" in
      running) echo web ;;
      --services) echo web ;;
    esac ;;
  *) echo "Unexpected fake Docker call: $*" >&2; exit 1 ;;
esac
DOCKER
chmod +x "$tmp/bin/docker"
run_json() {
  local expected=$1 rc=0
  : > "$tmp/calls"
  bash "$UPDATER" --check --json --timeout 1 > "$tmp/result" 2> "$tmp/stderr" || rc=$?
  [[ $rc == "$expected" ]]
  jq -e . "$tmp/result" >/dev/null
  ! grep -Eq '(^| )(pull|up)( |$)' "$tmp/calls"
}
for CASE in update latest pinned local platform auth timeout stubborn multifile empty; do
  export CASE
  expected=0
  case "$CASE" in platform|auth|timeout|stubborn) expected=2 ;; esac
  run_json "$expected"
  case "$CASE" in
    update) jq -e '.projects[0].status == "update" and .projects[0].project == "custom-name"' "$tmp/result" ;;
    latest) jq -e '.projects[0].status == "latest"' "$tmp/result" ;;
    pinned|local) jq -e '.containers[0].status == "skipped"' "$tmp/result" ;;
    platform|auth|timeout|stubborn) jq -e '.containers[0].status == "unknown"' "$tmp/result" ;;
    multifile) jq -e '.projects[0].selectable == false' "$tmp/result" ;;
    empty) jq -e '.containers == [] and .projects == []' "$tmp/result" ;;
  esac > /dev/null
  echo "PASS $CASE"
done
export CASE=update
bash "$UPDATER" --check --dir "$tmp/other" --json > "$tmp/result"
jq -e '.containers == []' "$tmp/result" >/dev/null
echo 'PASS directory scope'
: > "$tmp/calls"
bash "$UPDATER" --check < /dev/null > /dev/null
! grep -Eq '(^| )(pull|up)( |$)' "$tmp/calls"
echo 'PASS noninteractive report only'
for args in '--json' '--check --all' '--check --timeout 0'; do
  if bash "$UPDATER" $args > /dev/null 2>&1; then exit 1; fi
done
echo 'PASS invalid options'
# script(1) supplies a terminal so real selection code runs against fake Docker.
if command -v script >/dev/null; then
  : > "$tmp/calls"
  printf '\n' | script -qec 'bash "$UPDATER" --check' /dev/null > /dev/null
  ! grep -Eq '(^| )(pull|up)( |$)' "$tmp/calls"
  echo 'PASS blank selection'
  : > "$tmp/calls"
  printf '1,1\n' | script -qec 'bash "$UPDATER" --check' /dev/null > /dev/null
  [[ $(grep -c ' pull$' "$tmp/calls") == 1 ]]
  grep -F "compose -p custom-name -f $tmp/project/compose.yml up -d" "$tmp/calls" >/dev/null
  echo 'PASS selected project, explicit name, deduplication'
fi
# Original --all path still invokes the normal update commands.
: > "$tmp/calls"
bash "$UPDATER" --all > /dev/null
grep -q ' pull$' "$tmp/calls"
grep -q ' up -d$' "$tmp/calls"
echo 'PASS legacy --all'
