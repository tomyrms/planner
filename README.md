# Planner

App iPhone personnelle de tâches et de calendrier avec assistant IA : backend à la racine, app SwiftUI dans [`ios/`](ios/README.md) (compilée par GitHub Actions à chaque push). La spécification complète (pack de documentation, ADR) est tenue hors de ce dépôt ; les chemins `../IOS_AI_PLANNER_DEEP_RESEARCH_2026-09-15/…` y renvoient.

## Backend

Backend du planner iPhone (étapes 1 à 3 de la roadmap et partie serveur de la voix : temps, fixtures partagées, PostgreSQL, appairage, upload des commandes, PowerSync auto-hébergé, export, sauvegarde, assistant, transcription). Règles : `AGENTS.md` et `../IOS_AI_PLANNER_DEEP_RESEARCH_2026-09-15/AGENTS.md`. Décisions d'implémentation : ADR-027 à ADR-030.

## Ce qui existe

| Partie | Contenu |
|---|---|
| `src/modules/time` | Valeurs temporelles (date flottante, heure + fuseau, changements d'heure), récurrence fixe et après complétion, identités d'occurrence, plan de rappels. |
| `fixtures/time` | Cas littéraux JSON partagés par les tests TypeScript et Swift. |
| `src/modules/sync` | `POST /api/v1/sync/mutations` : exécuteur de commandes (verrou, reçu, précondition, effet, révision) et handlers par agrégat (tâches, occurrences et séries, rappels, listes). C'est le service de domaine unique, que l'assistant utilise aussi (`executePlan`). |
| `fixtures/sync` | Scénarios de conflit JSON (commandes → résultat attendu), exécutés contre PostgreSQL. |
| `src/modules/domain` | Dérivés partagés : colonnes temporelles, bases de rappel, texte de recherche normalisé. |
| `src/modules/assistant` | Tours durables (`/api/v1/assistant/*`, JSON ou SSE), outils du catalogue v1, plan appliqué par l'exécuteur de commandes, politique R0–R3, propositions, Undo groupé, fournisseurs scripté, à règles et DeepSeek. |
| `fixtures/assistant` | Jeu d'évaluation versionné (31 cas) : test déterministe et évaluation réelle, dont tags et sous-tâches. |
| `src/modules/voice` | `/api/v1/assistant/transcriptions` (multipart) : contrôle du conteneur M4A, transcription OpenAI `gpt-transcribe` ou simulée, essais, plafonds, abandon, nettoyage de l'audio. |
| `src/modules/export` | `GET /api/v1/export` : archive JSON versionnée, instantané cohérent, un export par minute par appareil. |
| `src/modules/import` | Import sélectif en console : aperçu privé, confirmation par empreinte, nouveaux identifiants, application atomique et reprise du même plan sans doublons. |
| `src/modules/auth` | Appairage depuis la console, rotation des refresh tokens, jeton de sync, déconnexion, JWKS. |
| `migrations` | Schéma PostgreSQL et contraintes du modèle de données (0001 à 0008). |
| `powersync/` | Configuration du service PowerSync et Sync Streams (lecture seule, filtrée par utilisateur). |
| `src/infrastructure/db` | Runner de migrations, provisionnement PowerSync, règles de sauvegarde, rotation de génération. |

L'app iPhone contient maintenant les écrans de tâches, l'agenda et le calendrier, les séries, les rappels locaux, l'assistant et les messages vocaux. Voir [`ios/README.md`](ios/README.md) pour l'installation et les validations restantes.

`GET /api/v1/diagnostics` est authentifié et expose uniquement l'état technique et les compteurs. La corbeille est purgée après 30 jours, une fois par jour ; le journal IA reste tant que la tâche ou sa conversation existe. **Reçus et tombstones restent conservés** tant que la récupération des files hors ligne de plus de 90 jours n'est pas implémentée : les effacer maintenant permettrait de rejouer d'anciennes commandes.

La récupération guidée conserve une archive vérifiée et la file existante avant de changer de serveur, d'identité ou de génération. L'import sélectif est disponible en console ; la validation complète sur iPhone reste à faire.

### Import sélectif

Préparer un JSON de sélection explicite avec `taskIds`, `projectIds` et `tagIds` (tableaux d'UUID présents dans l'archive). Les listes et tags non sélectionnés ne sont pas recréés : leurs tâches deviennent Inbox ou perdent ces affectations, avec avertissements dans l'aperçu.

```powershell
.\scripts\npm-local.ps1 run admin -- import preview export.json --selection selection.json --user UUID --out .local/import-plan.json
# Examiner le plan privé et ses avertissements, puis confirmer son empreinte affichée.
.\scripts\npm-local.ps1 run admin -- import apply .local/import-plan.json --user UUID --confirm-plan SHA256
```

Les versions serveur/iPhone 1 sont acceptées, dans la limite de 20 Mio et 500 commandes. L'import recrée uniquement les objets choisis avec de nouveaux IDs, via le domaine. Il ne rejoue ni file de commandes, ni historique, ni réglages. Une série exige une nouvelle ancre explicite dans `restartSeries`; ses anciennes occurrences restent exclues. Les collisions de noms de tags demandent un renommage explicite dans `tagNames`. Réutiliser le même plan après une interruption ; régénérer un plan crée un autre import. Le serveur, le propriétaire, la génération et l'empreinte sont contrôlés à l'application.

Le budget voix est réservé par tentative puis imputé au mois UTC de son envoi au fournisseur. Une tentative autorisée reste comptée si la réponse se perd. Les essais antérieurs à la migration 0008 restent des estimations au mois de création, leurs horodatages individuels n'étant pas connus.

Les tâches disposent d'une description, d'une checklist à un niveau (hors récurrence) et de tags réutilisables. Dans Réglages > Assistant, le classement automatique peut être activé pour les nouvelles tâches créées par l'assistant : jusqu'à trois tags existants pertinents, aucun si la correspondance est incertaine. Le réglage est désactivé par défaut ; les résultats indiquent les ajouts et restent annulables. Les nouvelles tables sont incluses dans la réplication et les sauvegardes ; les anciens dumps sont contrôlés selon leurs migrations puis mis à niveau lors de leur restauration.

Depuis Réglages > Données, l'iPhone peut exporter sa copie locale en JSON, même hors ligne : tâches, listes, occurrences, rappels, conversations, textes en cours, commandes non acquittées et rejets. L'archive précise si la première synchronisation est incomplète ; elle ne remplace pas une sauvegarde complète du serveur. Aucun audio ni identifiant d'accès n'est inclus, et l'export ne modifie pas la file.

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
.\scripts\npm-local.ps1 run smoke:local       # auth, upload de commandes, rejeu, 426, 409, tours texte et vocal, Undo
.\scripts\npm-local.ps1 run spike:powersync   # client PowerSync Node : critères ADR-004 n° 2, 3, 5, 6, 7, 8
```

Le spike appaire puis révoque un appareil temporaire et laisse ses tâches « [spike] » dans la corbeille. Fumée et spike appairent chacun un appareil : la limite anti-abus (10 appairages par heure par adresse) peut les bloquer après plusieurs lancements ; en développement seulement, `docker compose exec -T postgres psql -U planner_owner -d planner -c "DELETE FROM auth_pair_rate_limits"`.

## Assistant

Sans `DEEPSEEK_API_KEY`, le développement utilise un fournisseur à règles déterministe (les cinq demandes de référence) ; en production sans clé, l'assistant répond 503. En local, garder `ASSISTANT_PROVIDER=rules` dans `.env` même avec une clé : la pile Docker et `smoke:local` restent gratuits. L'évaluation utilise toujours le vrai modèle et exige une liste de cas (chaque cas ≈ 15 000 à 30 000 tokens) :

```powershell
.\scripts\npm-local.ps1 run eval:assistant                          # liste des cas, aucun appel
.\scripts\npm-local.ps1 run eval:assistant -- reference-free-slots   # un seul cas, schéma jetable
.\scripts\npm-local.ps1 run eval:assistant -- --all                  # les 24 cas
```

Réglages : `ASSISTANT_PROVIDER` (`deepseek`, `rules`, `disabled`), `DEEPSEEK_MODEL` (`deepseek-flash`), `DEEPSEEK_THINKING` (`false`), `ASSISTANT_MONTHLY_TOKEN_BUDGET`.

## Voix

Sans `OPENAI_API_KEY`, le développement renvoie une transcription simulée (texte marqué « [voix simulée] », aucun audio ne sort de la machine) ; en production sans clé, les nouveaux envois vocaux répondent 503. La lecture d'un résultat existant et l'abandon restent disponibles. L'audio vit dans `AUDIO_DIR` (tmpfs du conteneur), jamais dans une sauvegarde. Le résultat est persisté avant suppression de l'audio ; un échec de suppression est repris par le nettoyage.

Le POST attend au plus une seconde le fournisseur, puis rend un état consultable par GET. Une réponse réseau perdue se reprend par GET avec le même identifiant. L'iPhone conserve le texte et les identifiants du tour avant de le remettre à l'assistant ; l'attente peut être mise en pause. Les erreurs de validation sont journalisées par code technique, sans audio ni texte.

Réglages : `TRANSCRIPTION_PROVIDER` (`openai`, `simulated`, `disabled`), `OPENAI_TRANSCRIPTION_MODEL` (`gpt-transcribe`), `TRANSCRIPTION_MONTHLY_MINUTES` (600), `AUDIO_DIR`.

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

### Sauvegarde quotidienne sur Windows

```powershell
.\scripts\backup-daily.ps1                     # crée puis vérifie exactement le nouveau dump
.\scripts\register-maintenance.ps1 -WhatIf     # aperçu ; ne crée aucune tâche
.\scripts\register-maintenance.ps1             # installation explicite, 03:15 et ouverture de session
```

La tâche `Planner Daily Backup` utilise le compte courant sans mot de passe enregistré ni élévation. Elle reprend une échéance manquée, réessaie trois fois à 15 minutes d'intervalle après échec et refuse les exécutions simultanées. Elle nécessite une session Windows ouverte et Docker Desktop déjà lancé ; elle ne démarre pas Docker. Sur une machine éteinte ou déconnectée, une planification ne garantit pas une sauvegarde sous 24 h.

Le job utilise `npm-local.ps1`, conserve la rétention existante (7 dumps récents + 4 semaines), puis restaure le fichier qu'il vient de produire dans une base temporaire. Il ne lance jamais `backup restore` sur la base principale. Si plusieurs dumps apparaissent pendant sa création, il échoue explicitement au lieu d'en choisir un au hasard. `-Destination <dossier>` change uniquement le dossier des sauvegardes locales, sur les deux scripts ; `-At HH:mm` change l'horaire de la tâche. Ces scripts n'effectuent aucune copie ni aucun chiffrement hors machine.

Statut et dernier journal : `.local/maintenance/backup-daily/state.json` et `last-run.log`, réservés au compte courant, au système et aux administrateurs. Ils contiennent seulement dates, étape, résultat, nom technique et taille du dump, jamais les sorties des outils ni des secrets. Codes d'échec : 11 Docker/PostgreSQL indisponible, 12 création, 13 nouveau fichier ambigu/incomplet, 14 vérification, 15 configuration ou statut local. Une création/vérification réussie alimente aussi `maintenance_runs`, visible dans les diagnostics de l'app ; un échec avant accès à PostgreSQL reste signalé par le statut local et le Planificateur de tâches.

La copie chiffrée hors machine nécessite encore une destination choisie, un moyen de déchiffrement conservé séparément et un essai de récupération depuis cette copie. Les secrets du serveur restent dans un coffre distinct. La vérification temporaire prouve le dump ; elle ne remplace pas un exercice complet sur un serveur vierge avec l'iPhone plus récent que la sauvegarde.

## Partager le projet pour une revue

Ne pas zipper le dossier : il contient `.env`, `.local/`, `backups/` et les dépendances. Utiliser :

```powershell
.\scripts\export-review.ps1          # ..\_exports\planner-review-….zip : pack, fichiers racine, backend suivi par Git
```

L'archive est refusée si un fichier ressemble à une clé ou à un dump, ou contient une valeur secrète du `.env` local (seul le nom de la variable est affiché).

## Tests

- `test:unit` : module temporel, règles de sauvegarde et frontière HTTP, sans base.
- `test:integration` : PostgreSQL dans un schéma jetable par suite (contraintes, migrations, rôles, restaurabilité, couverture de la sauvegarde, provisionnement, commandes et concurrence, route de sync, export, fixtures de conflits, assistant et jeu d'évaluation scripté, voix). Nécessite `DATABASE_ADMIN_URL`.
- `tests/fixtures/audio` : fichiers AAC de 3 s générés par FFmpeg (mono, stéréo) et AVFoundation (Apple mono), sans voix.
- `smoke:local` et `spike:powersync` demandent la pile Docker démarrée.
- Aucun test Swift/iPhone n'est exécuté depuis Windows.

## Dépannage

- Docker Desktop qui se ferme au démarrage avec « The file cannot be accessed by the system » sur `dockerInference` ou `engine.sock` : quitter Docker Desktop, renommer le dossier `%LOCALAPPDATA%\Docker\run` (ou `%LOCALAPPDATA%\docker-secrets-engine`) en `*.stale`, recréer le dossier vide, relancer Docker. Les anciens dossiers `run.stale-20260916*` peuvent être supprimés une fois Docker stable.
- `health/ready` renvoie `sync: not_provisioned` : lancer `npm run db:provision-sync`.
- PowerSync ne démarre pas après un changement de mot de passe : relancer `db:provision-sync`, puis `docker compose --profile app up -d --wait powersync`.
