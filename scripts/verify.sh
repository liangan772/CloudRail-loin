#!/usr/bin/env bash
# Runs every offline check on the plugin sources.
#
# These are the checks that do NOT require a Discourse checkout: Ruby
# syntax, YAML validity, .gjs parsing (via content-tag), SCSS compilation
# (via dart-sass), i18n key coverage, and the bare-boot simulation that
# proves the plugin cannot abort `rake db:migrate`.
#
# Usage:  bash scripts/verify.sh
#
# Requires the helper tooling in $VERIFY_TOOLS (see the README). When the
# tooling is absent the corresponding check is skipped with a notice
# rather than failing, so the script is still useful on a bare machine.

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_TOOLS="${VERIFY_TOOLS:-/c/tmp/gjscheck}"
GJS_HELPERS="${GJS_HELPERS:-/c/tmp/boottest}"

pass=0
fail=0
skip=0

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip + 1)); }

section() { printf '\n== %s ==\n' "$1"; }

cd "$PLUGIN_ROOT" || exit 1

# ------------------------------------------------------------------ #
section "Ruby syntax"
# ------------------------------------------------------------------ #
while IFS= read -r f; do
  if ruby -c "$f" >/dev/null 2>&1; then
    ok "$f"
  else
    bad "$f"
    ruby -c "$f"
  fi
done < <(find lib spec -name '*.rb' | sort)

if ruby -c plugin.rb >/dev/null 2>&1; then
  ok "plugin.rb"
else
  bad "plugin.rb"
fi

# ------------------------------------------------------------------ #
section "YAML"
# ------------------------------------------------------------------ #
while IFS= read -r f; do
  if ruby -e "require 'yaml'; YAML.unsafe_load_file('$f')" >/dev/null 2>&1; then
    ok "$f"
  else
    bad "$f"
  fi
done < <(find config -name '*.yml' | sort)

# ------------------------------------------------------------------ #
section ".gjs templates"
# ------------------------------------------------------------------ #
if [ -f "$VERIFY_TOOLS/check2.cjs" ]; then
  while IFS= read -r f; do
    if node "$VERIFY_TOOLS/check2.cjs" "$f" >/dev/null 2>&1; then
      ok "$f"
    else
      bad "$f"
      node "$VERIFY_TOOLS/check2.cjs" "$f"
    fi
  done < <(find assets -name '*.gjs' | sort)
else
  note "content-tag validator not found at $VERIFY_TOOLS/check2.cjs"
fi

# ------------------------------------------------------------------ #
section "SCSS"
# ------------------------------------------------------------------ #
if [ -f "$VERIFY_TOOLS/check_scss.cjs" ]; then
  while IFS= read -r f; do
    abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    if node "$VERIFY_TOOLS/check_scss.cjs" "$abs" >/dev/null 2>&1; then
      ok "$f"
    else
      bad "$f"
      node "$VERIFY_TOOLS/check_scss.cjs" "$abs"
    fi
  done < <(find assets -name '*.scss' | sort)
else
  note "sass compiler not found at $VERIFY_TOOLS/check_scss.cjs"
fi

# ------------------------------------------------------------------ #
section "Plain JS"
# ------------------------------------------------------------------ #
tmpjs="$(mktemp -d)"
while IFS= read -r f; do
  cp "$f" "$tmpjs/check.mjs"
  if node --check "$tmpjs/check.mjs" >/dev/null 2>&1; then
    ok "$f"
  else
    bad "$f"
    node --check "$tmpjs/check.mjs"
  fi
done < <(find assets -name '*.js' | sort)
find "$tmpjs" -type f -delete 2>/dev/null
rmdir "$tmpjs" 2>/dev/null || true

# ------------------------------------------------------------------ #
section "i18n key coverage"
# ------------------------------------------------------------------ #
if [ -f "$GJS_HELPERS/check_i18n.rb" ]; then
  if ruby "$GJS_HELPERS/check_i18n.rb" "$PLUGIN_ROOT" >/dev/null 2>&1; then
    ok "all referenced keys exist in every locale"
  else
    bad "missing i18n keys"
    ruby "$GJS_HELPERS/check_i18n.rb" "$PLUGIN_ROOT"
  fi
else
  note "i18n checker not found at $GJS_HELPERS/check_i18n.rb"
fi

# ------------------------------------------------------------------ #
section "Bare-boot simulation (rake db:migrate safety)"
# ------------------------------------------------------------------ #
if [ -f "$GJS_HELPERS/simulate_boot.rb" ]; then
  # Re-sync the current sources into the harness sandbox.
  rm -rf "$GJS_HELPERS/lib" "$GJS_HELPERS/plugin.rb"
  mkdir -p "$GJS_HELPERS/lib"
  cp -r lib/. "$GJS_HELPERS/lib/"
  cp plugin.rb "$GJS_HELPERS/plugin.rb"

  if out="$(cd "$GJS_HELPERS" && ruby simulate_boot.rb 2>&1)"; then
    ok "plugin.rb survives a boot without controllers"
  else
    bad "boot simulation failed"
    printf '%s\n' "$out"
  fi
else
  note "boot simulator not found at $GJS_HELPERS/simulate_boot.rb"
fi

# ------------------------------------------------------------------ #
printf '\n----------------------------------------\n'
printf 'passed: %d   failed: %d   skipped: %d\n' "$pass" "$fail" "$skip"
if [ "$fail" -eq 0 ]; then
  printf '\033[32mALL CHECKS PASSED\033[0m\n'
  exit 0
fi
printf '\033[31m%d CHECK(S) FAILED\033[0m\n' "$fail"
exit 1
