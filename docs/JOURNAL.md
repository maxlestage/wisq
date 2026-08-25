# Journal des sessions autonomes

Ce fichier existe pour une raison simple : quand le travail continue pendant
que personne ne regarde, il faut pouvoir lire le matin ce qui a été décidé la
nuit — et surtout **sur quelle autorisation**. Un agent qui fusionne des pull
requests sans que la trace de l'accord existe quelque part est un agent dont
on ne peut pas vérifier le mandat après coup.

L'ordre est antéchronologique : le plus récent en haut.

## 2026-08-24, nuit — autonomie accordée

**Autorisation, mot pour mot :** « Je vais dormir continue de travailler sans
moi note le / Je veux que ça soit enregistré / Il faut merger et continuer. »
— Maxime Nathan Lestage, 24 août 2026.

Ce que ça change par rapport au reste de la session : jusque-là chaque fusion
était autorisée une par une, et je m'arrêtais après chaque PR pour demander.
À partir de là je fusionne moi-même une PR dont la CI est verte, et
j'enchaîne.

Ce que ça ne change pas, et qui reste vrai sans qu'on ait besoin de me le
redire :

- Le développement reste sur `claude/concurrent-utm-app-stores-ofjujj`. Après
  chaque fusion, la branche repart de `master` et une **nouvelle** PR est
  ouverte — jamais d'empilement sur de l'historique déjà fusionné.
- Une CI verte ne suffit pas : le journal brut du job est lu avant de
  fusionner, pour vérifier que les tests ont **réellement tourné** et que rien
  n'a été sauté. Une pastille verte n'est pas une preuve.
- Aucune licence n'est annoncée nulle part. Aucune n'a été choisie.
  `scripts/check-licence-claims.sh` le tient.
- Rien de destructif, rien d'irréversible sans accord : pas de réécriture de
  l'historique de `master`, pas de suppression de branche d'autrui, pas de
  publication de release, pas de `--force` ailleurs que sur ma propre branche
  et seulement quand son contenu est déjà dans `master`.
- Chaque affirmation qu'un commit fait sur son propre travail est vérifiée
  avant d'être écrite, sabotage compris : on casse la ligne exprès et on
  regarde si un test tombe. Quand il ne tombe pas, c'est la ligne ou le test
  qui est faux, et c'est dit.

Ce qui a été fait dans la soirée, avant de dormir : lecture des fichiers de
connexion `.vv` et `.rdp` et leur branchement dans l'application (#28),
décodage du canal display de SPICE (#29), décodage du codec LZ vérifié contre
l'implémentation de référence (#30). Trois fusions, trois branches repartant
de `master`.

Ce qui suit est écrit au fil de la nuit.
