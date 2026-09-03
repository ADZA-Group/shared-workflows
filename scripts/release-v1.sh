#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# release-v1.sh <release-ref> <vX.Y.Z> [--yes] [--dry-run] [--no-wait]
#
# Stufe A (2026-09-03): erzeugt den KANDIDATEN-BRANCH `release-vX.Y.Z` und ueberlaesst
# Smokes + Tag-Move dem Workflow .github/workflows/release.yml. Kein lokaler
# Force-Push von v1 mehr — der Mensch (oder Agent) pusht nur einen Branch.
#
#   Kandidat = <release-ref> + EIN Commit, der alle internen Refs
#   `adza-group/shared-workflows/...@v1` auf `@release-vX.Y.Z` (den Kandidaten-BRANCH)
#   umschreibt — nicht auf den SHA: nur so loesen auch die VERSCHACHTELTEN Refs
#   (reusable-ci → security-scan → Composite) gegen den Rewrite-Commit auf (Codex A1).
#   Dazu `.release-source` (sha+version).
#   release.yml: prep → Smokes (Orchestrator, Docker-Push ubuntu+self-hosted,
#   Promotion) → Tag vX.Y.Z + v1-Move auf den ORIGINAL-SHA → Branch-Cleanup.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git-Bash unter Windows: 'refs/tags/v1^{}' nicht zu Pfad mangeln

DRY_RUN=0; ASSUME_YES=0; WAIT=1; RELEASE_REF=""; VERSION_TAG=""
die()  { echo "❌ ABBRUCH: $*" >&2; exit 1; }
info() { echo "▸ $*"; }
ok()   { echo "✓ $*"; }
for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --no-wait)  WAIT=0 ;;
    -*)         die "unbekanntes Flag: $arg" ;;
    *)
      if   [ -z "$RELEASE_REF" ]; then RELEASE_REF="$arg"
      elif [ -z "$VERSION_TAG" ]; then VERSION_TAG="$arg"
      else die "zu viele Argumente: $arg"; fi ;;
  esac
done
[ -n "$RELEASE_REF" ] && [ -n "$VERSION_TAG" ] || die "Usage: $0 <release-ref> <vX.Y.Z> [--yes] [--dry-run] [--no-wait]"
[[ "$VERSION_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version muss vX.Y.Z sein (ist '$VERSION_TAG')"
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) nicht gefunden."
[ -z "$(git status --porcelain)" ] || die "working tree nicht clean — erst committen/stashen."
ok "working tree clean"

info "fetch tags + refs …"
git fetch --tags --force origin >/dev/null 2>&1 || die "git fetch fehlgeschlagen."
git fetch origin >/dev/null 2>&1 || true
RELEASE_SHA="$(git rev-parse -q --verify "${RELEASE_REF}^{commit}" 2>/dev/null)" || die "release-ref '$RELEASE_REF' nicht aufloesbar."
ok "release-ref $RELEASE_REF → $RELEASE_SHA"

REMOTE_V1="$(git ls-remote origin 'refs/tags/v1^{}' | awk '{print $1}')"
if [ -n "$REMOTE_V1" ]; then
  ok "@v1 remote → $REMOTE_V1"
  git merge-base --is-ancestor "$REMOTE_V1" "$RELEASE_SHA" \
    || die "Verlust-Check: @v1 ($REMOTE_V1) ist kein Vorfahr von $RELEASE_SHA — erst mergen/cherry-picken."
  ok "Verlust-Check: @v1 ist Vorfahr des Kandidaten"
else
  info "⚠ @v1 existiert remote noch nicht (Erst-Setup)"
fi
[ -z "$(git ls-remote origin "refs/tags/$VERSION_TAG" 2>/dev/null)" ] || die "Version-Tag $VERSION_TAG existiert bereits."
ok "Version-Tag $VERSION_TAG ist frei"
BRANCH="release-${VERSION_TAG}"
[ -z "$(git ls-remote origin "refs/heads/$BRANCH" 2>/dev/null)" ] || die "Kandidaten-Branch $BRANCH existiert remote bereits (alter Release-Versuch? erst loeschen)."

TAG_NAME="$(git log -1 --format='%an' "$RELEASE_SHA")"; TAG_EMAIL="$(git log -1 --format='%ae' "$RELEASE_SHA")"
[ -n "$TAG_NAME" ] && [ -n "$TAG_EMAIL" ] || die "keine Committer-Identity aus der Historie ermittelbar."

echo ""
echo "── Release-Plan ──────────────────────────────────────────"
echo "   Kandidat: $BRANCH = $RELEASE_SHA + Rewrite-Commit (@v1 → @$BRANCH)"
echo "   Gates:    release.yml (Orchestrator · Docker-Push ubuntu+self-hosted · Promotion)"
echo "   Danach:   Tag $VERSION_TAG + @v1 → $RELEASE_SHA (durch den Workflow)"
echo "──────────────────────────────────────────────────────────"
if [ "$DRY_RUN" != 1 ] && [ "$ASSUME_YES" != 1 ]; then
  printf "Kandidaten-Branch pushen und Release-Workflow starten? [yes/NO] "
  read -r reply; [ "$reply" = "yes" ] || die "keine Bestaetigung — abgebrochen."
fi

# Kandidat in einem Wegwerf-Worktree bauen (der Checkout bleibt unberuehrt).
WT="$(mktemp -d)"; trap 'git worktree remove --force "$WT" >/dev/null 2>&1 || true' EXIT
git worktree add -q --detach "$WT" "$RELEASE_SHA"
(
  cd "$WT"
  # Nur die konkreten internen Refs umschreiben — nichts anderes im Repo. Pattern: `@v1`
  # NUR vor Whitespace/Zeilenende (exakte Pins wie `@v1.10.6` bleiben unberuehrt, Codex A3).
  grep -rlE 'adza-group/shared-workflows/[^@[:space:]]+@v1([[:space:]]|$)' .github | while read -r f; do
    sed -i -E "s#(adza-group/shared-workflows/[^@[:space:]]+)@v1([[:space:]]|\$)#\1@${BRANCH}\2#g" "$f"
  done
  if grep -rEn 'adza-group/shared-workflows/[^@[:space:]]+@v1([[:space:]]|$)' .github; then
    echo "::error::Rewrite unvollstaendig" >&2; exit 1
  fi
  printf 'sha=%s\nversion=%s\n' "$RELEASE_SHA" "$VERSION_TAG" > .release-source
  git checkout -q -b "$BRANCH"
  git add -A .github .release-source
  git -c user.name="$TAG_NAME" -c user.email="$TAG_EMAIL" commit -q -m "release-candidate: $VERSION_TAG — internal refs @v1 -> @${BRANCH}

Wegwerf-Commit fuer release.yml (Kandidaten-Branch). Getaggt wird ${RELEASE_SHA}."
  N=$(grep -rhoE "adza-group/shared-workflows/[^@[:space:]]+@${BRANCH}([[:space:]]|\$)" .github | wc -l)
  echo "▸ Rewrite: $N interne Refs → @${BRANCH} ($(git diff --stat HEAD^ HEAD | tail -1))"
  if [ "$DRY_RUN" = 1 ]; then
    echo "✓ DRY-RUN — Kandidat lokal gebaut und validiert (Codex A-R2: Dry-Run prueft den Rewrite), kein Push."
    exit 0
  fi
  git push -q origin "$BRANCH"
)
[ "$DRY_RUN" = 1 ] && exit 0
ok "Kandidaten-Branch $BRANCH gepusht — release.yml laeuft"

[ "$WAIT" = 1 ] || { info "--no-wait: Fortschritt: gh run list --workflow release.yml --branch $BRANCH"; exit 0; }
info "warte auf den Release-Lauf …"
RUN_ID=""
for _ in $(seq 1 30); do
  RUN_ID="$(gh run list --workflow=release.yml --branch="$BRANCH" -L 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"
  [ -n "$RUN_ID" ] && break; sleep 5
done
[ -n "$RUN_ID" ] || die "kein release.yml-Lauf fuer $BRANCH gefunden (Trigger? Actions deaktiviert?)."
info "Run $RUN_ID — gh run watch …"
gh run watch "$RUN_ID" --exit-status >/dev/null 2>&1 || die "Release-Lauf $RUN_ID ist NICHT gruen: gh run view $RUN_ID --log-failed"
FINAL="$(git ls-remote origin 'refs/tags/v1^{}' | awk '{print $1}')"
[ "$FINAL" = "$RELEASE_SHA" ] || die "Post-Verify: remote @v1 = ${FINAL:-leer}, erwartet $RELEASE_SHA"
ok "Post-Verify: remote @v1 = $RELEASE_SHA ($VERSION_TAG)"
echo "🎉 Release fertig."
