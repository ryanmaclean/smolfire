# smolfire

[![CI](https://github.com/ryanmaclean/smolfire/actions/workflows/ci.yml/badge.svg)](https://github.com/ryanmaclean/smolfire/actions/workflows/ci.yml)

> Anciennement « smolBSD » — renommé pour éviter toute confusion avec le
> projet NetBSD sans lien [NetBSDfr/smolBSD](https://github.com/NetBSDfr/smolBSD).
> Les identifiants actifs utilisent désormais `smolfire`, tandis que certains
> documents historiques peuvent encore conserver `smolBSD`.

## Qu'est-ce que c'est ?

smolfire est une VM FreeBSD 15 minimale (aarch64 en cible principale, amd64 en
cible secondaire) associée à un coordinateur Nushell en machine à états finis
(FSM) qui distribue des tâches de build, de revue et d'exploitation à des
agents via un spool mbox+TOML. L'objectif est de produire un petit artefact
qcow2 qui démarre sans intervention jusqu'à une invite de connexion en moins de
30 secondes sur des hôtes HVF/KVM, piloté de bout en bout par le coordinateur
sans historique de conversation partagé.

## État

Au 2026-07-24 :

| Volet | Porte de démarrage | Taille d'image | Notes |
|---|---|---|---|
| amd64 | 9 s jusqu'à la connexion sur KVM — **PASS** | **66.6 Mio bruts, 26.6 Mio en téléchargement compressé** (porte ≤ 512 Mio **PASS**) | Construit de bout en bout par le pipeline hébergé ; voir les [releases](https://github.com/ryanmaclean/smolfire/releases) (0.1.0 : 223 Mio, 0.2.0 : 91/33 Mio, deuxième régime : 66.6/26.6 Mio) |
| aarch64 | nécessite du matériel ARM (voir `docs/BHYVE-GATE-AMD64.md`) | compilé en croisé par le même pipeline, porte de taille uniquement | Référence antérieure en build natif : 11 s sous HVF, 1.41 Gio avant régime |
| **SMOLFIRE** (microVM) | **511 ms jusqu'au shell sous Firecracker** (569 ms sous QEMU microvm), porte réseau TCP + ping hôte **PASS** | **37 Mio — un seul ELF PVH constitue tout l'OS** (noyau + racine MFS statique `/rescue`) | Esprit rump-kernel : ni bootloader, ni disque, ni pkgbase ; `sys/amd64/conf/SMOLFIRE` + `bin/build-smolfire.sh` |

Voir `docs/UR-BSD-VERIFY.md` pour les constats vérifiés et le plan de réduction
d'image, ainsi que `docs/PHASE-1-RESULTS.md` pour le rapport de base initial.

## Démarrage rapide

**Prérequis partout :** [Nushell](https://www.nushell.sh) **0.115.1**, la
version figée par la CI dans [`.github/nu-version`](.github/nu-version)
(`pkg install nushell` / `brew install nushell` / binaire de release GitHub —
0.112.2 échoue sur `str lowercase` dans `bin/coord-tick.nu` ; 0.111 et plus
anciens échouent sur `get -o`).

Trois façons de démarrer, selon votre environnement :

1. **Pas d'hôte FreeBSD ?** Déclenchez le
   [pipeline de build hébergé](.github/workflows/build-image-hosted.yml) depuis
   l'onglet Actions — il construit le qcow2 sur un runner GitHub standard et le
   téléverse comme artefact de workflow (voir `docs/BUILDING.md`, « Building in
   a pipeline »). Les builds qui passent les portes peuvent être publiés via le
   workflow manuel `Release smolfire Image` — consultez les
   [Releases](https://github.com/ryanmaclean/smolfire/releases) pour les images
   précompilées.
2. **Vous avez un hôte FreeBSD 15 ?** Construisez nativement — voir **Build**
   ci-dessous.
3. **Vous avez déjà un qcow2 ?** Démarrez-le :

   ```sh
   qemu-system-x86_64 -M q35 -accel kvm -cpu host -m 512M \
     -drive file=smolfire.qcow2,format=qcow2,if=virtio \
     -nic user,model=virtio-net-pci -nographic
   # (-accel hvf sur macOS ; retirez -accel/-cpu pour le TCG lent ailleurs)
   ```

   Connectez-vous avec `root` / mot de passe `smolfire`. **Images de dev
   uniquement** : elles livrent `PermitRootLogin yes` + l'authentification par
   mot de passe — changez le mot de passe dès la première connexion et ne les
   exposez jamais au-delà du réseau user-mode de QEMU.

## Carte du dépôt

| Chemin | Contenu |
|---|---|
| `bin/` | FSM du coordinateur (`coord-*.nu`, exécutable via `sh bin/coord-run.sh`), build d'image (`build-smolfire-vm.nu`), outillage ops (`harvest.sh`, `qemu-smolfire-vm.nu`, outils bhyve) |
| `sys/`, `release/tools/` | Configurations de noyau SMOLFIRE et confs d'image de release |
| `tests/` | Suites Nu unitaires/intégration + portes de boot `expect` (`sh tests/run-all.sh`) |
| `docs/` | `BUILDING.md` (point de départ), `UR-BSD.md`/`UR-BSD-VERIFY.md` (travail de taille), `BHYVE-GATE-AMD64.md` |
| `plans/`, `.planning/` | Traces de planification de phase (historiques) |
| `var/` | Spool/état d'exécution — jamais commités (voir `CLAUDE.md` §9) |

## Build

Le pipeline complet est décrit dans `docs/BUILDING.md`. La commande en une ligne
depuis un hôte FreeBSD 15 aarch64 avec `/usr/src` extrait sur `releng/15.0` :

```sh
sudo nu bin/build-smolfire-vm.nu
```

Elle exécute la phase de setup, `buildworld`, `buildkernel
KERNCONF=SMOLFIRE-VM`, le nettoyage des objets noyau et `make cloudware-release`
(l'étape d'image de release). La sortie est enregistrée dans
`/var/tmp/smolfire-build.log`. Utilisez `--check` pour un préflight en lecture
seule, `--skip-buildworld` pour reprendre après un long build, ou `--arch amd64`
pour la compilation croisée.

## Harvest et portes d'acceptation

`bin/harvest.sh` récupère les artefacts qcow2 depuis les hôtes de build
distants (`<aarch64-builder>` via un jump host pour aarch64, Vultr pour amd64)
dans `var/artifacts/`, puis exécute les portes de taille et de démarrage et
écrit `var/artifacts/harvest-report.txt` :

```sh
sh bin/harvest.sh
```

Portes :
- taille ≤ 512 Mio (`wc -c` sur le qcow2)
- démarrage via `expect tests/time-to-ready-arm64.exp` /
  `tests/time-to-ready.exp`

Pour diagnostiquer un gonflement d'image, montez le rootfs et affichez les plus
gros répertoires, fichiers et paquets pkgbase par taille :

```sh
bin/analyze-image.sh path/to/FreeBSD-15-aarch64-smolfire.qcow2
```

Fonctionne sous Linux (qemu-nbd) et FreeBSD (mdconfig). Écrit un
`.size-report.txt` à côté de l'image et termine avec un code non nul si
l'utilisation dépasse 512 Mio.

## Coordinateur

Le coordinateur Nushell est documenté dans `CLAUDE.md`. Pour lancer la boucle :

```sh
sh bin/coord-run.sh
```

Pour avancer d'un tick à la main :

```sh
nu bin/coord-tick.nu
```

Variables d'environnement de surcharge (toutes optionnelles) :

| Var | Défaut | Rôle |
|---|---|---|
| `ROOT` | `.` | Racine du dépôt |
| `INTERVAL` | `60` | Secondes entre les ticks normaux |
| `HALT_INTERVAL` | `10` | Sommeil en secondes à l'arrêt |
| `STATE_FILE` | `var/run/coord-state.toml` | État FSM persisté |
| `SPOOL` | `var/mail/spool` | Chemin du spool mbox |
| `SMOLFIRE_CLAUDE_MODEL` | `claude-sonnet-5` | Modèle Claude utilisé pour la distribution aux sous-agents |
| `SMOLFIRE_EXECUTOR` | `vm` | Sélection de l'exécuteur `vm` ou `jail` |

Les états FSM sont `idle -> dispatching -> waiting -> harvesting -> halted`.
Pendant `dispatching`, le coordinateur lance automatiquement la CLI `claude`
pour l'agent cible si elle est présente dans le `PATH` (câblage Phase II) ;
sinon il met la requête en file d'attente et attend qu'un agent externe réponde
dans le spool. Arrêt d'urgence global : `touch var/mail/HALT` — `coord-run.sh`
cesse alors d'appeler `coord-tick.nu` et dort pendant `HALT_INTERVAL` secondes
jusqu'à suppression du fichier. Arrêt par tâche : `var/mail/HALT.<task_id>`.
Pour reprendre une tâche arrêtée, envoyez un message dans le spool avec
`X-Resume-Action: retry | abort | edit`.

## Tests

```sh
sh tests/run-all.sh
```

Exécute chaque suite `tests/*-test.nu`. Les suites dépendantes du matériel
(TPM) renvoient `SKIP` au lieu d'échouer lorsque le matériel ou l'image sont
absents, de sorte qu'un clone neuf est vert dès le départ. Les suites
individuelles peuvent être lancées directement avec `nu tests/<file>.nu`.

## Licence

Apache-2.0 pour le code du projet (voir [LICENSE](LICENSE)). Les composants issus
de la base FreeBSD conservent leurs licences BSD-2-Clause / BSD-3-Clause
d'origine. Aucune dépendance GPL/LGPL/AGPL.
