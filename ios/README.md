# Planner — app iPhone

App SwiftUI (iOS 26.0, Xcode 26.3, Swift 6). Le code est écrit depuis Windows ; **GitHub compile chaque push** avec la même toolchain que le Mac (workflow `iOS`, ADR-031). Le Mac sert à installer l'app sur l'iPhone et à la tester. Décisions et règles : `../AGENTS.md`, pack de documentation (ADR-023, ADR-031).

État : étape 4 — app vide qui affiche version, build, version d'iOS et modèle de l'iPhone.

## Structure

| Chemin | Rôle |
|---|---|
| `Planner.xcodeproj` | Projet Xcode. Le dossier `Planner/` y est **synchronisé** : tout fichier ajouté dans ce dossier fait partie de l'app, sans modifier le projet. |
| `Planner/` | Code et ressources de l'app. |
| `Config/*.xcconfig` | Réglages de build (version, identifiant, Swift 6, isolation Main Actor). `Local.xcconfig` (non versionné) porte l'équipe de signature. |
| `scripts/build-device.sh` | Build + installation sur l'iPhone branché, en ligne de commande. |

## Sur le Mac (première fois)

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
