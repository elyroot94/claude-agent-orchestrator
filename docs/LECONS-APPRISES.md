# Leçons apprises (sur le terrain)

Tout ce qui suit est arrivé pour de vrai pendant la mise en place. Chaque piège a coûté du temps de debug — les voici avec leurs solutions, pour que vous n'ayez pas à les repayer.

## n8n

**1. « No output data » après le webhook GitHub : course de propagation.**
Le webhook `labeled` part *immédiatement* quand vous posez un label ; si vous interrogez l'API GitHub (`/issues?labels=ai-ready`) 300 ms plus tard, une réplique de lecture peut ne pas encore voir le label → liste vide → le workflow s'arrête « avec succès » sans rien faire.
✅ **Solution : un node Wait de 5 secondes** entre le webhook et l'appel API. C'est le node le plus rentable du pipeline.

**2. Emails vides : le piège `Email Format`.**
Le node *Send Email* (v2.x) a un paramètre `emailFormat` dont le défaut est `html`. Si vous remplissez le champ **Text** sans forcer `emailFormat: "text"`, le node envoie le champ HTML (vide) et ignore votre texte. Résultat : des emails avec juste le pied de page n8n.
✅ Toujours poser explicitement `"emailFormat": "text"` (ou remplir le champ HTML).

**3. `n8n import:workflow` désactive le workflow importé.**
Après chaque import CLI : `n8n update:workflow --id=… --active=true` **puis redémarrage du conteneur** (l'instance en mémoire ne recharge pas toute seule).

**4. Un « Save » depuis une page n8n non rechargée écrase vos modifications CLI.**
Vécu : un Save UI a remis les paramètres d'un node Wait à zéro → le défaut du node étant **1 heure**, le pipeline serait resté muet une heure par run. Rechargez la page avant d'éditer, et re-vérifiez les paramètres critiques après tout Save.

**5. Archivez les doublons de workflows.**
Un vieux workflow inactif avec un node cassé vous fera perdre des heures le jour où vous ferez « Execute step » dedans en croyant être dans le bon.

## Claude Code / Agent Teams

**6. Mode non-interactif : les teammates de fond sont tués après 600 s.**
`claude "<prompt>"` avec stdout pipé passe en mode *print* ; quand le lead finit son message, le CLI attend les tâches de fond au maximum 10 minutes puis **les termine**. Votre teammate meurt en plein TDD.
✅ `export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` dans la commande tmux.

**7. Identité git : configurez-la AVANT le premier run.**
Sans `git config --global user.name/email` pour l'utilisateur du VPS, aucun commit ne passe — et les agents n'ont pas le droit de la configurer eux-mêmes (`git config` hors allow-list, à juste titre). Symptôme : code fini, tests verts, zéro PR.

**8. Les conventions du repo sont plus fortes que le prompt.**
Notre prompt exigeait des branches `ai/issue-N-slug` ; l'historique du repo contenait des branches `claude/issue-N` → les teammates ont reproduit l'ancienne convention **deux fois**, créant des PRs invisibles du monitoring (et des doublons). Consigne durcie + filtre du monitoring élargi. Moralité : ce que les agents *voient* dans le repo pèse autant que ce qu'on leur *dit*.

**9. Une session tuée par la limite de quota se récupère très bien.**
Procédure : committer le travail en cours du worktree (`wip`), pousser la branche, **commenter l'issue** avec la consigne de reprise (« ne repars pas de zéro, reprends cette branche »), nettoyer le worktree local, relancer. Les commentaires étant injectés dans le prompt, le nouveau lead reprend exactement où c'était arrêté.

**10. En mode print, le log est vide jusqu'à la fin.**
Ne surveillez pas la « fraîcheur » du fichier de log pour détecter un blocage (faux positifs garantis) — surveillez les effets observables : labels GitHub, commits dans le worktree, processus gradle/npm actifs, PR.

**11. Allow-list : pensez aux cas d'usage complets.**
Nos agents n'avaient ni `gh issue create` (impossible de créer les issues de régression prévues par leur propre spec !) ni `gh pr close` (impossible de fermer leurs doublons) ni `rm`/`git rm` (impossible de finaliser une purge de fichiers). Chaque manque = une escalade humaine évitable. Auditez l'allow-list par rapport aux livrables attendus. Gardez `git config`, la CI et les migrations dans la deny-list.

## Monitoring

**12. Dédoublonnez TOUTES les alertes récurrentes.**
Une PR ouverte, une session « inactive », des issues `ai-in-progress` sans session : si l'alerte n'est pas mémorisée (fichier d'état), vous recevez le même email **toutes les 10 minutes**. Chaque type d'alerte a son fichier `notified-*.txt`.

**13. Retirez `ai-in-progress` à l'ouverture de la PR.**
Sinon, après chaque lot terminé, le monitoring hurle « session morte ? » jusqu'au merge. C'est le lead qui doit le faire (une ligne dans le prompt).

## E2E / régression

**14. Faites construire la suite e2e par le pipeline lui-même.**
Deux issues bien spécifiées (socle + couverture du cahier des charges) et les agents livrent l'infrastructure Playwright complète — y compris un `CONFORMITE.md` qui mappe chaque story de la roadmap à sa spec.

**15. Le filet attrape des vrais poissons dès le premier jour.**
Notre suite de conformité a découvert qu'une fonctionnalité marquée ✅ en roadmap renvoyait un 500 systématique en réalité (violation de FK masquée par un rollback silencieux) — jamais vue par les tests d'intégration qui mockaient la couche fautive. L'issue générée contenait reproduction + cause racine ; la réparation a été faite… par le pipeline.

**16. Sur un VPS partagé, sérialisez agents et e2e.**
Un run e2e full-stack (app + Kafka + navigateurs) et une team en pleine compilation ne tiennent pas ensemble dans 16 Go. Le script e2e prend un verrou et **attend la fin des teams** (avec plafond) avant de tourner.

## Stripe (bonus infra)

**17. La version d'API d'un endpoint webhook ne se change PAS.**
Elle se fixe **à la création** de l'endpoint, ni le dashboard ni l'API ne permettent de la modifier ensuite. « Épingler la version » = créer un nouvel endpoint épinglé + basculer le signing secret + recréer le backend. La version à épingler est celle de votre SDK (constante embarquée dans la lib).

**18. Vérifiez que vos webhooks existent vraiment.**
Nous avons découvert que le `STRIPE_WEBHOOK_SECRET` de la prod pointait dans le vide : **aucun endpoint n'avait jamais été créé**. L'app ne recevait aucun événement paiement. Un `curl /v1/webhook_endpoints` vaut mieux que des suppositions — et un test de livraison de bout en bout (PaymentIntent de test → log du backend) vaut mieux que tout.

## SSH / sécurité

**19. Désactiver l'authentification par mot de passe : dans l'ordre.**
Inventoriez d'abord *tout* ce qui se connecte (vous, vos machines, n8n !) et migrez chacun sur clé **avant** de couper. Et attention : dans `sshd_config.d/`, c'est la **première** occurrence d'une directive qui gagne — un `50-cloud-init.conf` avec `PasswordAuthentication yes` battra votre `99-hardening.conf` ; nommez le vôtre `00-…`. Validez avec `sshd -t` avant de recharger.
