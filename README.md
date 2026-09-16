# Planner — backend

Backend du planner iPhone (étape 1 de la roadmap : temps, fixtures partagées, PostgreSQL, appairage). Règles : `AGENTS.md` et `../IOS_AI_PLANNER_DEEP_RESEARCH_2026-09-15/AGENTS.md`. Décisions d'implémentation : ADR-027.

## Ce qui existe

| Partie | Contenu |
|---|---|
| `src/modules/time` | Valeurs temporelles (date flottante, heure + fuseau, changements d'heure), récurrence fixe et après complétion, identités d'occurrence, plan de rappels. |
| `fixtures/time` | Cas littéraux JSON que le futur client Swift devra aussi passer. |
| `src/modules/domain` | Complétion / saut / réouverture d'une série après complétion (idempotent, sûr en concurrence). |
| `src/modules/auth` | Appairage depuis la console, rotation des refresh tokens, jeton de sync, déconnexion, JWKS. |
| `migrations` | Schéma PostgreSQL et contraintes du modèle de données. |

Pas encore : `POST /sync/mutations`, PowerSync, assistant IA, tâches fixes/rappels/listes côté API (étapes 2 et 3).

## Démarrer (Windows)

Prérequis : Docker Desktop lancé. Node 24.21.0 est fourni localement dans `.tools/` et utilisé par `scripts/npm-local.ps1`.

```powershell
.\scripts\npm-local.ps1 ci                   # dépendances exactes
.\scripts\npm-local.ps1 run setup:local      # crée .env et .local/ (secrets locaux, jamais versionnés)
docker compose up -d --wait postgres         # PostgreSQL 18.6 sur 127.0.0.1:55437
.\scripts\npm-local.ps1 run db:migrate       # migrations avec le rôle propriétaire
.\scripts\npm-local.ps1 run check            # typecheck + build + tous les tests
```

API dans Docker, puis vérification de bout en bout :

```powershell
docker compose --profile app up -d --build --wait api
.\scripts\npm-local.ps1 run smoke:local
```

Appairer un appareil (console de confiance uniquement ; le secret s'affiche une fois et expire en 10 minutes) :

```powershell
.\scripts\npm-local.ps1 run admin -- pair --name "iPhone"
.\scripts\npm-local.ps1 run admin -- devices
.\scripts\npm-local.ps1 run admin -- devices revoke <UUID>
```

## Tests

- `test:unit` : module temporel et frontière HTTP, sans base.
- `test:integration` : PostgreSQL dans un schéma jetable par suite (contraintes, migrations, rôles, complétion concurrente, authentification). Nécessite `DATABASE_ADMIN_URL`.
- Aucun test Swift/iPhone n'est exécuté depuis Windows.

## Dépannage

Docker Desktop qui se ferme au démarrage avec « The file cannot be accessed by the system » sur `dockerInference` ou `engine.sock` : quitter Docker Desktop, renommer le dossier `%LOCALAPPDATA%\Docker\run` (ou `%LOCALAPPDATA%\docker-secrets-engine`) en `*.stale`, recréer le dossier vide, relancer Docker. Les anciens dossiers `run.stale-20260916*` peuvent être supprimés une fois Docker stable.
