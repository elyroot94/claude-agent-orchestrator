#!/usr/bin/env bash
# ============================================================
# run-e2e-regression.sh — Suite e2e Playwright sur main + issue
# documentée en cas de régression. Appelé par n8n :
#   ./run-e2e-regression.sh --pr 214 --sha abc123    (post-merge)
#   ./run-e2e-regression.sh --nightly                (cron nuit)
# Lance le vrai travail détaché dans tmux (session e2e-<ts>) et
# rend la main immédiatement (JSON sur stdout pour n8n).
#
# CONTRAT avec la suite e2e (créée par l'issue d'audit) :
#   e2e/package.json           npm ci puis npx playwright test
#   e2e/start-env.sh (exéc.)   démarre l'app de test (bloquant jusqu'à prêt)
#   e2e/stop-env.sh  (exéc.)   arrête et nettoie l'environnement
# ============================================================
set -euo pipefail

REPO_DIR="${E2E_REPO_DIR:-/home/deploy/votre-app-e2e}"
LOG_DIR="${E2E_LOG_DIR:-/var/log/agent-orchestrator/e2e}"
REPO="OWNER/REPO"
LOCK_DIR="/tmp/gp-e2e.lock"
TEAM_WAIT_MAX=2700          # attente max (s) si une team d'agents tourne
CLAUDE_MODEL="claude-sonnet-5"

PR=""; SHA=""; NIGHTLY=0; EXEC=0
while [ $# -gt 0 ]; do case "$1" in
  --pr) PR="$2"; shift 2;;
  --sha) SHA="$2"; shift 2;;
  --nightly) NIGHTLY=1; shift;;
  --exec) EXEC=1; shift;;
  *) shift;;
esac; done

mkdir -p "$LOG_DIR"

# ---------- Mode lanceur (appelé par n8n) : détache et répond ----------
if [ "$EXEC" -eq 0 ]; then
  if [ -d "$LOCK_DIR" ]; then
    echo '{"status":"skipped","reason":"un run e2e est deja en cours"}'
    exit 0
  fi
  RUN_ID="e2e-$(date +%Y%m%d-%H%M%S)"
  ARGS="--exec"
  [ -n "$PR" ] && ARGS="$ARGS --pr $PR"
  [ -n "$SHA" ] && ARGS="$ARGS --sha $SHA"
  [ "$NIGHTLY" -eq 1 ] && ARGS="$ARGS --nightly"
  tmux new-session -d -s "$RUN_ID" \
    "$0 $ARGS 2>&1 | tee '$LOG_DIR/${RUN_ID}.log'"
  echo "{\"status\":\"launched\",\"session\":\"$RUN_ID\",\"pr\":\"${PR:-nightly}\",\"log\":\"$LOG_DIR/${RUN_ID}.log\"}"
  exit 0
fi

# ---------- Mode exécution (dans tmux) ----------
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "[e2e] run concurrent détecté, abandon"; exit 0
fi
STOP_ENV=""
cleanup() {
  [ -n "$STOP_ENV" ] && "$STOP_ENV" >> "$RUN_DIR/env.log" 2>&1 || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Attendre que les teams d'agents soient terminées (partage des 16 GB)
WAITED=0
while tmux ls 2>/dev/null | grep -q '^team-'; do
  if [ "$WAITED" -ge "$TEAM_WAIT_MAX" ]; then
    echo "[e2e] teams toujours actives après $((TEAM_WAIT_MAX/60)) min — run annulé (sera rejoué au prochain déclencheur)"
    exit 0
  fi
  echo "[e2e] team active, attente 60s..."
  sleep 60; WAITED=$((WAITED+60))
done

RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$LOG_DIR/$RUN_ID"; mkdir -p "$RUN_DIR"
echo "[e2e] démarrage $RUN_ID (PR=${PR:-nightly})"

cd "$REPO_DIR"
git fetch origin -q && git checkout main -q && git pull --ff-only -q
HEAD_SHA=$(git rev-parse --short HEAD)
echo "[e2e] main @ $HEAD_SHA"

if [ ! -d e2e ]; then
  echo "[e2e] pas de dossier e2e/ sur main — la suite n'existe pas encore, rien à tester"
  exit 0
fi

# Environnement de test (contrat)
if [ -x e2e/start-env.sh ]; then
  echo "[e2e] démarrage environnement de test..."
  if ! ./e2e/start-env.sh > "$RUN_DIR/env.log" 2>&1; then
    echo "[e2e] ERREUR: start-env.sh a échoué (voir $RUN_DIR/env.log)"
    exit 1
  fi
  [ -x e2e/stop-env.sh ] && STOP_ENV="$REPO_DIR/e2e/stop-env.sh"
else
  echo "[e2e] AVERTISSEMENT: e2e/start-env.sh absent — on suppose l'app déjà accessible"
fi

cd e2e
npm ci --silent > "$RUN_DIR/npm.log" 2>&1
npx playwright install chromium > /dev/null 2>&1 || true
echo "[e2e] exécution de la suite Playwright..."
set +e
nice -n 10 npx playwright test --reporter=json > "$RUN_DIR/report.json" 2> "$RUN_DIR/stderr.log"
PW_EXIT=$?
set -e
cd "$REPO_DIR"
cp -r e2e/test-results "$RUN_DIR/artifacts" 2>/dev/null || true

# ---------- Analyse du rapport ----------
RUN_DIR="$RUN_DIR" python3 > "$RUN_DIR/.summary" <<'PYEOF'
import json, os
run_dir = os.environ["RUN_DIR"]
try:
    r = json.load(open(f"{run_dir}/report.json"))
except Exception:
    print("PARSE_ERROR|0|0"); raise SystemExit
failed, passed, lines = 0, 0, []
def walk(suites, path=""):
    global failed, passed
    for s in suites:
        p = f"{path}{s.get('title','')} > " if s.get('title') else path
        for sp in s.get('specs', []):
            name = f"{s.get('file', sp.get('file','?'))} > {p}{sp['title']}"
            ok = all(all(res.get('status') in ('passed','skipped') for res in t.get('results',[])) for t in sp.get('tests',[]))
            if sp.get('ok', ok) and ok: passed += 1
            else:
                failed += 1
                err = ""
                for t in sp.get('tests', []):
                    for res in t.get('results', []):
                        e = res.get('error', {}) or {}
                        if e.get('message'): err = e['message'][:400]; break
                lines.append(f"- `{name}`\n  Erreur : {err}")
        walk(s.get('suites', []), p)
walk(r.get('suites', []))
open(f"{run_dir}/failures.md","w").write("\n".join(lines))
print(f"OK|{failed}|{passed}")
PYEOF
SUMMARY=$(cat "$RUN_DIR/.summary")
STATE=$(echo "$SUMMARY" | cut -d'|' -f1)
FAILED=$(echo "$SUMMARY" | cut -d'|' -f2)
PASSED=$(echo "$SUMMARY" | cut -d'|' -f3)
echo "[e2e] résultat : $PASSED passed, $FAILED failed (exit=$PW_EXIT, parse=$STATE)"

if [ "$STATE" != "OK" ]; then
  echo "[e2e] ERREUR: rapport illisible — voir $RUN_DIR"
  exit 1
fi
if [ "$FAILED" -eq 0 ]; then
  echo "[e2e] ✅ aucune régression (main @ $HEAD_SHA)"
  exit 0
fi

# ---------- Dédoublonnage ----------
EXISTING=$(gh issue list -R "$REPO" --label regression --state open --json body -q '[.[].body] | join("\n")' 2>/dev/null || echo "")
EXISTING="$EXISTING" RUN_DIR="$RUN_DIR" python3 > "$RUN_DIR/.newfails" <<'PYEOF'
import os
existing = os.environ["EXISTING"]
out = []
for block in open(f'{os.environ["RUN_DIR"]}/failures.md').read().split("\n- "):
    if not block.strip(): continue
    spec = block.split("`")[1] if "`" in block else block[:80]
    if spec not in existing:
        out.append(("- " + block) if not block.startswith("-") else block)
print("\n".join(out))
PYEOF
NEW_FAILS=$(cat "$RUN_DIR/.newfails")
if [ -z "$NEW_FAILS" ]; then
  echo "[e2e] échecs déjà couverts par des issues regression ouvertes — pas de doublon créé"
  exit 0
fi

# ---------- Analyse préliminaire par Claude (best effort) ----------
DIFF=""
[ -n "$PR" ] && DIFF=$(gh pr diff "$PR" -R "$REPO" 2>/dev/null | head -c 15000 || true)
ANALYSIS="(analyse automatique indisponible)"
if command -v claude >/dev/null && [ -n "$DIFF" ]; then
  set +e
  ANALYSIS=$(timeout 180 claude --model "$CLAUDE_MODEL" -p \
"Tu analyses une régression e2e. Tests en échec :
$NEW_FAILS

Diff de la PR #$PR fraîchement mergée (tronqué) :
$DIFF

En 5-10 lignes : quelle est la cause la plus probable du lien entre ce diff et ces échecs ? Quels fichiers regarder en premier ? Réponds en français, factuel, sans préambule." 2>/dev/null | head -c 3000)
  set -e
  [ -z "$ANALYSIS" ] && ANALYSIS="(analyse automatique indisponible)"
fi

# ---------- Création de l'issue ----------
if [ -n "$PR" ]; then
  TITLE="[REGRESSION] $FAILED test(s) e2e en échec après merge de #$PR"
  ORIGINE="après le merge de #$PR (commit \`${SHA:-$HEAD_SHA}\`)"
else
  TITLE="[REGRESSION] $FAILED test(s) e2e en échec (run nightly)"
  ORIGINE="lors du run nightly (main @ \`$HEAD_SHA\`)"
fi
BODY_FILE="$RUN_DIR/issue-body.md"
cat > "$BODY_FILE" <<EOF
## Contexte
Régression détectée $ORIGINE le $(date '+%Y-%m-%d %H:%M').
Suite e2e : **$PASSED passed / $FAILED failed**.

## Tests en échec
$NEW_FAILS

## Reproduction
\`\`\`bash
cd e2e && npm ci && npx playwright test
\`\`\`
Artefacts (traces, screenshots) : \`$RUN_DIR/\` sur le VPS.

## Analyse préliminaire (générée automatiquement — à confirmer par un humain)
$ANALYSIS

---
_Issue créée automatiquement par run-e2e-regression.sh. Après triage,
poser \`ai-ready\` pour lancer la réparation par l'agent team._
EOF
URL=$(gh issue create -R "$REPO" --title "$TITLE" --body-file "$BODY_FILE" \
  --label regression --label needs-triage 2>&1 | tail -1)
echo "[e2e] 🚨 issue créée : $URL"
