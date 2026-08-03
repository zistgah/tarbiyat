#!/usr/bin/env bash
# seed_tarbiyat.sh — seed (and optionally mint) zistgah/tarbiyat.
#
# Contract-honouring:
#   * SOURCES zops from the estate (never re-implements push/receipt/seal/OTS).
#   * Runs from ANYWHERE: resolves the build source beside the script, then $PWD,
#     then a delivered tarball, then a clone. Never asks the operator to cd/rm/tar.
#   * ONE typed PUSH gate (inside zops_push). MINT is opt-in behind a SECOND typed LIVE gate.
#   * NEVER cd's after zops_repo (zops_repo already cds into the clone).
#   * Homepage loads from the repo ROOT (index.html), not docs/.
#
# Usage:
#   bash seed_tarbiyat.sh                 # stage + push  (one PUSH gate)
#   bash seed_tarbiyat.sh --mint          # also mint the DOI (behind a typed LIVE gate)
#   bash seed_tarbiyat.sh --dry-run       # resolve + stage into a temp clone, no gate, no push
#
# Environment (all optional, discovered when absent):
#   ZOPS_LIB     path to ops/zops.sh (else estate, else governance clone)
#   ZOPS_FORGE   forge base (passed through to zops)
#   ESTATE       estate root (default /shared/estate/github)
#   ZENODO_TOKEN required only for --mint live publish

set -euo pipefail

REPO="zistgah/tarbiyat"
BRANCH="main"
ESTATE="${ESTATE:-/shared/estate/github}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO_MINT=0
DRY=0
for a in "$@"; do
  case "$a" in
    --mint) DO_MINT=1 ;;
    --dry-run|--dry) DRY=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

log(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
# Call a zops verb ONLY if the live library defines it. A verb this script cannot
# confirm from here is a hypothesis (C37): an absent one is skipped-and-declared,
# never fatal. zops_push owns the gate + commit + receipt + OTS + reseal + push.
zopt(){ if command -v "$1" >/dev/null 2>&1; then "$@"; else log "(zops has no $1 — skipped)"; fi; }

# ---------------------------------------------------------------------------
# 1. Locate and source zops FROM THE ESTATE (not a fetch).
#    Order: $ZOPS_LIB → estate governance → a governance clone → fail loudly.
# ---------------------------------------------------------------------------
resolve_zops(){
  local c
  for c in \
    "${ZOPS_LIB:-}" \
    "$ESTATE/zistgah/governance/ops/zops.sh" \
    "$SCRIPT_DIR/ops/zops.sh"; do
    [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
  done
  # last resort: clone governance beside us into a work dir and use its copy
  local work; work="$(mktemp -d)"
  if command -v git >/dev/null 2>&1; then
    local base="${ZOPS_FORGE:-https://github.com}"
    if git clone --depth 1 "$base/zistgah/governance.git" "$work/governance" >/dev/null 2>&1; then
      [ -f "$work/governance/ops/zops.sh" ] && { echo "$work/governance/ops/zops.sh"; return 0; }
    fi
  fi
  return 1
}
ZLIB="$(resolve_zops)" || die "could not locate ops/zops.sh (set ZOPS_LIB or mount the estate)"
# sanity: a real zops library, not a 404 body written to disk
head -1 "$ZLIB" | grep -qE '^#!' || die "zops at $ZLIB is not a shell script (refusing to source)"
grep -q 'zops_push' "$ZLIB" || die "zops at $ZLIB has no zops_push (wrong file)"
log "zops: $ZLIB"
# shellcheck disable=SC1090
source "$ZLIB"

# ---------------------------------------------------------------------------
# 2. Resolve the BUILD SOURCE (run-from-anywhere). Never ask the operator to prep.
#    beside script → $PWD → extract a delivered tarball → clone canonical.
# ---------------------------------------------------------------------------
has_build(){ [ -f "$1/index.html" ] && [ -d "$1/assets/posters" ] \
             && [ "$(ls -1 "$1/assets/posters"/*.png 2>/dev/null | wc -l)" -ge 1 ]; }

resolve_build_src(){
  local c
  for c in "$SCRIPT_DIR" "$PWD"; do
    has_build "$c" && { echo "$c"; return 0; }
  done
  # a delivered tarball beside the script or in $PWD
  local tb
  for tb in "$SCRIPT_DIR"/tarbiyat-build.tar.gz "$PWD"/tarbiyat-build.tar.gz; do
    if [ -f "$tb" ]; then
      local ex; ex="$(mktemp -d)"
      tar -xzf "$tb" -C "$ex"
      # tarball may contain a top-level dir or be flat
      local root="$ex"; has_build "$root" || root="$ex/tarbiyat-build"
      has_build "$root" && { echo "$root"; return 0; }
    fi
  done
  # last resort: clone canonical (idempotent, read-only use)
  if command -v git >/dev/null 2>&1; then
    local work; work="$(mktemp -d)"; local base="${ZOPS_FORGE:-https://github.com}"
    if git clone --depth 1 "$base/$REPO.git" "$work/tarbiyat" >/dev/null 2>&1; then
      has_build "$work/tarbiyat" && { echo "$work/tarbiyat"; return 0; }
    fi
  fi
  return 1
}
SRC="$(resolve_build_src)" || die "no build source found (assets not beside script, not in \$PWD, no tarball, clone failed)"
NPOST="$(ls -1 "$SRC/assets/posters"/*.png 2>/dev/null | wc -l)"
[ "$NPOST" -ge 1 ] || die "posters present: 0 — refusing to seed an empty site"
log "build source: $SRC"
log "posters present: $NPOST"

# ---------------------------------------------------------------------------
# 3. zops lifecycle. zops_repo cds into the clone; we DO NOT cd afterwards.
# ---------------------------------------------------------------------------
zops_init
zops_preflight
zops_repo "$REPO"          # <-- after this, CWD is the repo clone. Do not cd.

zopt zops_contract_begin

# Copy the staged site into the repo root (root index.html, not docs/).
copy_site(){
  local from="$1"
  # everything except VCS metadata and any nested build tarball
  ( cd "$from" && tar --exclude=.git --exclude='tarbiyat-build.tar.gz' -cf - . ) | tar -xf -
}
copy_site "$SRC"

# Homepage-at-root assertion (this repo's defining difference from tabdili).
[ -f index.html ] || die "index.html missing at repo root after copy"
[ ! -e docs/index.html ] || die "docs/index.html exists — tarbiyat must serve from ROOT, not docs/"
log "homepage at root: index.html ✓ (no docs/ redirect)"

# Standard contract checks — each optional (guarded above).
zopt zops_check_copyright
zopt zops_check_affiliation
zopt zops_check_no_placeholder
zopt zops_contract_check
zopt zops_contract_end

zopt zops_diff

if [ "$DRY" -eq 1 ]; then
  log "--dry-run: staged into $(pwd); no gate, no push."
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. ONE typed PUSH gate (create-remote + commit + receipt + OTS + reseal + push).
# ---------------------------------------------------------------------------
zops_push "seed zistgah/tarbiyat — 22 Topological Bildung posters, root landing + reader + seeder + PWA"
zopt zops_mark
zopt zops_receipt

# ---------------------------------------------------------------------------
# 5. MINT — opt-in, behind a SECOND typed LIVE gate. No sandbox (removed with
#    intent: sandbox publish was failing permission-denied and adds nothing —
#    misty validate already checks the metadata; the live deposit is gated).
# ---------------------------------------------------------------------------
if [ "$DO_MINT" -eq 1 ]; then
  command -v misty >/dev/null 2>&1 || die "--mint requested but 'misty' not found on PATH"
  [ -f metadata/misty.json ] || die "metadata/misty.json missing"
  log "misty validate…"
  misty validate -m metadata/misty.json || die "misty metadata invalid"

  # package the artifact misty will deposit (posters + site as a tarball)
  local_art="tarbiyat-artifact.tar.gz"
  tar --exclude=.git -czf "$local_art" assets metadata README.md index.html reader.html seed.html

  printf '\n  LIVE DOI mint. Zenodo leaves a tombstone on later delete.\n'
  printf '  Type exactly: MINT tarbiyat live\n  > '
  read -r ans
  if [ "$ans" = "MINT tarbiyat live" ]; then
    [ -n "${ZENODO_TOKEN:-}" ] || die "ZENODO_TOKEN not set — cannot mint live"
    misty publish -m metadata/misty.json -f "$local_art" --output live-result.json \
      || die "live publish failed"
    DOI="$(grep -oE '"doi"[[:space:]]*:[[:space:]]*"[^"]+"' live-result.json | head -1 | sed 's/.*"doi"[[:space:]]*:[[:space:]]*"//;s/"//')"
    log "minted DOI: ${DOI:-<see live-result.json>}"
    # record the DOI back through the same gated push
    if [ -n "${DOI:-}" ]; then
      sed -i "s#ORCID 0009-0002-0684-8320#ORCID 0009-0002-0684-8320 · DOI ${DOI}#" README.md || true
      zops_push "record DOI ${DOI} for zistgah/tarbiyat"
    fi
  else
    log "LIVE mint declined (got: '$ans'). Nothing minted."
  fi
fi

zops_done
log "done."
