#!/usr/bin/env bash
# ============================================================
# launch-team.sh v2 — Lance une Agent Team Claude Code dans tmux
# Appelé par n8n via SSH :
#   MODEL=claude-fable-5 ./launch-team.sh 42 57   (issues sensibles)
#   ./launch-team.sh 42 57                        (Opus par défaut)
# ============================================================
set -euo pipefail

# ---------- CONFIGURATION (à adapter) ----------
REPO_DIR="${REPO_DIR:-/opt/votre-app}"
PROMPT_TEMPLATE="${PROMPT_TEMPLATE:-/opt/agent-orchestrator/prompt-team-lead.md}"
LOG_DIR="${LOG_DIR:-/var/log/agent-orchestrator}"
MAX_CONCURRENT_TEAMS=1
MODEL="${MODEL:-claude-opus-4-8}"   # routé par n8n : fable-5 si lot sensible
# ------------------------------------------------

if [ "$#" -lt 1 ]; then
  echo "Usage: [MODEL=...] $0 <issue#> [issue# ...]" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
BATCH_ID="$(date +%Y%m%d-%H%M%S)"
SESSION="team-${BATCH_ID}"
ISSUES=("$@")

RUNNING=$(tmux ls 2>/dev/null | grep -c '^team-' || true)
if [ "$RUNNING" -ge "$MAX_CONCURRENT_TEAMS" ]; then
  echo "{\"status\":\"refused\",\"reason\":\"${RUNNING} team(s) deja en cours\"}"
  exit 0
fi

command -v claude >/dev/null || { echo '{"status":"error","reason":"claude CLI absent"}'; exit 1; }
command -v gh >/dev/null     || { echo '{"status":"error","reason":"gh CLI absent"}'; exit 1; }
gh auth status >/dev/null 2>&1 || { echo '{"status":"error","reason":"gh non authentifie"}'; exit 1; }
cd "$REPO_DIR"
git fetch origin && git checkout main -q && git pull --ff-only -q

ISSUES_BLOCK=""
for N in "${ISSUES[@]}"; do
  TITLE=$(gh issue view "$N" --json title -q .title)
  BODY=$(gh issue view "$N" --json body -q .body | head -c 4000)
  # Inclure les commentaires : c'est là que vivent tes réponses aux escalades
  COMMENTS=$(gh issue view "$N" --json comments \
    -q '[.comments[] | "— " + .author.login + " : " + .body] | join("\n")' | head -c 3000)
  ISSUES_BLOCK+=$'\n'"### Issue #${N} — ${TITLE}"$'\n'"${BODY}"$'\n'
  [ -n "$COMMENTS" ] && ISSUES_BLOCK+=$'\n'"#### Commentaires (dont réponses du propriétaire)"$'\n'"${COMMENTS}"$'\n'
  gh issue edit "$N" --add-label "ai-in-progress" --remove-label "ai-ready" || true
done

PROMPT_FILE="${LOG_DIR}/prompt-${BATCH_ID}.md"
python3 - "$PROMPT_TEMPLATE" "$PROMPT_FILE" <<PYEOF
import sys
template = open(sys.argv[1]).read()
issues_block = """${ISSUES_BLOCK}"""
open(sys.argv[2], "w").write(template.replace("{{ISSUES}}", issues_block))
PYEOF

tmux new-session -d -s "$SESSION" -c "$REPO_DIR" \
  "export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1; export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0; \
   claude --model '$MODEL' \"\$(cat '$PROMPT_FILE')\" 2>&1 | tee '${LOG_DIR}/${SESSION}.log'"

echo "{\"status\":\"launched\",\"session\":\"${SESSION}\",\"model\":\"${MODEL}\",\"issues\":\"${ISSUES[*]}\",\"log\":\"${LOG_DIR}/${SESSION}.log\"}"
