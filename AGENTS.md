# Planner — règles de développement

Lire d'abord `../IOS_AI_PLANNER_DEEP_RESEARCH_2026-09-15/AGENTS.md` et sa table normative. Les décisions du pack s'appliquent à ce dépôt. Le produit V1 reste iPhone-first ; ce dépôt contient son backend, pas un client Windows.

- TypeScript ESM strict, imports locaux suffixés `.js`, dépendances exactes et lockfile.
- Étape 1 : temps, fixtures JSON partagées, PostgreSQL, appairage. PowerSync reste candidat et ne fait pas partie du runtime de cette étape.
- Pas de clés ou données personnelles dans le code, les fixtures, les logs ou Git. `.env` et `.local/` sont ignorés.
- Les tests d'intégration utilisent des schémas PostgreSQL jetables et dédiés, jamais une base de production. Fournir `DATABASE_URL` de développement.
- `npm run typecheck`, `npm run build`, `npm test` doivent passer. Aucun test iPhone/Swift n'est revendiqué depuis Windows.
- Toute précision de contrat met à jour le document normatif du pack puis son manifeste via `../_audit_work/tools/build_manifest.ps1`.
