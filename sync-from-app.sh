#!/usr/bin/env bash
# Synchronize the public installer artifacts from the Android app repository.

set -euo pipefail

APP_DIR="${HERMES_APP_DIR:-$HOME/dev/hermes-console-app/hermes-android}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

SOURCE_FILES=(
  hermes_bridge.py
  hermes-mobile-setup.sh
  hermes-pair.sh
)
CANONICAL_FILES=(
  "${SOURCE_FILES[@]}"
  bridge-release.json
)

DRY_RUN=false
PUBLISH=false

usage() {
  cat <<'EOF'
Usage: ./sync-from-app.sh [--dry-run | --publish]

  --dry-run  Report what would change without touching files, index or history.
  --publish  Synchronize and commit canonical files, then push explicitly.

Without an option, the script synchronizes and creates a local commit only.
EOF
}

while (($# > 0)); do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --publish) PUBLISH=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: opción desconocida: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if $DRY_RUN && $PUBLISH; then
  echo "ERROR: --dry-run y --publish son incompatibles." >&2
  exit 2
fi

source_path() {
  case "$1" in
    hermes_bridge.py) printf '%s\n' "$APP_DIR/assets/bridge/hermes_bridge.py" ;;
    hermes-mobile-setup.sh) printf '%s\n' "$APP_DIR/scripts/hermes-mobile-setup.sh" ;;
    hermes-pair.sh) printf '%s\n' "$APP_DIR/scripts/hermes-pair.sh" ;;
    *) return 1 ;;
  esac
}

for dest in "${SOURCE_FILES[@]}"; do
  src="$(source_path "$dest")"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: no existe $src" >&2
    exit 1
  fi
done

BRIDGE_SOURCE="$(source_path hermes_bridge.py)"
VERSION="$(sed -nE 's/^VERSION = "([^"]+)".*/\1/p' "$BRIDGE_SOURCE" | head -n1)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][A-Za-z0-9.-]+)?$ ]]; then
  echo "ERROR: VERSION inválida o ausente en $BRIDGE_SOURCE" >&2
  exit 1
fi

BRIDGE_SHA256="$(sha256sum "$BRIDGE_SOURCE" | awk '{print $1}')"
BRIDGE_SIZE="$(wc -c < "$BRIDGE_SOURCE" | tr -d '[:space:]')"
MANIFEST_TMP="$(mktemp "${TMPDIR:-/tmp}/bridge-release.XXXXXX")"
cleanup() {
  [[ -z "${MANIFEST_TMP:-}" ]] || rm -f -- "$MANIFEST_TMP"
}
trap cleanup EXIT

printf '{\n  "schema": 1,\n  "version": "%s",\n  "sha256": "%s",\n  "size": %s\n}\n' \
  "$VERSION" "$BRIDGE_SHA256" "$BRIDGE_SIZE" > "$MANIFEST_TMP"

CHANGED_FILES=()
for dest in "${SOURCE_FILES[@]}"; do
  src="$(source_path "$dest")"
  if ! cmp -s -- "$src" "$REPO_DIR/$dest"; then
    CHANGED_FILES+=("$dest")
  fi
done
if ! cmp -s -- "$MANIFEST_TMP" "$REPO_DIR/bridge-release.json"; then
  CHANGED_FILES+=(bridge-release.json)
fi

if $DRY_RUN; then
  if ((${#CHANGED_FILES[@]} == 0)); then
    echo "Ya sincronizado: los archivos canónicos coinciden con la app."
  else
    printf 'Cambiaría: %s\n' "${CHANGED_FILES[@]}"
  fi
  echo "(dry-run: no se han modificado archivos, índice, commits ni remotos)"
  exit 0
fi

for dest in "${SOURCE_FILES[@]}"; do
  src="$(source_path "$dest")"
  if ! cmp -s -- "$src" "$REPO_DIR/$dest"; then
    cp -- "$src" "$REPO_DIR/$dest"
  fi
done
if ! cmp -s -- "$MANIFEST_TMP" "$REPO_DIR/bridge-release.json"; then
  cp -- "$MANIFEST_TMP" "$REPO_DIR/bridge-release.json"
fi

cd "$REPO_DIR"
git add -- "${CANONICAL_FILES[@]}"

if git diff --cached --quiet -- "${CANONICAL_FILES[@]}"; then
  echo "Ya sincronizado: no hay cambios canónicos que commitear."
else
  git diff --cached --stat -- "${CANONICAL_FILES[@]}"
  git commit --only -m "Sync from app (bridge $VERSION)" -- \
    "${CANONICAL_FILES[@]}"
fi

if $PUBLISH; then
  git push
  echo "Publicado: bridge $VERSION"
else
  echo "Preparado localmente: bridge $VERSION (usa --publish para publicar)"
fi
