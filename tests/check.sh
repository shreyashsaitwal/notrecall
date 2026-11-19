#!/bin/sh
# Validates shell syntax, VDF manifests, and NotProton plugin schema compliance.
set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
NOTPROTON_DIR="${NOTPROTON_DIR:-$PROJECT_DIR/../NotProton}"

echo "==> Checking POSIX shell syntax (sh -n)"
for f in \
  "$PROJECT_DIR/compat/run" \
  "$PROJECT_DIR/scripts/pipeline_hook.sh" \
  "$PROJECT_DIR/scripts/install.sh" \
  "$PROJECT_DIR/scripts/uninstall.sh" \
  "$PROJECT_DIR/scripts/build_runtime.sh" \
  "$PROJECT_DIR/scripts/build_helpers.sh" \
  "$PROJECT_DIR/scripts/patch_ntdll.sh" \
  "$PROJECT_DIR/scripts/package.sh" \
  "$PROJECT_DIR/tests/check.sh"; do
  sh -n "$f"
  echo "    OK: ${f#"$PROJECT_DIR/"}"
done

echo "==> Checking Steam VDF manifests"
grep -q '"notrecall-proton"' "$PROJECT_DIR/compat/compatibilitytool.vdf"
grep -q '"from_oslist" "windows"' "$PROJECT_DIR/compat/compatibilitytool.vdf"
grep -q '"to_oslist" "macos"' "$PROJECT_DIR/compat/compatibilitytool.vdf"
grep -q '"commandline" "/run %verb%"' "$PROJECT_DIR/compat/toolmanifest.vdf"
echo "    OK: compatibilitytool.vdf & toolmanifest.vdf"

echo "==> Validating plugins/50-notrecall.conf against NotProton's plugin parser"
if [ -f "$NOTPROTON_DIR/dylib/feats/compat_run.sh" ]; then
  # Extract np_conf_normalise directly from NotProton's compat_run.sh and run it on our plugin dir.
  tmp_validator=$(mktemp)
  trap 'rm -f "$tmp_validator"' EXIT
  awk '/^np_conf_normalise\(\)/,/^)/' "$NOTPROTON_DIR/dylib/feats/compat_run.sh" > "$tmp_validator"
  out=$(
    # shellcheck disable=SC1090
    . "$tmp_validator"
    np_conf_normalise "$PROJECT_DIR/plugins" "" plugin
  )
  refused=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "!" { print }')
  if [ -n "$refused" ]; then
    echo "FAIL: NotProton refused plugin entries:" >&2
    printf '%s\n' "$refused" >&2
    exit 1
  fi
  records=$(printf '%s\n' "$out" | awk -F'\t' '$1 != "!" && $1 !~ /^== / && !seen[$1]++ { n++ } END { print n + 0 }')
  echo "    OK: NotProton accepted all $records plugin record(s) with 0 refusals"
else
  echo "    SKIP: NotProton repo not found at $NOTPROTON_DIR"
fi

echo "==> All checks passed!"
