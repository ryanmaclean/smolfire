# smolfire

> Anciennement « smolBSD » — renommé pour éviter toute confusion avec le
> projet NetBSD sans lien [NetBSDfr/smolBSD](https://github.com/NetBSDfr/smolBSD).
> Voir la section « Name » de [README.md](README.md).

Une image FreeBSD minimale pour les déploiements embarqués et en périphérie de
réseau, coordonnée par un système de boîtes aux lettres selon le modèle acteur.

## Qu'est-ce que smolfire ?

smolfire est un projet visant à construire la machine virtuelle FreeBSD la plus
légère possible qui démarre sans intervention jusqu'à l'invite de connexion en
30 secondes ou moins. L'image cible tient dans 512 Mio sur disque (objectif
aspirationnel : artefact qcow2 inférieur à 128 Mio) et n'inclut que les paquets
nécessaires à l'exécution de `sh`, `vi`/`ed`, `rc.d` et `pkg`.

La coordination entre les tâches de compilation repose sur un système de boîtes
aux lettres selon le modèle acteur : chaque agent (architecte, compilateur,
réviseur, chercheur) lit les tâches qui lui sont adressées dans un spool mbox
partagé (`var/mail/spool`) et répond dans le fil de discussion à l'aide
d'enveloppes RFC 822 avec des corps TOML. Le coordinateur collecte les réponses
à chaque cycle et distribue la tâche suivante. Aucun historique de conversation
partagé n'est nécessaire — les dépôts Just-Enough-Context (JEC) transportent
tout l'état nécessaire entre les agents.

## Objectifs de la Phase I

Deux branches s'exécutent en parallèle ; aarch64 est la branche principale.

### aarch64 — natif HVF sur Apple Silicon (`<hypervisor-host>`)

FreeBSD 15.0-RELEASE arm64, compilé nativement sur `<aarch64-builder>` (une VM FreeBSD 15
aarch64 hébergée sur un Mac Apple Silicon). HVF (Hypervisor.framework) offre
une accélération quasi bare-metal pour l'invité aarch64. La porte d'acceptation
de 30 secondes (temps jusqu'à l'invite de connexion) n'est atteignable qu'ici ;
l'émulation amd64 via TCG est 5 à 10 fois plus lente.

### amd64 — KVM sur Vultr

FreeBSD 15.0-RELEASE amd64, compilé en croisé depuis l'hôte <aarch64-builder> aarch64 et
déployé sur une instance Vultr x86 compatible KVM pour sa porte de mesure
temporelle.

## Approche de compilation

### Gestion de versions : jj

Tous les commits utilisent [jj](https://github.com/martinvonz/jj) (VCS
Jujutsu). On ne passe au git brut que lorsqu'un outil externe l'exige.

```sh
jj log --no-graph -r '@' --limit 5    # historique récent
jj describe -m "your message"         # mettre à jour la description de la copie de travail
jj new                                # ouvrir un nouveau changement
```

### Coordinateur Nushell

`bin/coord-tick.nu` — la boucle principale du coordinateur. À chaque cycle, il :

1. Lit `var/mail/spool` et collecte les réponses des agents.
2. Évalue les verdicts et les critères d'acceptation.
3. Ajoute la prochaine enveloppe de tâche dans le spool.

`bin/mbox-parse.nu` — assistant qui analyse les corps mbox + TOML en
enregistrements structurés pour le traitement en aval.

### Spool de boîtes aux lettres

`var/mail/spool` — un seul fichier mbox RFC 822. Chaque message (requête du
coordinateur et réponse d'agent) y réside. Les adresses suivent le schéma
`<rôle>@smolfire.local`. Le corps TOML transporte la charge utile structurée de
la tâche.

Exemples de rôles :
- `coordinator@smolfire.local`
- `architect@smolfire.local`
- `builder@smolfire.local`
- `reviewer@smolfire.local`

## Démarrage rapide

### Prérequis

- Mac Apple Silicon (pour le chemin aarch64/HVF) ou une instance Vultr KVM (chemin amd64)
- VM FreeBSD 15.0-RELEASE `<aarch64-builder>` accessible via saut SSH :

```sh
ssh -J <hypervisor-host> -p 2222 builder@localhost
```

- Nushell (`nu`) disponible localement pour les scripts du coordinateur
- `expect` disponible pour les tests d'acceptation

### Compiler le noyau

Se connecter en SSH sur <aarch64-builder> et exécuter :

```sh
make -j4 -C /usr/src buildworld buildkernel KERNCONF=SMOLFIRE-VM
```

Pour le chemin natif aarch64, aucun indicateur de compilation croisée n'est
nécessaire. Pour la compilation croisée amd64 depuis l'hôte arm64 :

```sh
make -j4 -C /usr/src buildworld buildkernel \
    KERNCONF=SMOLFIRE-VM \
    TARGET=amd64 \
    TARGET_ARCH=amd64
```

### Exécuter le test d'acceptation

```sh
expect tests/time-to-ready.exp
```

Le test mesure le temps réel écoulé entre le démarrage de la VM et l'invite de
connexion et échoue s'il dépasse 30 secondes.

### Avancer le coordinateur

```sh
nu bin/coord-tick.nu
```

## Structure du projet

```
bin/
  coord-tick.nu          # boucle acteur du coordinateur
  mbox-parse.nu          # analyseur mbox+TOML
docs/
  superpowers/specs/     # spécifications de conception
plans/
  tinyos/                # plans de compilation par phase
tests/
  time-to-ready.exp      # script expect : porte de mesure démarrage-connexion
var/
  mail/spool             # mbox partagée — état complet du projet dans un seul fichier
```

## Inspirations techniques

- **Modèle acteur** — les agents communiquent uniquement via le spool ; aucun
  état partagé au-delà du fichier mbox
- **FSM à récursion terminale** — le coordinateur est une machine à états pure :
  lire le spool, calculer l'état suivant, ajouter le message, recommencer
- **SIMD / vecteur** — les futures charges de travail ciblent NEON sur aarch64
  et AVX-512 sur amd64 pour les tâches de traitement de signal en périphérie
- **Enclaves sécurisées** — objectif à long terme : exécuter des charges de
  travail sensibles dans des enclaves bhyve FreeBSD sur du matériel compatible
- **Substrat \*BSD** — la base FreeBSD fournit un socle propre et sous licence
  permissive ; pkgsrc NetBSD est envisagé pour les outils de paquets multi-arch

## Licence

Apache-2.0 pour le code spécifique au projet. Les composants du système de base
FreeBSD conservent leurs licences BSD-2-Clause / BSD-3-Clause. Aucune dépendance
GPL, LGPL ou AGPL n'est autorisée.
