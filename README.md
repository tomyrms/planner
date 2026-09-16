# Planner — backend

Backend du planner iPhone (étapes 1 à 3 de la roadmap : temps, fixtures partagées, PostgreSQL, appairage, upload des commandes, PowerSync auto-hébergé, export, sauvegarde, assistant). Règles : `AGENTS.md` et `../IOS_AI_PLANNER_DEEP_RESEARCH_2026-09-15/AGENTS.md`. Décisions d'implémentation : ADR-027 à ADR-029.

## Ce qui existe

| Partie | Contenu |
|---|---|
| `src/modules/time` | Valeurs temporelles (date flottante, heure + fuseau, changements d'heure), récurrence fixe et après complétion, identités d'occurrence, plan de rappels. |
| `fixtures/time` | Cas littéraux JSON que le futur client Swift devra aussi passer. |
| `src/modules/sync` | `POST /api/v1/sync/mutations` : exécuteur de commandes (verrou, reçu, précondition, effet, révision) et handlers par agrégat (tâches, occurrences et séries, rappels, listes). C'est le service de domaine unique, que l'assistant utilise aussi (`executePlan`). |
| `fixtures/sync` | Scénarios de conflit JSON (commandes → résultat attendu), exécutés contre PostgreSQL. |
| `src/modules/domain` | Dérivés partagés : colonnes temporelles, bases de rappel, texte de recherche normalisé. |
| `src/modules/assistant` | Tours durables (`/api/v1/assistant/*`, JSON ou SSE), outils du catalogue v1, plan appliqué par l'exécuteur de commandes, politique R0–R3, propositions, Undo groupé, fournisseurs scripté, à règles et DeepSeek. |
| `fixtures/assistant` | Jeu d'évaluation versionné (24 cas) : test déterministe et évaluation réelle. |
| `src/modules/export` | `GET /api/v1/export` : archive JSON versionnée, instantané cohérent, un export par minute par appareil. |
| `src/modules/auth` | Appairage depuis la console, rotation des refresh tokens, jeton de sync, déconnexion, JWKS. |
| `migrations` | Schéma PostgreSQL et contraintes du modèle de données (0001 à 0005). |
| `powersync/` | Configuration du service PowerSync et Sync Streams (lecture seule, filtrée par utilisateur). |
| `src/infrastructure/db` | Runner de migrations, provisionnement PowerSync, règles de sauvegarde, rotation de génération. |

Pas encore : voix (transcription), `GET /diagnostics`, purge planifiée, import d'un export, client iPhone. L'adaptateur DeepSeek n'a jamais appelé le vrai service (pas de clé).

## Démarrer (Windows)

Prérequis : Docker Desktop lancé. Node 24.21.0 est fourni localement dans `.tools/` et utilisé par `scripts/npm-local.ps1` (qui réinsère le `--` que PowerShell supprime).

```powershell
.\scripts\npm-local.ps1 ci                   # dépendances exactes
.\scripts\npm-local.ps1 run setup:local      # crée ou complète .env et .local/ (secrets locaux, jamais versionnés)
docker compose up -d --wait postgres         # PostgreSQL 18.6 (réplication logique) sur 127.0.0.1:55437
.\scripts\npm-local.ps1 run db:migrate       # migrations avec le rôle propriétaire
.\scripts\npm-local.ps1 run db:provision-sync  # rôle de réplication, publication, base de stockage PowerSync
.\scripts\npm-local.ps1 run check            # typecheck + build + tous les tests
```

Pile complète dans Docker (API sur 127.0.0.1:4317, PowerSync sur 127.0.0.1:4318), puis vérifications de bout en bout :

```powershell
docker compose --profile app up -d --build --wait
.\scripts\npm-local.ps1 run smoke:local       # auth, upload de commandes, rejeu, 426, 409, tour d'assistant et Undo
.\scripts\npm-local.ps1 run spike:powersync   # client PowerSync Node : critères ADR-004 n° 2, 3, 5, 6, 7, 8
```

Le spike appaire puis révoque un appareil temporaire et laisse ses tâches « [spike] » dans la corbeille. Fumée et spike appairent chacun un appareil : la limite anti-abus (10 appairages par heure par adresse) peut les bloquer après plusieurs lancements ; en développement seulement, `docker compose exec -T postgres psql -U planner_owner -d planner -c "DELETE FROM auth_pair_rate_limits"`.

## Assistant

Sans `DEEPSEEK_API_KEY`, le développement utilise un fournisseur à règles déterministe (les cinq demandes de référence) ; en production sans clé, l'assistant répond 503. Avec une clé dans `.env` :

```powershell
.\scripts\npm-local.ps1 run eval:assistant                 # 24 cas contre le vrai modèle, schéma jetable
.\scripts\npm-local.ps1 run eval:assistant -- reference-free-slots   # un seul cas
```

Réglages : `ASSISTANT_PROVIDER` (`deepseek`, `rules`, `disabled`), `DEEPSEEK_MODEL` (`deepseek-flash`), `DEEPSEEK_THINKING` (`false`), `ASSISTANT_MONTHLY_TOKEN_BUDGET`.

Appairer un appareil (console de confiance uniquement ; le secret s'affiche une fois et expire en 10 minutes) :

```powershell
.\scripts\npm-local.ps1 run admin -- pair --name "iPhone"
.\scripts\npm-local.ps1 run admin -- devices
.\scripts\npm-local.ps1 run admin -- devices revoke <UUID>
```

## Sauvegarde et restauration

```powershell
.\scripts\npm-local.ps1 run backup -- create                       # backups/ : dump, rôles, empreintes, rétention
.\scripts\npm-local.ps1 run backup -- verify backups\planner-….dump  # restauration réelle dans une base temporaire
docker compose --profile app stop api powersync
.\scripts\npm-local.ps1 run backup -- restore backups\planner-….dump --globals backups\planner-…-globals.sql --confirm
docker compose --profile app up -d --wait
```

`restore` garde l'ancienne base sous `planner_before_restore_…`, réinitialise PowerSync, crée une nouvelle génération et révoque tous les appareils (sauf `--keep-devices`) : réappairer ensuite. Procédure complète : `04_Backend/05_Homelab_Deployment.md`. Les fichiers de `backups/` contiennent des données personnelles et des empreintes de mots de passe : ne pas les partager, copie chiffrée hors machine.

## Tests

- `test:unit` : module temporel, règles de sauvegarde et frontière HTTP, sans base.
- `test:integration` : PostgreSQL dans un schéma jetable par suite (contraintes, migrations, rôles, restaurabilité, provisionnement, commandes et concurrence, route de sync, export, fixtures de conflits, assistant et jeu d'évaluation scripté). Nécessite `DATABASE_ADMIN_URL`.
- `smoke:local` et `spike:powersync` demandent la pile Docker démarrée.
- Aucun test Swift/iPhone n'est exécuté depuis Windows.

## Dépannage

- Docker Desktop qui se ferme au démarrage avec « The file cannot be accessed by the system » sur `dockerInference` ou `engine.sock` : quitter Docker Desktop, renommer le dossier `%LOCALAPPDATA%\Docker\run` (ou `%LOCALAPPDATA%\docker-secrets-engine`) en `*.stale`, recréer le dossier vide, relancer Docker. Les anciens dossiers `run.stale-20260916*` peuvent être supprimés une fois Docker stable.
- `health/ready` renvoie `sync: not_provisioned` : lancer `npm run db:provision-sync`.
- PowerSync ne démarre pas après un changement de mot de passe : relancer `db:provision-sync`, puis `docker compose --profile app up -d --wait powersync`.
