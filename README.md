# Claude Agent Orchestrator

**Un pipeline complet qui transforme des issues GitHub en Pull Requests — implémentées, testées et documentées par des équipes d'agents Claude, avec l'humain aux commandes des décisions.**

> *English TL;DR — A production-tested pipeline that turns GitHub issues into pull requests using Claude Code Agent Teams, orchestrated by n8n on a self-hosted VPS. A GitHub label (`ai-ready`) triggers everything: batch selection, model routing (Opus/Fable by sensitivity), tmux-isolated agent teams, TDD implementation in git worktrees, documented PRs, email monitoring, and a Playwright e2e regression net that files a root-caused issue after every merge that breaks something. Humans keep exclusive control of labels, merges and business arbitration.*

Ce dépôt est le résultat d'une mise en place réelle sur un projet de production (app full-stack Spring Boot + Next.js). Tout ce qui s'y trouve a tourné, cassé, été réparé — et les leçons sont documentées dans [docs/LECONS-APPRISES.md](docs/LECONS-APPRISES.md).

## Le principe en une image

```
   VOUS                    GITHUB                       VPS (n8n + Claude Code)
    │                        │                                │
    │  pose le label         │  webhook "issues"              │
    │  ai-ready ────────────▶│───────────────────────────────▶│ n8n : filtre, attend 5 s,
    │                        │                                │ liste les issues ai-ready,
    │                        │                                │ constitue le LOT (max 3) et
    │                        │                                │ choisit le MODÈLE :
    │                        │                                │  sensitive/complex → Fable
    │                        │                                │  sinon             → Opus
    │                        │                                ▼
    │                        │                      launch-team.sh (tmux)
    │                        │                      TEAM LEAD (delegate mode)
    │                        │                        ├─ lit le contexte projet
    │                        │                        ├─ lit VOS réponses en commentaires
    │                        │                        ├─ tranche les décisions ouvertes
    │                        │                        │  (documentées, arbitrables)
    │                        │                        └─ 1 teammate / issue
    │                        │                           (git worktree isolé, TDD)
    │                        │◀───────────────────────  PR "Closes #N" + labels
    │  review + MERGE ──────▶│                                │
    │  (réservé à l'humain)  │  webhook "pull_request"        │
    │                        │───────────────────────────────▶│ run-e2e-regression.sh
    │                        │                                │ (Playwright sur main)
    │                        │◀─── issue [REGRESSION] ────────│ si échec : issue documentée
    │  email ◀── monitoring (cron 10 min) : PRs à reviewer, escalades, régressions
```

## La machine à états des labels

| Label | Posé par | Signification |
|---|---|---|
| `ai-ready` | **humain uniquement** | issue prête → déclenche le pipeline |
| `ai-in-progress` | pipeline | une team travaille dessus (retiré à l'ouverture de la PR) |
| `needs-human` | team lead | escalade bloquante (interdits techniques uniquement) |
| `needs-decision` | team lead | PR livrée avec des décisions par défaut à arbitrer en review |
| `sensitive` | humain | paiement/auth/sécurité → routage vers le modèle le plus capable |
| `complex` | humain | architecture/décisions lourdes → idem |
| `sensitive-review` | team lead | PR sensible → review humaine approfondie exigée |
| `ai-blocked` | team lead | échec répété, diagnostic en commentaire |
| `regression` + `needs-triage` | e2e net | régression détectée post-merge, issue documentée |

## Philosophie : l'humain décide, les agents exécutent

1. **`ai-ready` n'est posé que par un humain.** Rien ne démarre sans vous.
2. **Les agents n'escaladent plus sur les décisions métier** : ils implémentent l'option la plus raisonnable et réversible, la documentent (commentaire d'issue + section « Décisions à arbitrer » dans la PR) et **vous tranchez à la review**. Si vous arbitrez différemment : commentez l'issue et reposez `ai-ready` — vos réponses sont injectées dans le prompt du run suivant et **priment**.
3. **Interdits techniques absolus** (seul cas d'escalade bloquante) : migrations de BDD, workflows CI, secrets, `push --force`, branche `main`, merge. Doublés d'un blocage **technique** (deny-list `.claude/settings.json` + scope du token).
4. **Le merge est réservé à l'humain.** Toujours.
5. **Chaque merge est re-testé** de bout en bout (Playwright), chaque nuit aussi. Une régression devient une issue avec reproduction, cause racine analysée par Claude (diff de la PR fautive à l'appui) et artefacts.

## Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `scripts/launch-team.sh` | lance une Agent Team dans tmux : garde-fou de concurrence, injection titre+corps+**commentaires** des issues dans le prompt, bascule des labels, routage modèle via `MODEL=` |
| `scripts/monitor-team.sh` | état des teams pour le cron n8n : sessions bloquées, sessions mortes, nouvelles escalades, nouvelles PRs, nouvelles régressions — **tout dédoublonné** (une alerte = un email, pas un spam toutes les 10 min) |
| `scripts/run-e2e-regression.sh` | filet anti-régression : run Playwright détaché en tmux, verrou de concurrence, **attend la fin des teams** (partage de la RAM), dédoublonnage des issues, analyse du diff par Claude, issue documentée |
| `prompts/team-lead.md` | le prompt du team lead : delegate mode, test des décisions ouvertes, décisions par défaut documentées, TDD obligatoire, livraison PR normée, interdits |
| `n8n/*.json` | les 4 workflows : lancement (webhook issues), monitoring (cron 10 min), régression post-merge (webhook PRs), nightly (cron 03h00) |
| `setup/github-labels.sh` | création des labels du cycle |
| `docs/LECONS-APPRISES.md` | tous les pièges rencontrés en vrai, et leurs solutions |

## Mise en place (résumé)

**Prérequis** : un VPS (4 cœurs / 16 Go suffisent), n8n (Docker), Node 22, tmux, `gh` CLI authentifié avec un token *fine-grained* limité au repo, Claude Code CLI (abonnement Claude), un repo GitHub avec un `CLAUDE.md` de contexte.

1. **VPS** : copiez `scripts/` vers `/opt/agent-orchestrator/`, `chmod +x`, créez `/var/log/agent-orchestrator/`. Clonez votre repo dans `/opt/votre-app` (+ un clone séparé pour l'e2e). Configurez `git config --global user.name/email` (sinon aucun commit ne passera — vécu).
2. **Labels** : `./setup/github-labels.sh OWNER/REPO`
3. **n8n** : importez les 4 workflows, recréez vos credentials (SSH par clé vers le VPS, GitHub API, SMTP), remplacez les placeholders (`OWNER/REPO`, emails), **activez**.
4. **Webhooks GitHub** (repo → Settings → Webhooks) : un webhook *Issues* vers `/webhook/...-issues`, un webhook *Pull requests* vers `/webhook/...-prs`.
5. **Permissions agents** : committez un `.claude/settings.json` dans votre repo avec une allow-list (git/gh/outils de build) et une **deny-list** (workflows CI, migrations, `.env`, force-push) — des exemples dans les leçons.
6. **Suite e2e** : le script de régression attend un contrat simple — `e2e/package.json` (Playwright), `e2e/start-env.sh` (démarre l'app de test, bloquant jusqu'à prêt), `e2e/stop-env.sh`. Astuce : faites construire ce socle **par le pipeline lui-même** (c'est ce qu'on a fait).
7. Posez `ai-ready` sur une issue simple et regardez la cascade. 🎉

## Maîtrise des coûts (abonnement Claude)

- Routage : ordinaire → Opus, `sensitive`/`complex` → Fable. Un label `simple` → Sonnet est un bon levier supplémentaire.
- Lots de 2-3 issues : un seul lead amorti sur plusieurs implémentations.
- Si vous utilisez l'action GitHub `claude-code-review`, limitez-la à `types: [opened]` — par défaut elle re-review à **chaque push**.
- Une session tuée par la limite de quota n'est pas perdue : committez/poussez le worktree, commentez l'issue avec la consigne de reprise (les commentaires sont injectés), relancez. Le lead reprendra là où c'était arrêté.

## Licence

MIT — servez-vous, améliorez, partagez.
