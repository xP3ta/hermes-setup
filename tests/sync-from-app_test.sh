#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hermes-sync-test.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$expected" == "$actual" ]] || \
    fail "$label (expected '$expected', got '$actual')"
}

make_app() {
  local app="$1"
  local version="$2"
  mkdir -p "$app/assets/bridge" "$app/scripts"
  printf 'VERSION = "%s"\nprint("bridge fixture")\n' "$version" \
    > "$app/assets/bridge/hermes_bridge.py"
  printf '#!/bin/sh\necho setup-%s\n' "$version" \
    > "$app/scripts/hermes-mobile-setup.sh"
  printf '#!/bin/sh\necho pair-%s\n' "$version" \
    > "$app/scripts/hermes-pair.sh"
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  cp "$ROOT/sync-from-app.sh" "$repo/sync-from-app.sh"
  chmod +x "$repo/sync-from-app.sh"
  printf 'VERSION = "0.0.1"\n' > "$repo/hermes_bridge.py"
  printf '#!/bin/sh\necho old-setup\n' > "$repo/hermes-mobile-setup.sh"
  printf '#!/bin/sh\necho old-pair\n' > "$repo/hermes-pair.sh"
  printf 'tracked notes\n' > "$repo/notes.txt"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name 'Sync Test'
  git -C "$repo" config user.email 'sync@example.invalid'
  git -C "$repo" add .
  git -C "$repo" commit -qm baseline
}

test_dry_run_is_non_destructive() {
  local app="$TMP_ROOT/app-dry"
  local repo="$TMP_ROOT/repo-dry"
  make_app "$app" 2.3.4
  make_repo "$repo"

  printf '# local QR work\n' >> "$repo/hermes-mobile-setup.sh"
  printf '# local QR work\n' >> "$repo/hermes-pair.sh"
  printf 'untracked\n' > "$repo/scratch.txt"

  local status_before hashes_before head_before
  status_before="$(git -C "$repo" status --porcelain=v1)"
  hashes_before="$(sha256sum "$repo/hermes-mobile-setup.sh" "$repo/hermes-pair.sh")"
  head_before="$(git -C "$repo" rev-parse HEAD)"

  HERMES_APP_DIR="$app" "$repo/sync-from-app.sh" --dry-run >/dev/null

  assert_eq "$status_before" "$(git -C "$repo" status --porcelain=v1)" \
    'dry-run status'
  assert_eq "$hashes_before" \
    "$(sha256sum "$repo/hermes-mobile-setup.sh" "$repo/hermes-pair.sh")" \
    'dry-run dirty file hashes'
  assert_eq "$head_before" "$(git -C "$repo" rev-parse HEAD)" 'dry-run HEAD'
  [[ ! -e "$repo/bridge-release.json" ]] || fail 'dry-run created manifest'
}

test_local_commit_and_explicit_publish() {
  local app="$TMP_ROOT/app-publish"
  local repo="$TMP_ROOT/repo-publish"
  local remote="$TMP_ROOT/remote.git"
  make_app "$app" 5.6.7
  make_repo "$repo"
  git init -q --bare --initial-branch=main "$remote"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -qu origin main
  local remote_before
  remote_before="$(git --git-dir="$remote" rev-parse main)"

  printf 'unrelated staged work\n' >> "$repo/notes.txt"
  git -C "$repo" add notes.txt
  printf 'untracked\n' > "$repo/scratch.txt"

  HERMES_APP_DIR="$app" "$repo/sync-from-app.sh" >/dev/null

  local local_head commit_files staged_files expected_sha expected_size
  local_head="$(git -C "$repo" rev-parse HEAD)"
  [[ "$local_head" != "$remote_before" ]] || fail 'default mode made no commit'
  assert_eq "$remote_before" "$(git --git-dir="$remote" rev-parse main)" \
    'default mode pushed unexpectedly'

  commit_files="$(git -C "$repo" show --pretty=format: --name-only HEAD | sed '/^$/d' | sort)"
  assert_eq $'bridge-release.json\nhermes-mobile-setup.sh\nhermes-pair.sh\nhermes_bridge.py' \
    "$commit_files" 'canonical commit paths'
  staged_files="$(git -C "$repo" diff --cached --name-only)"
  assert_eq 'notes.txt' "$staged_files" 'unrelated staged change preservation'
  [[ -e "$repo/scratch.txt" ]] || fail 'untracked file was removed'

  expected_sha="$(sha256sum "$repo/hermes_bridge.py" | awk '{print $1}')"
  expected_size="$(wc -c < "$repo/hermes_bridge.py" | tr -d '[:space:]')"
  jq -e \
    --arg sha "$expected_sha" \
    --argjson size "$expected_size" \
    '.schema == 1 and .version == "5.6.7" and .sha256 == $sha and .size == $size and (keys | sort == ["schema", "sha256", "size", "version"])' \
    "$repo/bridge-release.json" >/dev/null || fail 'invalid bridge manifest'

  HERMES_APP_DIR="$app" "$repo/sync-from-app.sh" --publish >/dev/null
  assert_eq "$local_head" "$(git --git-dir="$remote" rev-parse main)" \
    'explicit publish did not push'
  assert_eq 'notes.txt' "$(git -C "$repo" diff --cached --name-only)" \
    'publish changed unrelated staging'
}

test_invalid_options_are_non_destructive() {
  local app="$TMP_ROOT/app-invalid"
  local repo="$TMP_ROOT/repo-invalid"
  make_app "$app" 8.9.0
  make_repo "$repo"
  local status_before head_before
  status_before="$(git -C "$repo" status --porcelain=v1)"
  head_before="$(git -C "$repo" rev-parse HEAD)"

  if HERMES_APP_DIR="$app" "$repo/sync-from-app.sh" --dry-run --publish \
    >/dev/null 2>&1; then
    fail 'incompatible options succeeded'
  fi
  if HERMES_APP_DIR="$app" "$repo/sync-from-app.sh" --unknown \
    >/dev/null 2>&1; then
    fail 'unknown option succeeded'
  fi
  assert_eq "$status_before" "$(git -C "$repo" status --porcelain=v1)" \
    'invalid option status'
  assert_eq "$head_before" "$(git -C "$repo" rev-parse HEAD)" \
    'invalid option HEAD'
}

test_dry_run_is_non_destructive
test_local_commit_and_explicit_publish
test_invalid_options_are_non_destructive
echo 'sync-from-app tests: OK'
