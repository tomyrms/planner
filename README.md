# Planner — backend

Backend du planner iPhone (étapes 1 et 2 de la roadmap : temps, fixtures partagées, PostgreSQL, appairage, upload des commandes, PowerSync auto-hébergé, export, sauvegarde). Règles : `AGENTS.md` et `../IOS_AI_PLANNER_DEEP_RESEARCH_2026-09-15/AGENTS.md`. Décisions d'implémentation : ADR-027 et ADR-028.

## Ce qui existe

| Partie | Contenu |
|---|---|
| `src/modules/time` | Valeurs temporelles (date flottante, heure + fuseau, changements d'heure), récurrence fixe et après complétion, identités d'occurrence, plan de rappels. |
| `fixtures/time` | Cas littéraux JSON que le futur client Swift devra aussi passer. |
| `src/modules/sync` | `POST /api/v1/sync/mutations` : exécuteur de commandes (verrou, reçu, précondition, effet, révision) et handlers par agrégat (tâches, occurrences et séries, rappels, listes). C'est le service de domaine unique, que l'assistant appellera aussi. |
| `fixtures/sync` | Scénarios de conflit JSON (commandes → résultat attendu), exécutés contre PostgreSQL. |
| `src/modules/domain` | Dérivés partagés : colonnes temporelles, bases de rappel, texte de recherche normalisé. |
| `src/modules/export` | `GET /api/v1/export` : archive JSON versionnée, instantané cohérent, un export par minute par appareil. |
| `src/modules/auth` | Appairage depuis la console, rotation des refresh tokens, jeton de sync, déconnexion, JWKS. |
| `migrations` | Schéma PostgreSQL et contraintes du modèle de données (0001 à 0004). |
| `powersync/` | Configuration du service PowerSync et Sync Streams (lecture seule, filtrée par utilisateur). |
| `src/infrastructure/db` | Runner de migrations, provisionnement PowerSync, règles de sauvegarde, rotation de génération. |

Pas encore : assistant IA (étape 3), `GET /diagnostics`, purge planifiée, import d'un export, client iPhone.

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
.\scripts\npm-local.ps1 run smoke:local       # auth, upload de commandes, rejeu, 426, 409
.\scripts\npm-local.ps1 run spike:powersync   # client PowerSync Node : critères ADR-004 n° 2, 3, 5, 6, 7, 8
```

Le spike appaire puis révoque un appareil temporaire et laisse ses tâches « [spike] » dans la corbeille.

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
- `test:integration` : PostgreSQL dans un schéma jetable par suite (contraintes, migrations, rôles, restaurabilité, provisionnement, commandes et concurrence, route de sync, export, fixtures de conflits). Nécessite `DATABASE_ADMIN_URL`.
- `smoke:local` et `spike:powersync` demandent la pile Docker démarrée.
- Aucun test Swift/iPhone n'est exécuté depuis Windows.

## Dépannage

- Docker Desktop qui se ferme au démarrage avec « The file cannot be accessed by the system » sur `dockerInference` ou `engine.sock` : quitter Docker Desktop, renommer le dossier `%LOCALAPPDATA%\Docker\run` (ou `%LOCALAPPDATA%\docker-secrets-engine`) en `*.stale`, recréer le dossier vide, relancer Docker. Les anciens dossiers `run.stale-20260916*` peuvent être supprimés une fois Docker stable.
- `health/ready` renvoie `sync: not_provisioned` : lancer `npm run db:provision-sync`.
- PowerSync ne démarre pas après un changement de mot de passe : relancer `db:provision-sync`, puis `docker compose --profile app up -d --wait powersync`.
