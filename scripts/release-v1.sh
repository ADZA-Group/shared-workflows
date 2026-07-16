#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# release-v1.sh — Gated @v1-Move für ADZA shared-workflows
#
# @v1 ist ein bewusst BEWEGLICHER Major-Tag (kein Pinning — s. CLAUDE.md /
# Root-Cause-Incident 2026-06-01: exakte interne Pins wurden stale → Fixes kamen
# nicht an). Dieses Skript härtet NICHT das Pinning, sondern den MOVE-Prozess:
# es erzwingt die bisher manuellen Schritte als HARTE Gates (Abbruch statt
# Vergessen). Auslöser: Audit 2026-07-16, Alternative zu #3/#9.
#
# Gates (jeder bricht bei Fehler ab):
#   1) working tree clean
#   2) Verlust-Check   — kein commit, der aktuell auf @v1 hängt, geht verloren
#   3) Smoke grün      — es MUSS einen grünen _smoke-ci-Lauf für EXAKT den SHA geben
#   4) Version-Tag frei — Punkt-Tags (v1.9.x) sind unveränderlich
#   5) Race-Recheck    — @v1 darf sich seit Prüfbeginn nicht bewegt haben (Parallel-Session)
#   6) Bestätigung     — interaktiv (oder --yes)
#   7) Post-Verify     — remote @v1 zeigt danach wirklich auf den SHA
#
# Usage:
#   scripts/release-v1.sh <release-ref> [version-tag] [--yes] [--dry-run]
# Beispiele:
#   scripts/release-v1.sh release-v1.9.5 v1.9.5      # Punkt-Tag + @v1 bewegen
#   scripts/release-v1.sh HEAD --dry-run             # nur Gates prüfen, nichts pushen
# ═══════════════════════════════════════════════════════════════
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git-Bash unter Windows: 'refs/tags/v1^{}' nicht zu Pfad mangeln

SMOKE_WORKFLOW="_smoke-ci.yml"
DRY_RUN=0
ASSUME_YES=0
RELEASE_REF=""
VERSION_TAG=""

die()  { echo "❌ ABBRUCH: $*" >&2; exit 1; }
info() { echo "▸ $*"; }
ok()   { echo "✓ $*"; }

# ── Args ──────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    -*)         die "unbekanntes Flag: $arg" ;;
    *)
      if   [ -z "$RELEASE_REF" ]; then RELEASE_REF="$arg"
      elif [ -z "$VERSION_TAG" ]; then VERSION_TAG="$arg"
      else die "zu viele Argumente: $arg"; fi ;;
  esac
done
[ -n "$RELEASE_REF" ] || die "Usage: $0 <release-ref> [version-tag] [--yes] [--dry-run]"
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) nicht gefunden — für das Smoke-Gate nötig."

# ── Gate 1: working tree clean ────────────────────────────────
[ -z "$(git status --porcelain)" ] || die "working tree nicht clean — erst committen/stashen."
ok "working tree clean"

# ── Fetch (holt aktuellen v1-Tag + refs lokal) ────────────────
info "fetch tags + refs …"
git fetch --tags --force origin >/dev/null 2>&1 || die "git fetch fehlgeschlagen."
git fetch origin >/dev/null 2>&1 || true

# ── release-ref → commit (NICHT tag-object) ───────────────────
RELEASE_SHA="$(git rev-parse -q --verify "${RELEASE_REF}^{commit}" 2>/dev/null)" \
  || die "release-ref '$RELEASE_REF' nicht als commit auflösbar."
ok "release-ref $RELEASE_REF → $RELEASE_SHA"

# ── Gate 2: Verlust-Check (v1^{} = commit hinter dem annotated Tag) ─────
LOCAL_V1="$(git rev-parse -q --verify 'v1^{commit}' 2>/dev/null || true)"
if [ -z "$LOCAL_V1" ]; then
  info "⚠ @v1 existiert noch nicht (Erst-Setup) — Verlust-Check übersprungen."
else
  ok "@v1 aktuell → $LOCAL_V1"
  LOST="$(git log --oneline "$LOCAL_V1" --not "$RELEASE_SHA" 2>/dev/null || true)"
  if [ -n "$LOST" ]; then
    echo "── commits die der Move von @v1 VERLIEREN würde: ──────────" >&2
    echo "$LOST" >&2
    echo "───────────────────────────────────────────────────────────" >&2
    die "$RELEASE_REF enthält obige @v1-commits nicht. Erst mergen/cherry-picken, dann erneut."
  fi
  ok "Verlust-Check: kein @v1-commit geht verloren"
fi

# ── Gate 3: Smoke MUSS grün sein für EXAKT diesen SHA ─────────
info "Smoke-Gate: $SMOKE_WORKFLOW-Lauf für $RELEASE_SHA …"
SMOKE_CONCL="$(gh run list --workflow="$SMOKE_WORKFLOW" -L 80 \
  --json headSha,conclusion,createdAt \
  --jq "[.[] | select(.headSha==\"$RELEASE_SHA\")] | sort_by(.createdAt) | last | .conclusion // \"NONE\"" \
  2>/dev/null || echo NONE)"
[ -n "$SMOKE_CONCL" ] || SMOKE_CONCL=NONE
case "$SMOKE_CONCL" in
  success) ok "Smoke grün für $RELEASE_SHA" ;;
  NONE)    die "Kein $SMOKE_WORKFLOW-Lauf für $RELEASE_SHA. Trigger den Smoke auf dem release-ref (temp push-Trigger) und warte auf grün, dann erneut." ;;
  *)       die "Smoke für $RELEASE_SHA ist '$SMOKE_CONCL' (nicht success). Erst grün machen." ;;
esac

# ── Gate 4: Version-Tag frei (unveränderlich) ─────────────────
if [ -n "$VERSION_TAG" ]; then
  if git rev-parse -q --verify "refs/tags/$VERSION_TAG" >/dev/null 2>&1 \
     || [ -n "$(git ls-remote origin "refs/tags/$VERSION_TAG" 2>/dev/null)" ]; then
    die "Version-Tag $VERSION_TAG existiert bereits (Punkt-Tags sind unveränderlich)."
  fi
  ok "Version-Tag $VERSION_TAG ist frei"
fi

# ── Zusammenfassung ───────────────────────────────────────────
echo ""
echo "── Release-Plan ──────────────────────────────────────────"
echo "   @v1:   ${LOCAL_V1:-<neu>}  →  $RELEASE_SHA"
[ -n "$VERSION_TAG" ] && echo "   Tag:   $VERSION_TAG → $RELEASE_SHA (neu)"
echo "   Smoke: success"
echo "──────────────────────────────────────────────────────────"

if [ "$DRY_RUN" = 1 ]; then
  ok "DRY-RUN — alle Gates bestanden, kein Tag/Push."
  exit 0
fi

# ── Gate 6: Bestätigung ───────────────────────────────────────
if [ "$ASSUME_YES" != 1 ]; then
  printf "Diesen @v1-Move ausführen? [yes/NO] "
  read -r reply
  [ "$reply" = "yes" ] || die "keine Bestätigung — abgebrochen."
fi

# ── Gate 5: Race-Recheck UNMITTELBAR vor dem Push ─────────────
REMOTE_NOW="$(git ls-remote origin 'refs/tags/v1^{}' | awk '{print $1}')"
if [ "${REMOTE_NOW:-}" != "${LOCAL_V1:-}" ]; then
  die "@v1 wurde seit Prüfbeginn bewegt (${LOCAL_V1:-<neu>} → ${REMOTE_NOW:-<weg>}) — Parallel-Session. Neu starten."
fi
ok "Race-Recheck: @v1 unverändert"

# ── Push (der eigentliche Move) ───────────────────────────────
if [ -n "$VERSION_TAG" ]; then
  git tag -a "$VERSION_TAG" -m "Release $VERSION_TAG" "$RELEASE_SHA"
  git push origin "$VERSION_TAG"
  ok "Punkt-Tag $VERSION_TAG gepusht"
fi
git tag -f -a v1 -m "v1 → ${VERSION_TAG:-$RELEASE_SHA}" "$RELEASE_SHA"
git push -f origin v1
ok "@v1 bewegt"

# ── Gate 7: Post-Verify ───────────────────────────────────────
FINAL="$(git ls-remote origin 'refs/tags/v1^{}' | awk '{print $1}')"
[ "$FINAL" = "$RELEASE_SHA" ] || die "Post-Verify FEHLGESCHLAGEN: remote @v1 = ${FINAL:-<leer>} (erwartet $RELEASE_SHA)."
ok "Post-Verify: remote @v1 = $RELEASE_SHA"
echo "🎉 Release fertig."
