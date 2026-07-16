#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# smoke-release.sh — Henne-Ei-Smoke mit GARANTIERTEM Zurückdrehen
#
# Problem (dev/v1-Drift): reusable-ci referenziert seine Sub-Reusables/Composites
# intern über @v1 (Prod). Ein dev-/Release-Branch ist voraus (nutzt Inputs, die
# @v1 noch nicht kennt, z.B. gated-promotion) → jeder Smoke = startup_failure,
# bis @v1 nachgezogen ist. Der etablierte Workaround: interne Refs TEMPORÄR auf
# den Branch biegen, smoken, VOR dem Tag zurückdrehen. Das Zurückdrehen zu
# vergessen macht @v1 kaputt (dokumentierter Fehler in CLAUDE.md).
#
# Dieses Skript biegt die Refs auf den aktuellen Branch, pusht, lässt dich smoken,
# und dreht via `trap` GARANTIERT zurück — auch bei Ctrl-C oder Fehler.
# Es bewegt NIE @v1 (das macht release-v1.sh + User). (Audit 2026-07-16, Etappe 5)
#
# Usage:
#   scripts/smoke-release.sh              # biegt→push→wartet→dreht zurück (auf aktuellem Branch)
#   scripts/smoke-release.sh --dry-run    # zeigt nur, was gebogen würde
#   scripts/smoke-release.sh --restore    # Notfall: Refs zurück auf @v1 (falls ein Lauf abbrach)
# ═══════════════════════════════════════════════════════════════
set -euo pipefail
export MSYS_NO_PATHCONV=1

DRY_RUN=0; RESTORE=0
for a in "$@"; do case "$a" in
  --dry-run) DRY_RUN=1 ;;
  --restore) RESTORE=1 ;;
  *) echo "unbekanntes Flag: $a" >&2; exit 1 ;;
esac; done

die()  { echo "❌ ABBRUCH: $*" >&2; exit 1; }
info() { echo "▸ $*"; }
ok()   { echo "✓ $*"; }

TARGETS=(.github/workflows/reusable-*.yml .github/actions/*/action.yml)

BRANCH="$(git branch --show-current || true)"
[ -n "$BRANCH" ] || die "detached HEAD — auf einem Branch ausführen (nicht auf einem Tag)."
[ "$BRANCH" != "main" ] || die "nicht auf main ausführen — das ist die Release-Linie."

# Biegt interne shared-workflows-Refs @<from> → @<to>. Matcht @v1 am Zeilenende ODER
# vor Whitespace, NIE @v1.9.5 (dort folgt '.', kein Ende/Space). Gibt Trefferzahl aus.
biege() {
  local from="$1" to="$2" total=0
  for f in ${TARGETS[@]}; do
    [ -f "$f" ] || continue
    local n; n=$(grep -cE "adza-group/shared-workflows/[^[:space:]]*@${from}([[:space:]]|\$)" "$f" || true)
    if [ "${n:-0}" -gt 0 ]; then
      sed -i -E "s|(adza-group/shared-workflows/[^[:space:]]*)@${from}\$|\1@${to}|; s|(adza-group/shared-workflows/[^[:space:]]*)@${from}([[:space:]])|\1@${to}\2|g" "$f"
      total=$((total + n))
    fi
  done
  echo "$total"
}

# ── --restore: Notfall-Rückdrehung ────────────────────────────
if [ "$RESTORE" = 1 ]; then
  n=$(biege "$BRANCH" v1)
  ok "$n interne Refs @${BRANCH} → @v1 zurückgedreht. Bitte committen + pushen."
  git --no-pager diff --stat
  exit 0
fi

# ── Gate: working tree clean ──────────────────────────────────
[ -z "$(git status --porcelain)" ] || die "working tree nicht clean — erst committen/stashen."

# ── --dry-run: nur zeigen ─────────────────────────────────────
if [ "$DRY_RUN" = 1 ]; then
  n=$(biege v1 "$BRANCH")
  echo "── Würde $n interne @v1-Refs auf @${BRANCH} biegen: ──────────"
  git --no-pager diff
  git checkout -- ${TARGETS[@]} 2>/dev/null || true   # verwerfen, nichts committen
  ok "DRY-RUN — nichts geändert."
  exit 0
fi

command -v gh >/dev/null 2>&1 || die "gh nicht gefunden."
NAME="$(git log -1 --format='%an')"; EMAIL="$(git log -1 --format='%ae')"
commit() { git -c user.name="$NAME" -c user.email="$EMAIL" commit -q "$@"; }

# ── trap: Refs GARANTIERT zurückdrehen (auch bei Ctrl-C/Fehler) ─
cleanup() {
  echo ""; info "cleanup: interne Refs zurück auf @v1 …"
  if [ -n "$(git status --porcelain ${TARGETS[@]} 2>/dev/null)" ]; then
    git checkout -- ${TARGETS[@]} 2>/dev/null || true   # ungespeicherte Bieg-Reste weg
  fi
  local n; n=$(biege "$BRANCH" v1)
  if [ "$n" -gt 0 ] && [ -n "$(git status --porcelain)" ]; then
    git add ${TARGETS[@]}; commit -m "chore: interne Refs zurück auf @v1 (Henne-Ei-Smoke Ende)"
    git push origin "$BRANCH" 2>&1 | tail -1 || echo "⚠ push fehlgeschlagen — MANUELL zurückdrehen/pushen!"
    ok "@v1-Refs wiederhergestellt + gepusht."
  else
    ok "Refs bereits auf @v1."
  fi
}
trap cleanup EXIT

# ── biegen + committen + pushen ───────────────────────────────
n=$(biege v1 "$BRANCH")
[ "$n" -gt 0 ] || die "keine internen @v1-Refs gefunden — nichts zu tun."
git add ${TARGETS[@]}
commit -m "chore: TEMP interne Refs auf @${BRANCH} (Henne-Ei-Smoke — trap dreht zurück)"
git push origin "$BRANCH" 2>&1 | tail -1
ok "$n Refs auf @${BRANCH} gebogen + gepusht."
echo ""
echo "── Jetzt den Smoke fahren: ───────────────────────────────"
echo "   Temp-Trigger push:[$BRANCH] in _smoke-ci.yml setzen + pushen (oder gh workflow run),"
echo "   dann: gh run watch <id> --exit-status"
echo "──────────────────────────────────────────────────────────"
printf "ENTER drücken, wenn der Smoke durch ist (Refs werden dann zurückgedreht)… "
read -r _
# trap cleanup läuft beim EXIT
