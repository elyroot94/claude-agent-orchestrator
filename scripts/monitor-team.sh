#!/usr/bin/env bash
# ============================================================
# monitor-team.sh v2 — État des Agent Teams pour n8n (cron 10 min)
# Nouveauté : détecte les NOUVELLES escalades "needs-human" et les
# remonte en alerte (tu reçois le mail avec les questions à trancher).
# ============================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/votre-app}"
LOG_DIR="${LOG_DIR:-/var/log/agent-orchestrator}"
STATE_FILE="${LOG_DIR}/notified-escalations.txt"
STALL_MINUTES=30

cd "$REPO_DIR"
touch "$STATE_FILE"

SESSIONS_JSON="[]"
ALERTS="[]"

add_alert() {
  ALERTS=$(python3 - "$1" <<'PYEOF'
import json, sys
alerts = json.loads(open("/tmp/.alerts.json").read()) if __import__("os").path.exists("/tmp/.alerts.json") else []
alerts.append(sys.argv[1])
open("/tmp/.alerts.json","w").write(json.dumps(alerts))
print(json.dumps(alerts))
PYEOF
)
}
rm -f /tmp/.alerts.json

# --- Sessions tmux team-* ---
SESSIONS=$(tmux ls 2>/dev/null | grep '^team-' | cut -d: -f1 || true)
ENTRIES=""
for S in $SESSIONS; do
  LOG="${LOG_DIR}/${S}.log"
  if [ -f "$LOG" ]; then
    LAST_MOD=$(( ($(date +%s) - $(stat -c %Y "$LOG")) / 60 ))
  else
    LAST_MOD=-1
  fi
  ENTRIES+="{\"session\":\"$S\",\"idle_minutes\":$LAST_MOD},"
  # Alerte de stagnation : UNE seule fois par session (le log reste vide en
  # mode print tant que le lead n'a pas fini — ce n'est pas forcément un blocage)
  STALL_STATE="${LOG_DIR}/notified-stalls.txt"
  touch "$STALL_STATE"
  if [ "$LAST_MOD" -ge "$STALL_MINUTES" ] && ! grep -qx "$S" "$STALL_STATE"; then
    add_alert "Session $S sans sortie depuis ${LAST_MOD} min (peut être normal en mode print) — vérifier : tmux attach -t $S"
    echo "$S" >> "$STALL_STATE"
  fi
done
SESSIONS_JSON="[${ENTRIES%,}]"

# --- Sessions mortes avec issues encore en ai-in-progress ---
IN_PROGRESS=$(gh issue list --label "ai-in-progress" --json number -q '.[].number' | tr '\n' ' ')
DEAD_STATE="${LOG_DIR}/notified-dead-sessions.txt"
touch "$DEAD_STATE"
if [ -n "$IN_PROGRESS" ] && [ -z "$SESSIONS" ]; then
  SIG=$(echo "$IN_PROGRESS" | tr ' ' '\n' | sort -n | tr '\n' '-')
  if ! grep -qx "$SIG" "$DEAD_STATE"; then
    add_alert "Issues en ai-in-progress ($IN_PROGRESS) mais aucune session team active — session morte ? (alerte unique, relancer ou retirer le label)"
    echo "$SIG" >> "$DEAD_STATE"
  fi
fi

# --- NOUVELLES escalades needs-human (décisions métier à trancher) ---
ESCALATED=$(gh issue list --label "needs-human" --state open --json number,title \
  -q '.[] | (.number|tostring) + "|" + .title')
NEW_ESCALATIONS=""
while IFS='|' read -r NUM TITLE; do
  [ -z "$NUM" ] && continue
  if ! grep -qx "$NUM" "$STATE_FILE"; then
    NEW_ESCALATIONS+="#${NUM} (${TITLE}) "
    echo "$NUM" >> "$STATE_FILE"
  fi
done <<< "$ESCALATED"
if [ -n "$NEW_ESCALATIONS" ]; then
  add_alert "🧠 Décisions métier attendues sur : ${NEW_ESCALATIONS}— lis les questions en commentaire, réponds, puis remets le label ai-ready"
fi

# --- PRs ouvertes par les agents (signalées UNE seule fois chacune) ---
PR_STATE="${LOG_DIR}/notified-prs.txt"
touch "$PR_STATE"
PRS=$(gh pr list --state open --json number,title,headRefName,labels \
  -q '[.[] | select((.headRefName | startswith("ai/")) or (.headRefName | startswith("claude/issue")))]' 2>/dev/null || echo "[]")
PR_SUMMARY=$(echo "$PRS" | PR_STATE="$PR_STATE" python3 -c "
import json, os, sys
prs = json.load(sys.stdin)
state = os.environ['PR_STATE']
seen = set(open(state).read().split())
new = [p for p in prs if str(p['number']) not in seen]
sens = [p['number'] for p in new if any(l['name']=='sensitive-review' for l in p.get('labels',[]))]
out = []
if new: out.append('Nouvelles PR d agents a reviewer : ' + ', '.join('#%s %s' % (p['number'], p['title']) for p in new))
if sens: out.append('dont SENSIBLES (review approfondie) : %s' % sens)
print(' — '.join(out))
with open(state, 'a') as f:
    for p in new: f.write(str(p['number']) + '\n')
")
[ -n "$PR_SUMMARY" ] && add_alert "$PR_SUMMARY"

# --- Nouvelles issues regression (créées par run-e2e-regression.sh) ---
REG_STATE="${LOG_DIR}/notified-regressions.txt"
touch "$REG_STATE"
REGS=$(gh issue list --label regression --state open --json number,title \
  -q '.[] | (.number|tostring) + "|" + .title')
NEW_REGS=""
while IFS='|' read -r NUM TITLE; do
  [ -z "$NUM" ] && continue
  if ! grep -qx "$NUM" "$REG_STATE"; then
    NEW_REGS+="#${NUM} (${TITLE}) "
    echo "$NUM" >> "$REG_STATE"
  fi
done <<< "$REGS"
if [ -n "$NEW_REGS" ]; then
  add_alert "🚨 Régression e2e : ${NEW_REGS}— issue documentée créée, triage requis (poser ai-ready pour lancer la réparation)"
fi

python3 - <<PYEOF
import json, os
alerts = json.loads(open("/tmp/.alerts.json").read()) if os.path.exists("/tmp/.alerts.json") else []
print(json.dumps({
  "sessions": json.loads('''$SESSIONS_JSON'''),
  "open_prs": json.loads('''$PRS'''),
  "issues_in_progress": "$IN_PROGRESS".split(),
  "alerts": alerts
}))
PYEOF
