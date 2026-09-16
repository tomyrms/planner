# Planner — règles de développement

Lire d'abord `../IOS_AI_PLANNER_DEEP_RESEARCH_2026-09-15/AGENTS.md` et sa table normative. Les décisions du pack s'appliquent à ce dépôt. Le produit V1 reste iPhone-first ; ce dépôt contient son backend, pas un client Windows.

- TypeScript ESM strict, imports locaux suffixés `.js`, dépendances exactes et lockfile.
- Étapes 1 à 3 livrées, plus la voix côté serveur : temps, fixtures JSON partagées, PostgreSQL, appairage, upload des commandes, PowerSync auto-hébergé (toujours candidat, ADR-004 et ADR-028), export, sauvegarde, assistant (ADR-029), transcription (ADR-030). Toute écriture de domaine passe par `executeCommand` ou `executePlan` ; aucune route CRUD.
- Le backend n'est plus étendu avant le spike PowerSync Swift (étape 5), sauf correctif ou besoin révélé par l'iPhone.
- Voix : jamais d'audio en base, en sauvegarde ou dans les journaux ; jamais le texte transcrit dans les journaux. Chaque envoi au fournisseur compte dans le budget.
- Nouvelle table : la classer dans `REQUIRED_TABLES` ou `TRANSIENT_TABLES` (`src/infrastructure/db/backup-plan.ts`), sinon un test échoue.
- Partager le projet : `scripts/export-review.ps1`, jamais un ZIP du dossier.
- **Dépôt public** (`github.com/tomyrms/planner`, ADR-031) : rien de personnel ni de secret, identité Git anonyme (`tomy.rms`, adresse noreply) configurée dans ce dépôt ; vérifier chaque diff avant push.
- App iPhone (`ios/`) : écrite depuis Windows, **compilée par le workflow `iOS`** (Xcode 26.3, SDK iOS 26.2). Ne dire « compilé » que si ce workflow est vert sur le commit, « testé » qu'après essai sur l'iPhone. Swift 6, isolation Main Actor par défaut, Approachable Concurrency ; ajouter un fichier dans `ios/Planner/` suffit (dossier synchronisé), jamais d'édition manuelle de `project.pbxproj` pour cela ; réglages dans `ios/Config/*.xcconfig`, équipe de signature seulement dans `Local.xcconfig` (ignoré).
- Assistant : changer le prompt, un schéma d'outil ou la logique temporelle impose de rejouer `fixtures/assistant/eval-v1.json` (test, puis `npm run eval:assistant` si une clé existe) et de monter `PROMPT_VERSION` si le prompt change. Jamais de contenu (prompt, arguments, notes) dans les journaux.
- Pas de clés ou données personnelles dans le code, les fixtures, les logs ou Git. `.env` et `.local/` sont ignorés.
- Les tests d'intégration utilisent des schémas PostgreSQL jetables et dédiés, jamais une base de production. Fournir `DATABASE_URL` de développement.
- `npm run typecheck`, `npm run build`, `npm test` doivent passer ; `smoke:local` et `spike:powersync` après toute modification de la sync. Aucun test iPhone/Swift n'est revendiqué depuis Windows.
- Toute précision de contrat met à jour le document normatif du pack puis son manifeste via `../_audit_work/tools/build_manifest.ps1`.
