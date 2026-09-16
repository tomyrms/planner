# Contrat temporel partagé — v1

`v1.json` contient des entrées et résultats littéraux. Les tests TypeScript exécutent ces mêmes données ; le futur client Swift devra les lire sans générer ses propres résultats attendus. Les UUID attendus ont été recoupés avec `uuid.uuid5` de Python, indépendant du module TypeScript.

`reminder-plans-v1.json` couvre les fenêtres, quotas et preuves de programmation. Pour chaque cas, créer `candidateCount` rappels éligibles avec UUID `11111111-1111-4111-8111-` suivi de l'indice zéro en 12 chiffres, sans occurrence, tous au `triggerAt` indiqué. `systemPending:true` fournit ces mêmes requêtes dans la lecture système ; `acceptedAt` fournit une ancienne acceptation pour chacun. Les résultats attendus sont les nombres littéraux de requêtes désirées, à ajouter, et d'états. Ce format évite de répéter 51 objets identiques pour le test du quota.

## Décisions précisées pour l'étape 1 (ADR-027)

- Calendrier grégorien ISO, dates `0001-01-01` à `9999-12-31`, heures à la minute. `{date}` est normalisé en `{date,time:null,timeZone:null}` ; absence du groupe = inchangé dans un patch, `null` = effacement.
- Fuseaux IANA pris dans la tzdata du runtime ; offsets numériques refusés. Le runtime et sa tzdata doivent être consignés lors de la comparaison Swift/TypeScript. Aucun fuseau de la machine ne sert de valeur implicite.
- Une heure inexistante est avancée minute par minute jusqu'à la première minute valide, y compris un saut de 30 minutes. Une heure répétée choisit son premier instant. La valeur métier originale reste conservée avec l'ajustement dérivé.
- Fenêtre d'occurrences : de `from` à `through` inclus, au plus 60 dates civiles. Aucun historique n'est matérialisé pour calculer un groupe de manquées.
- Semaine ISO débutant lundi ; la semaine de l'ancre est la première semaine du cycle. Les jours sélectionnés antérieurs à l'ancre sont exclus. `count` dénombre les occurrences réellement produites à partir de l'ancre, jamais les mois sans le 31 ; `until` est inclusif et exclusif de `count`.
- `after_completion` ajoute jours, semaines ou mois à la date locale réelle de l'action sur l'appareil. L'addition de mois est contrainte au dernier jour disponible (31 janvier + 1 mois = 28/29 février). Cela ne modifie pas les séries fixes `byMonthDay:31`, qui ignorent février.
- Clés fixes : `YYYY-MM-DD`. Clés après complétion : `YYYY-MM-DD~N`, ordinal `N` initial à zéro puis incrémenté transactionnellement. La partie date peut rester identique ou précéder l'ancienne date prévue lors d'une complétion anticipée ; l'ordinal distingue les cycles. `nextAfterCompletionDate` renvoie la date, `nextAfterCompletionKey` construit la clé suivante. Le modèle SQL garantit l'unicité et la transaction protège contre les doubles effets ; la transition pure ne prétend pas fournir un verrou.
- Namespace UUIDv5 figé : `6fcb5ad1-40ec-5ca9-bfab-62083e61c443`. Nom UTF-8 : UUID de tâche en minuscules + `:` + clé d'occurrence complète. Ne jamais remplacer ce namespace après création de données.
- Le résumé `countMissedFixed` considère les dates effectives strictement antérieures à `beforeDate`, exclut les complétions/ignorées et tient compte des reports. `latestOccurrenceKey` signifie la clé d'origine la plus récente ; aucun tableau d'historique n'est produit.
- Rappels date seule : heure dans le fuseau actuel de l'appareil. Rappels horaires : instant de la base dans son fuseau d'origine, diminué de l'offset réel en minutes. Les rappels absolus ne suivent pas un report.
- Fenêtre de rappel : maintenant jusqu'à la même heure locale 14 jours civils plus tard, borne supérieure incluse ; au plus 50 requêtes, triées par instant puis identifiant stable. Aucun rappel passé n'est rejoué. Une réconciliation calcule un état désiré ; seuls les `systemPending` issus d'iOS permettent l'état `scheduled`. Une ancienne acceptation avant l'heure prouve la programmation, jamais l'affichage ; son état après passage de l'heure est `display_unknown`.

## Limites assumées

Les fonctions ne programment pas de notification iOS. Aucun test Swift/iPhone n'a lieu dans ce dépôt Windows. L'état des tâches et l'ownership sont vérifiés par les services appelants ; les calculs temporels ne constituent ni une API de mutation ni un mécanisme d'authentification.

Référence d'implémentation : [Temporal ZonedDateTime](https://tc39.es/proposal-temporal/docs/zoneddatetime.html), [Temporal PlainDate](https://tc39.es/proposal-temporal/docs/plaindate.html). Le contrat produit choisit explicitement la première minute valide, au lieu du décalage automatique habituel de la bibliothèque dans une lacune DST.
