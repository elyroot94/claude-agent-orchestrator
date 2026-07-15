#!/usr/bin/env bash
# Crée les labels du cycle de l'orchestrateur.
# Usage: ./github-labels.sh OWNER/REPO
set -euo pipefail
REPO="${1:?Usage: $0 OWNER/REPO}"
lab() { gh label create "$1" -R "$REPO" --color "$2" --description "$3" 2>/dev/null || echo "label $1 existe déjà"; }
lab ai-ready            "0E8A16" "Prête pour le pipeline (posé par un humain uniquement)"
lab ai-in-progress      "FBCA04" "Une team d agents travaille dessus"
lab ai-blocked          "B60205" "Echec répété - diagnostic en commentaire"
lab needs-human         "D93F0B" "Escalade bloquante (interdits techniques)"
lab needs-decision      "FBCA04" "PR avec décisions par défaut à arbitrer"
lab sensitive           "B60205" "Paiement / auth / sécurité - modèle renforcé"
lab sensitive-review    "B60205" "PR sensible - review humaine approfondie"
lab complex             "1D76DB" "Architecture / décision lourde - modèle renforcé"
lab regression          "D93F0B" "Régression détectée par les e2e"
lab needs-triage        "FBCA04" "A trier par le propriétaire"
echo "✅ Labels en place sur $REPO"
