# Planner — app iPhone

App SwiftUI (iOS 26.0, Xcode 26.3, Swift 6). Le code est écrit depuis Windows ; **GitHub compile chaque push** avec la même toolchain que le Mac (workflow `iOS`, ADR-031) et publie un **IPA non signé** à installer avec iLoader. Le Mac n'est plus qu'une solution de secours. Décisions et règles : `../AGENTS.md`, pack de documentation (ADR-023, ADR-031).

État : étape 5 en cours — appairage par lien, Aujourd'hui, Inbox, À venir, listes, Terminées, Corbeille, recherche, éditeur, Réglages > Synchronisation, sur PowerSync Swift 1.16.2. Calendrier et Assistant affichent un écran d'attente. Compilé par GitHub ; **pas encore essayé sur l'iPhone**.

## Appairer l'app

L'app ne contient aucune adresse de serveur (l'IPA est public). Le backend doit être joignable **en HTTPS** depuis l'iPhone, avec `PUBLIC_API_URL` et `PUBLIC_SYNC_URL` réglés sur ses adresses publiques. Puis, sur le serveur :

```bash
npm run admin -- pair --name "iPhone"
```

Coller le lien `planner://pair?…` affiché dans l'écran d'appairage (valable 10 minutes, une seule fois).

## Structure

| Chemin | Rôle |
|---|---|
| `Planner.xcodeproj` | Projet Xcode. Le dossier `Planner/` y est **synchronisé** : tout fichier ajouté dans ce dossier fait partie de l'app, sans modifier le projet. |
| `Planner/` | Code et ressources : `App` (démarrage, services), `Domain` (dates, tâches, sections), `Data` (base PowerSync, file, API, sync), `Features` (écrans), `DesignSystem`. |
| `Config/*.xcconfig` | Réglages de build (version, identifiant, Swift 6, isolation Main Actor). `Local.xcconfig` (non versionné) porte l'équipe de signature. |
| `scripts/build-device.sh` | Build + installation sur l'iPhone branché, en ligne de commande. |

## Installer avec iLoader (méthode principale, sans Mac)

Pas encore essayé : signaler toute étape qui bloque.

1. Ouvrir le dernier run vert du workflow **iOS** : https://github.com/tomyrms/planner/actions/workflows/ios.yml (connecté à GitHub).
2. En bas, **Artifacts** : télécharger `Planner-<version>-<build>` (un zip), l'extraire : il contient `Planner-<version>-<build>.ipa`.
3. Dans iLoader (https://github.com/nab138/iloader, iPhone branché, identifiant Apple connecté) : **importer l'IPA** et l'installer.
4. Au premier lancement : **Réglages > Général > VPN et gestion de l'appareil** > faire confiance au développeur ; **Mode développeur** activé si iOS le demande.

À savoir avec un identifiant Apple gratuit :

- iLoader signe l'IPA et **change l'identifiant de l'app** en `io.github.tomyrms.planner.<ÉQUIPE>` ; il crée aussi un groupe d'app `group.io.github.tomyrms.planner.<ÉQUIPE>`. Le code ne doit donc jamais supposer l'identifiant exact.
- L'app expire après **7 jours** : réinstaller le même IPA (ou un plus récent) suffit, les données restent si l'identifiant ne change pas.
- 3 apps sideloadées actives au plus et 10 identifiants d'app par semaine : chaque extension future (widget) consomme un identifiant.
- Le numéro de build de l'IPA est le numéro du run GitHub ; la version affichée dans l'app permet de vérifier ce qui est installé.

## Sur le Mac (secours : build local, journaux Xcode)

Pas encore essayé sur le MacBook Air : signaler toute étape qui bloque.

1. Xcode 26.3 ouvert au moins une fois, licence acceptée, plateforme iOS installée.
2. Xcode > Réglages > Comptes : ajouter l'identifiant Apple, puis **Gérer les certificats** > **+** > **Apple Development**.
3. Récupérer l'identifiant d'équipe (10 caractères, champ `OU`) :
   ```bash
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```
4. Cloner dans `~/Developer` (pas dans Documents ni Bureau) :
   ```bash
   mkdir -p ~/Developer && cd ~/Developer
   git clone https://github.com/tomyrms/planner.git
   cd planner
   cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
   open -e ios/Config/Local.xcconfig
   ```
   Remplacer `ABCDE12345` par l'identifiant d'équipe. Ne pas choisir l'équipe dans l'interface d'Xcode : elle serait écrite dans le projet et bloquerait les `git pull`.
5. iPhone branché, déverrouillé, « Faire confiance » accepté ; **Réglages > Confidentialité et sécurité > Mode développeur** activé (redémarrage demandé).
6. Lancer :
   ```bash
   ios/scripts/build-device.sh
   ```
7. Au premier lancement, iOS peut demander de faire confiance au développeur : **Réglages > Général > VPN et gestion de l'appareil**.

## Ensuite

```bash
cd ~/Developer/planner
git pull
ios/scripts/build-device.sh            # Debug ; « Release » en argument pour une version durable
```

- En cas d'échec, envoyer le contenu de `ios/build/last-errors.txt` (ou la fin de `ios/build/xcodebuild.log`).
- Avec un identifiant Apple gratuit, l'app installée expire après 7 jours : relancer le script.
- Le build incrémental réutilise `ios/build/DerivedData` ; le premier build est le plus long.
- Remplir le tableau d'environnement (`03_iOS/05_Build_IPA_Sideload.md` §1) avec les valeurs affichées par l'app.

## Règles

- Un changement n'est « compilé » que si le workflow `iOS` est vert sur ce commit ; il n'est « testé » qu'après essai sur l'iPhone.
- Aucune clé ni secret dans le projet, les xcconfig versionnés ou le bundle.
- Pas de modification manuelle de `project.pbxproj` pour ajouter un fichier : le dossier synchronisé s'en charge.
