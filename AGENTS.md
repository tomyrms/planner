# Planner — règles de développement

Lire d'abord `../IOS_AI_PLANNER_DEEP_RESEARCH_2026-09-15/AGENTS.md` et sa table normative. Les décisions du pack s'appliquent à ce dépôt. Le produit V1 reste iPhone-first ; ce dépôt contient son backend, pas un client Windows.

- TypeScript ESM strict, imports locaux suffixés `.js`, dépendances exactes et lockfile.
- Étapes 1 à 3 livrées : temps, fixtures JSON partagées, PostgreSQL, appairage, upload des commandes, PowerSync auto-hébergé (toujours candidat, ADR-004 et ADR-028), export, sauvegarde, assistant (ADR-029). Toute écriture de domaine passe par `executeCommand` ou `executePlan` ; aucune route CRUD.
- Assistant : changer le prompt, un schéma d'outil ou la logique temporelle impose de rejouer `fixtures/assistant/eval-v1.json` (test, puis `npm run eval:assistant` si une clé existe) et de monter `PROMPT_VERSION` si le prompt change. Jamais de contenu (prompt, arguments, notes) dans les journaux.
- Pas de clés ou données personnelles dans le code, les fixtures, les logs ou Git. `.env` et `.local/` sont ignorés.
- Les tests d'intégration utilisent des schémas PostgreSQL jetables et dédiés, jamais une base de production. Fournir `DATABASE_URL` de développement.
- `npm run typecheck`, `npm run build`, `npm test` doivent passer ; `smoke:local` et `spike:powersync` après toute modification de la sync. Aucun test iPhone/Swift n'est revendiqué depuis Windows.
- Toute précision de contrat met à jour le document normatif du pack puis son manifeste via `../_audit_work/tools/build_manifest.ps1`.
