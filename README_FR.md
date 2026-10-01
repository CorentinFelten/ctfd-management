# Infrastructure CTFd

L'objectif de ce dépôt est de proposer un outil simple de configuration et de gestion des challenges pour les infrastructures CTFd. Il a été testé et validé sur les infrastructures CTFd de [PolyCyber](polycyber.io) (PolyPwn2025, PolyPwn2026, ainsi que le CTFd interne de PolyCyber).

## Scripts disponibles

### 1. Script d'installation CTFd (`setup.sh`)

Script Bash qui automatise l'installation et la configuration d'un serveur CTFd en utilisant le plugin [Zync](https://github.com/28Pollux28/zync) et son instancer dédié [Galvanize](https://github.com/28Pollux28/galvanize).

### 2. Outil de gestion des challenges (`challenges.sh`)

Script Bash pour construire, ingérer et synchroniser les challenges CTF avec support des conteneurs Docker et Docker Compose.

# Prérequis

## Pour le script d'installation CTFd

- **Système d'exploitation** : Testé et vérifié sur :
  - Ubuntu Server 24
  - Ubuntu Server 25
  - Debian 12
- **Privilèges** : Le script doit être exécuté en tant que root (utilise automatiquement sudo si nécessaire)

## Pour l'outil de gestion des challenges

- **Docker** : Installé et fonctionnel
- **curl, jq, yq** : Pour les appels API et le traitement YAML/JSON (vérifiés automatiquement)
- **Dépôt de challenges** : Structure de dossiers avec des fichiers `challenge.yml`

# Installation du serveur CTFd

1. **Cloner ce dépôt** :
   ```bash
   git clone https://github.com/CorentinFelten/infra
   cd infra
   ```

2. **Exécuter le script d'installation et suivre les instructions** :
   ```bash
   ./setup.sh --domain <domaine.com>
   ```

3. **Accéder à l'URL du serveur configuré**
   - Configurer l'événement CTF
   - Naviguer vers le panneau de configuration administrateur : `Admin Panel` --> `Plugins` --> `Zync Config`
   - Vérifier l'URL de l'instancer Galvanize et le secret JWT (tous deux pré-remplis par le script d'installation, voir ci-dessous)

   > **URL de l'instancer et secret JWT** : avec le workflow d'installation fourni, les deux sont injectés automatiquement dans le conteneur CTFd depuis `deploy/.env` : `ZYNC_DEPLOYER_URL` (`https://instancer.<domaine>` pour l'instancer intégré) et `ZYNC_JWT_SECRET`. Le même secret est écrit dans la configuration de Galvanize. Vous n'avez donc pas besoin de saisir ces valeurs manuellement dans le panneau Zync Config.

## Options du script d'installation

| Option                   | Description                                                                               | Requis   |
|--------------------------|-------------------------------------------------------------------------------------------|----------|
| `--domain URL/IP`        | URL/domaine de votre serveur CTFd                                                         | ✅ Oui   |
| `--working-folder DIR`   | Répertoire de travail (défaut : votre répertoire personnel, `/root` en root)             | ❌ Non   |
| `--theme SOURCE`         | Installer un thème personnalisé : dossier ou URL Git (`#ref` pour une branche/un tag). Répétable | ❌ Non   |
| `--remove-theme NAME`    | Supprimer un thème personnalisé installé. Répétable                                       | ❌ Non   |
| `--active-theme NAME`    | Définir NAME comme thème actif de CTFd                                                    | ❌ Non   |
| `--backup-schedule TYPE` | Fréquence des sauvegardes (`daily` (défaut), `hourly`, `10min`)                           | ❌ Non   |
| `--instancer-url URL`    | Utiliser un instancer Galvanize externe plutôt que d'en déployer un localement            | ❌ Non   |
| `--no-instancer`         | Ignorer la configuration de Galvanize (le déployer séparément plus tard)                  | ❌ Non   |
| `--dns-provider NAME`    | Fournisseur DNS pour les certificats TLS wildcard (défaut : `cloudflare`)                 | ❌ Non   |
| `--acme-email EMAIL`     | Adresse email pour les certificats Let's Encrypt (requis pour HTTPS)                      | ✅ HTTPS |
| `--no-https`             | Déploiement sans HTTPS (activé automatiquement pour les adresses IP)                     | ❌ Non   |
| `--yes`                  | Répondre à chaque question par sa valeur par défaut, pour une exécution sans surveillance | ❌ Non   |
| `--help`                 | Afficher l'aide                                                                           | ❌ Non   |

> `--instancer-url` et `--no-instancer` sont mutuellement exclusifs.
>
> `--domain` doit être une adresse joignable par les joueurs : les adresses de loopback (`127.0.0.1`, `localhost`, `::1`) et `0.0.0.0` sont refusées. L'instancer Galvanize se connecte aussi à cette adresse en SSH depuis son conteneur, où une adresse de loopback désigne le conteneur lui-même. Pour un déploiement par IP, utilisez l'IP réelle du serveur (`ip -4 route get 1.1.1.1` l'affiche).

> **Exécution sans surveillance (`--yes`)** : chaque question prend sa réponse par défaut. Lors d'une réexécution, la paire de clés SSH Ansible est donc recréée (le conteneur de l'instancer est recréé pour la prendre en compte). L'assistant DNS ne peut pas demander les identifiants : pour un déploiement HTTPS, ils doivent déjà se trouver dans `deploy/traefik.env`, ou être passés dans l'environnement root (`sudo CF_DNS_API_TOKEN=... ./setup.sh ... --yes`). Sans `--yes`, une question posée sans terminal (CI, cron) échoue avec un message indiquant `--yes`.

## Exemples d'installation

```bash
# Installation basique avec domaine (inclut l'instancer Galvanize local par défaut)
./setup.sh --domain exemple.com --acme-email admin@exemple.com

# Installation basique avec une IP - utilise automatiquement l'option --no-https
./setup.sh --domain 192.168.123.123

# Installation avec répertoire personnalisé
./setup.sh --domain exemple.com --working-folder /opt/ctfd

# Installation avec thème personnalisé
./setup.sh --domain exemple.com --theme /home/user/my-custom-theme

# Installation avec thème personnalisé téléchargé directement depuis github
./setup.sh --domain exemple.com --theme https://github.com/user/theme.git

# Plusieurs thèmes, dont un épinglé sur un tag Git, et choix du thème actif
./setup.sh --domain exemple.com --theme https://github.com/user/theme.git#v2.0 \
  --theme ./second-theme --active-theme theme

# Email ACME personnalisé pour Let's Encrypt
./setup.sh --domain exemple.com --acme-email admin@exemple.com

# Sauvegarde horaire
./setup.sh --domain exemple.com --backup-schedule hourly

# Sauvegarde toutes les 10 minutes
./setup.sh --domain exemple.com --backup-schedule 10min

# Utiliser un instancer Galvanize externe
./setup.sh --domain exemple.com --instancer-url https://instancer.exemple.com

# Ignorer Galvanize entièrement (le déployer indépendamment plus tard)
./setup.sh --domain exemple.com --no-instancer

# Afficher l'aide
./setup.sh --help
```

## Configuration du thème personnalisé

`--theme` installe un thème personnalisé et peut être donné autant de fois que nécessaire. Chaque source est un dossier local ou une URL Git ; ajoutez `#REF` à une URL Git pour cloner une branche ou un tag (`https://github.com/user/theme.git#v2.0`). Le thème prend le nom du dossier ou du dépôt (`theme` ici) et doit contenir un dossier `templates/`. Les noms `core`, `core-deprecated` et `admin` sont les thèmes de CTFd et sont refusés.

Les thèmes sont intégrés à l'image CTFd : ils sont conservés dans `<working-folder>/deploy/ctfd/themes/<nom>/`, et `Dockerfile.ctfd` copie ce dossier à côté des thèmes intégrés de CTFd. Ils restent donc installés lors des exécutions suivantes du setup, y compris sans `--theme` ; redonner un thème le met à jour, et `--remove-theme NOM` le supprime. Une modification directe d'un thème prend effet après reconstruction de l'image (`docker compose build ctfd && docker compose up -d` dans `deploy/`, ou une exécution du setup).

Les thèmes installés apparaissent dans CTFd sous **Admin Panel → Config → Themes**. `--active-theme NOM` en sélectionne un depuis le setup (`core` revient au thème par défaut). Tant que l'assistant de première installation de CTFd n'a pas été terminé, c'est son propre champ Theme qui décide : le setup le signale, et les thèmes personnalisés y sont proposés.

Les déploiements antérieurs à ce changement montaient un seul thème depuis `deploy/data/CTFd/themes/<THEME_NAME>` ; l'exécution suivante du setup le copie automatiquement dans l'image.

## Déploiement de l'instancer Galvanize

Par défaut, `setup.sh` déploie Galvanize dans le même stack Docker Compose que CTFd. Deux alternatives sont disponibles :

- **`--instancer-url URL`** — pointer CTFd vers une instance Galvanize déjà en cours d'exécution ; aucun conteneur local n'est démarré.
- **`--no-instancer`** — ignorer Galvanize entièrement lors de l'installation. Vous pouvez le déployer indépendamment plus tard avec sa propre configuration (voir `config/galvanize/config.yaml` pour le modèle de configuration et `config/galvanize/playbooks/` pour les playbooks Ansible). `ZYNC_DEPLOYER_URL` vaut `https://instancer.<domaine>` par défaut ; modifiez-le dans `deploy/.env` si votre instancer est ailleurs.

`setup.sh` enregistre ce choix dans `deploy/.env` via `COMPOSE_PROFILES` (`instancer` pour l'instancer intégré, vide sinon) : un simple `docker compose up -d`, `down` ou `pull` lancé depuis `deploy/` ne démarre et ne gère l'instancer que s'il est hébergé localement. Abandonner l'instancer intégré arrête et supprime son conteneur à la prochaine exécution du setup.

### Configuration de Galvanize

Le modèle `config/galvanize/config.yaml` est copié vers `deploy/data/galvanize/config.yaml` à **chaque** exécution de `setup.sh` : faites donc vos modifications durables dans le modèle plutôt que dans la copie déployée. Le script renseigne ensuite :

| Clé | Valeur |
|-----|--------|
| `auth.jwt_secret` | Secret généré (partagé avec CTFd via `ZYNC_JWT_SECRET`) |
| `instancer.ansible.user` / `inventory` | `ansible-user` sur l'hôte `--domain` |
| `instancer.instancer_host` | `--domain`, ou `<ip>.sslip.io` pour les déploiements sur IP (DNS wildcard) |
| `instancer.redis.addr` / `db` | `redis:6379`, base `1` (CTFd utilise la base `0` du même Redis) |
| `instancer.extra_deployment_parameters.traefik_network` | `<COMPOSE_PROJECT_NAME>_challenges` (voir [Isolation réseau](#isolation-réseau)) |

Autres valeurs par défaut : les ports hôtes TCP sont tirés au hasard pour chaque équipe (`randomize_published_ports: true`), et chaque conteneur de challenge est limité à 1 CPU, 512 Mo de RAM et 256 PID, sauf si le challenge surcharge `resource_limits`.

### Playbooks Galvanize

Les playbooks Ansible (`http`, `tcp`, `custom_compose`) sont fournis dans `config/galvanize/playbooks/` et copiés vers `deploy/data/galvanize/playbooks/` à chaque exécution du setup. Ce sont des copies du dossier [`data/playbooks/`](https://github.com/28Pollux28/galvanize/tree/master/data/playbooks) de Galvanize (v0.7.1) : le montage `data/` masque les playbooks intégrés à l'image Galvanize, ils doivent donc se trouver sur l'hôte. Ils diffèrent de l'amont sur un point : une tâche « Normalise resource limits for Docker Compose » déplace la limite de PID de `pids_limit` vers `deploy.resources.limits.pids`, car Docker Compose 2.38+ refuse un service qui définit `pids_limit` à côté de `deploy.resources.limits`, ce qui fait échouer chaque déploiement avec les limites par défaut. Lors d'une mise à jour de Galvanize, recopiez ces fichiers depuis le dépôt amont en conservant cette tâche, sauf si l'amont a corrigé le problème.

### Isolation réseau

Le stack utilise des réseaux Docker séparés afin que les conteneurs de challenges, contrôlés par les joueurs, ne puissent pas atteindre la plateforme :

| Réseau | Membres | Rôle |
|--------|---------|------|
| `proxy` | Traefik, CTFd, instancer | Entrée publique (ports 80/443), SSH sortant de l'instancer vers l'hôte cible Ansible |
| `internal` (sans accès internet) | CTFd, MariaDB, Redis, instancer | Trafic backend (base de données, Redis) |
| `challenges` | Traefik, instances de challenges | Routage Traefik vers les challenges `http` |

- L'API Galvanize doit être joignable publiquement : Zync l'appelle directement depuis le navigateur des joueurs (et depuis le tableau de bord admin), ce qui permet aussi d'héberger Galvanize sur une machine séparée (`--instancer-url`). L'instancer intégré est publié par Traefik sur son propre sous-domaine, `https://instancer.<domaine>` (`http://instancer.<ip>.sslip.io` pour les déploiements sur IP), sur le port 443. Aucun port supplémentaire (comme 8080) n'est ouvert, et son endpoint Prometheus `/metrics` n'est pas routé. Ce sous-domaine doit pointer vers le serveur ; l'enregistrement DNS wildcard utilisé pour les sous-domaines des challenges (`*.<domaine>`) le couvre déjà.
- Les instances de challenges ne peuvent pas joindre directement CTFd, MariaDB, Redis ni l'instancer ; elles ne voient que les mêmes points d'accès publics que les joueurs. Elles peuvent toujours joindre Traefik, les autres instances du réseau `challenges` et internet. Les challenges TCP tournent sur le réseau bridge par défaut de Docker.
- Le provider Docker de Traefik utilise le réseau `challenges` par défaut, car les conteneurs déployés par Galvanize n'ont pas de label `traefik.docker.network`. Les services de la plateforme routés par Traefik (CTFd) doivent définir explicitement `traefik.docker.network=<COMPOSE_PROJECT_NAME>_proxy`.

> **Mise à jour d'un déploiement existant** : arrêtez d'abord les instances de challenges en cours (elles sont rattachées à l'ancien réseau), puis relancez `setup.sh`. Cela réécrit `docker-compose.yml`, les configs Traefik, la config et les playbooks Galvanize, et remet `ZYNC_DEPLOYER_URL` à `https://instancer.<domaine>` (sauf si `--instancer-url` est fourni). Zync met en cache l'URL de l'instancer dans le navigateur de chaque joueur (`localStorage`) : faites la mise à jour entre deux événements, car les joueurs ayant déjà ouvert un challenge avec l'ancienne URL `:8080` continueront de l'utiliser jusqu'à ce que leurs données de site soient effacées.

## Structure du répertoire de déploiement

Après l'exécution de `setup.sh`, la structure suivante est créée dans `<working-folder>/deploy/` :

```
deploy/
├── docker-compose.yml          # Fichier compose actif (copié depuis le dépôt)
├── .env                        # Variables d'environnement et secrets générés
├── .secrets                    # Copie en clair des secrets générés (chmod 600)
├── traefik.env                 # Identifiants du fournisseur DNS, seul env reçu par Traefik (chmod 600)
├── traefik-config/             # Configs statiques et dynamiques Traefik, stockage letsencrypt
├── ctfd/                       # Contexte de build de l'image CTFd (Dockerfile, entrypoint)
│   ├── plugins/zync/           # Clone du plugin instancer CTFd
│   └── themes/                 # Thèmes personnalisés (--theme), intégrés à l'image CTFd
├── ansible-ssh/                # Paire de clés SSH Ansible (instancer local uniquement)
├── data/                       # Données d'exécution (base de données, uploads, galvanize)
│   ├── CTFd/
│   ├── mysql/
│   ├── redis/
│   └── galvanize/              # Données Galvanize (instancer local uniquement)
│       ├── config.yaml         # Config Galvanize (depuis config/galvanize/config.yaml)
│       ├── playbooks/          # Playbooks Ansible (depuis config/galvanize/playbooks/)
│       ├── challenges/         # Dépôts de challenges indexés par Galvanize
│       └── deployer.sqlite     # Base de données des déploiements Galvanize
└── cron_backup.log             # Journal du cron de sauvegarde
```

# Outil de gestion des challenges

## `challenge.yml` : le standard ctfcli, sans l'outil

Les challenges sont décrits avec le même format `challenge.yml` que celui
utilisé par l'outil officiel [`ctfcli`](https://github.com/CTFd/ctfcli) de CTFd.
Les dépôts de challenges compatibles ctfcli fonctionnent donc ici sans
modification, et les challenges rédigés pour cet outil restent portables vers
ctfcli.

Ce que cet outil ne fait **pas**, c'est encapsuler ou dépendre de `ctfcli`.
L'ingestion et la synchronisation sont implémentées nativement en Bash via
l'API REST de CTFd (`curl` + `jq`). Cela garde l'outil léger en dépendances
(aucun environnement Python/pip à gérer) et permet à une seule exécution de
construire les images Docker, d'enregistrer le challenge dans CTFd et de câbler
le déploiement [Galvanize](https://github.com/28Pollux28/galvanize)/[Zync](https://github.com/28Pollux28/zync)
en même temps.

Les champs `challenge.yml` suivants sont pris en charge : `name`, `category`,
`description`, `value`, `type` (les `standard`/`dynamic` de ctfcli, plus
l'extension `zync` spécifique à Galvanize), `state`, `connection_info`,
`attempts`, `attribution`, les valeurs de scoring dynamique
`initial`/`minimum`/`decay`, `flags`, `files`, `hints` (y compris `title`,
`cost` et le verrouillage par prérequis via `key`), `tags`, `topics`,
`requirements` (soit une simple liste de prérequis, soit la forme objet
`{prerequisites, anonymize}`), ainsi qu'une map `extra` transmise telle quelle
pour les champs des plugins CTFd.

## Authentification

Lors de la première exécution d'une action qui communique avec CTFd (`ingest`,
`sync`, ou l'action par défaut `all`), l'outil demande l'URL de votre instance
CTFd ainsi qu'un **token d'accès administrateur**. Générez ce token au préalable
depuis l'interface web de CTFd, connecté en tant qu'administrateur :
**Settings → Access Tokens → Generate**. Le compte doit disposer des droits
admin, car l'ingestion et la gestion des challenges utilisent des endpoints API
réservés aux administrateurs.

L'URL et le token sont enregistrés dans `<working-folder>/.ctfd/config` et
réutilisés lors des exécutions suivantes : vous n'êtes donc sollicité qu'une
seule fois.

## Actions disponibles

| Action    | Description                              |
|-----------|------------------------------------------|
| `all`     | Construction + ingestion (défaut)        |
| `build`   | Construction des images Docker seulement |
| `ingest`  | Ingestion des challenges dans CTFd       |
| `sync`    | Synchronisation des challenges existants |
| `status`  | Affichage du statut et des statistiques  |
| `cleanup` | Arrêt des stacks compose et nettoyage des images Docker (respecte les filtres `--categories`/`--challenges`) |

## Options principales

| Option                 | Description                                                                          | Requis  |
|------------------------|--------------------------------------------------------------------------------------|---------|
| `--repo REPO`          | Nom du dépôt de challenges présent dans le répertoire de travail                     | ✅ Oui  |
| `--action ACTION`      | Action à effectuer (all (défaut), build, ingest, sync, status, cleanup)              | ❌ Non  |
| `--working-folder DIR` | Répertoire de travail (défaut : votre répertoire personnel)                          | ❌ Non  |
| `--config FILE`        | Charger une configuration depuis un fichier                                          | ❌ Non  |

## Options de filtrage

| Option              | Description                                                      |
|---------------------|------------------------------------------------------------------|
| `--categories LIST` | Liste des catégories à traiter (séparées par des virgules)       |
| `--challenges LIST` | Liste des challenges spécifiques à traiter (séparés par des virgules) |

## Options de comportement

| Option                | Description                                                         |
|-----------------------|---------------------------------------------------------------------|
| `--dry-run`           | Mode simulation (affiche les actions sans les exécuter)             |
| `--force`             | Forcer les opérations (reconstruction, écrasement)                  |
| `--parallel-builds N` | Nombre de constructions parallèles (défaut : 4)                     |
| `--build-images MODE` | Construction des images : `auto` (défaut), `yes`, `no`              |

## Options de debug

| Option                | Description                              |
|-----------------------|------------------------------------------|
| `--debug`             | Activer la sortie de debug               |
| `--skip-docker-check` | Ignorer la vérification du daemon Docker |
| `--help`              | Afficher l'aide                          |
| `--version`           | Afficher les informations de version     |

## Exemples de gestion des challenges

```bash
# Configuration complète (construction + ingestion)
./challenges.sh --repo challenge_repo

# Construction uniquement pour certaines catégories
./challenges.sh --action build --repo challenge_repo --categories "web,crypto"

# Synchronisation avec mise à jour forcée
./challenges.sh --action sync --repo challenge_repo --force

# Mode simulation pour voir les actions planifiées
./challenges.sh --repo challenge_repo --dry-run

# Traitement de challenges spécifiques
./challenges.sh --action build --repo challenge_repo --challenges "web-challenge-1,crypto-rsa"

# Construction parallèle avec 8 threads
./challenges.sh --action build --repo challenge_repo --parallel-builds 8

# Afficher le statut
./challenges.sh --action status --repo challenge_repo

# Nettoyer les images Docker
./challenges.sh --action cleanup --repo challenge_repo
```

### Fichier de configuration

Créez un fichier `.env` avec des paires `CLÉ=VALEUR` :

```bash
REPO=challenge_repo
WORKING_DIR=/opt/ctf
PARALLEL_BUILDS=8
FORCE=true
DEBUG=false
```

Utilisation :
```bash
./challenges.sh --config .env
```

# Fonctionnalités des scripts

## Script d'installation CTFd

### 1. Mise à jour du système
- Mise à jour des paquets système
- Installation des dépendances

### 2. Installation de Docker
- Ajout du dépôt Docker officiel
- Installation de Docker CE, Docker Compose, etc.
- Activation du service Docker au démarrage
- Configuration des groupes d'utilisateurs

### 3. Configuration du thème (optionnel)
Avec `--theme`, `--remove-theme` ou `--active-theme` :
- Installe, met à jour ou supprime les thèmes personnalisés intégrés à l'image CTFd
- Définit éventuellement le thème actif de CTFd (voir [Configuration du thème personnalisé](#configuration-du-thème-personnalisé))

## Outil de gestion des challenges

### 1. Vérification des dépendances
- Vérification de la disponibilité de Docker et du daemon
- Vérification des outils système requis (curl, jq, yq)

### 2. Découverte des challenges
- Analyse de la structure du dépôt de challenges
- Identification des challenges Docker et statiques

### 3. Construction des images Docker
- Uniquement lorsque l'instancer Galvanize est hébergé sur cette machine : Galvanize déploie les images depuis son propre hôte Docker, donc des images construites ailleurs ne sont jamais utilisées. La détection (`--build-images auto`) lit `INSTANCER_MODE` dans `<working-folder>/deploy/.env` (écrit par `setup.sh` : `local`, `external` ou `none`), se rabat sur un `GALVANIZE_CONFIG_PATH` local pour les anciens déploiements, puis sur un conteneur `galvanize-instancer` en cours d'exécution. Sans instancer local, `all` passe directement à l'ingestion et `build` ne fait rien. Forcer avec `--build-images yes` ou `--build-images no`.
- Construction séquentielle ou parallèle des images
- Support du mode `--force` pour une reconstruction complète
- Gestion des erreurs avec rapports détaillés

### 4. Ingestion des challenges
- Installation via l'API REST de CTFd dans l'instance CTFd
- Les challenges sont installés dans l'**ordre des dépendances** : les `requirements` sont triés topologiquement afin qu'un prérequis soit toujours créé avant le challenge qui en dépend. Les dépendances circulaires sont détectées et signalées.
- **Installation atomique avec rollback** : si l'attachement des flags, fichiers, indices, tags, topics ou requirements échoue, le challenge partiellement créé est supprimé, de sorte qu'une ingestion échouée ne laisse aucun challenge à moitié enregistré.
- Validation des tags d'image Docker Compose avant l'ingestion, et détection des doublons (les challenges existants sont ignorés — utilisez `sync` pour les mettre à jour).

### 5. Synchronisation
- Met à jour les challenges existants **sur place** : le challenge est mis à jour via PATCH, son ID CTFd ne change donc jamais.
- **Propage les modifications des sous-ressources possédées** sans perdre l'état des joueurs :
  - **Les indices sont mis à jour sur place**, afin que les joueurs conservent les indices déjà débloqués (CTFd suit les déblocages par ID d'indice). Le Nᵉ indice de `challenge.yml` met à jour le Nᵉ indice existant : gardez l'ordre des indices stable et ajoutez les nouveaux à la fin. Les indices retirés de `challenge.yml` sont supprimés, et les joueurs y perdent l'accès.
  - **Les flags sont comparés** : les nouveaux flags sont ajoutés avant la suppression des anciens, le challenge n'est donc jamais sans flag valide.
  - **Les fichiers sont comparés** par contenu (SHA-1) et par nom : les fichiers inchangés sont conservés et gardent leur URL de téléchargement ; les fichiers nouveaux ou modifiés sont envoyés, les obsolètes supprimés.
  - Les tags et topics, qui ne portent aucun état joueur, sont supprimés puis recréés.
- **Les requirements sont résolus en une seconde passe**, une fois que tous les challenges ont été synchronisés, afin qu'un prérequis référencé par son nom soit résolu correctement quel que soit l'ordre de traitement.
- Option de sauvegarde avant la synchronisation, et mode `--force` pour l'écrasement.

### 6. Suppression sûre vis-à-vis des dépendances
- CTFd stocke les prérequis (`requirements`) sous forme d'IDs de challenges bruts et ne les nettoie pas en cascade : supprimer puis recréer un challenge lui donnerait un nouvel ID et orphelinerait silencieusement tous les challenges qui en dépendaient.
- Pour éviter cela, la synchronisation ne supprime/recrée jamais un challenge (elle le met à jour sur place via PATCH), et l'outil **refuse de supprimer un challenge listé comme prérequis par d'autres challenges** sauf si cela est explicitement forcé.

### 7. Nettoyage
- Suppression des images Docker associées aux challenges
- Mode dry-run disponible

# Structure des challenges

## Structure attendue du dépôt de challenges

```
challenge_repo/
├── challenges/                    # (optionnel, détecté automatiquement)
│   ├── web/
│   │   ├── challenge-1/
│   │   │   ├── challenge.yml      # Configuration du challenge
│   │   │   ├── Dockerfile         # Image Docker (pour type: zync)
│   │   │   ├── src/               # Code source
│   │   │   └── files/             # Fichiers du challenge
│   │   └── challenge-2/
│   ├── crypto/
│   └── pwn/
```

### Format du fichier `challenge.yml`

```yaml
name: "MonChallenge"
author: Auteur_Challenge
category: AI

description: |-
  ## Description (Français)

  Petite description en français

  ## Description (English)

  Short description in English

flags:
  - flag{flag_to_find}

tags:
  - AI
  - A:Auteur_Challenge

# Prérequis : une simple liste de noms/IDs de challenges...
requirements:
  - "Rules"
# ...ou la forme objet, pour afficher les challenges verrouillés en « ??? » au lieu de les masquer :
# requirements:
#   prerequisites:
#     - "Rules"
#   anonymize: true

# Si des fichiers sont nécessaires
files:
  - "files/hello_world.txt"

# Si des indices sont nécessaires, choisir le coût
hints:
  - Indice intéressant
  - {
    cost: 10,
    content: "Indice payant intéressant"
  }
  # Indice verrouillé : reste caché tant que le joueur n'a pas débloqué les indices requis.
  # Donnez une `key` aux indices prérequis et référencez ces clés dans `requirements`.
  - key: step1
    cost: 5
    content: "Première étape"
  - cost: 20
    content: "Deuxième étape (révélée seulement après le déblocage de step1)"
    requirements:
      - step1

value: 5
type: zync                            # ou type: dynamic / static

# Les options suivantes sont réservées au type: zync. Voir https://github.com/28Pollux28/galvanize/tree/master/data/challenges/example pour des exemples à jour (http, tcp, custom_compose)

playbook_name: http                   # 'http' (conteneur unique derrière Traefik, sous-domaine HTTPS), 'tcp' (ports publiés) ou 'custom_compose' (voir ci-dessous)
deploy_parameters:
  image: nginx:alpine                 # Image Docker à déployer (playbooks 'http' et 'tcp')
  unique: false                       # Mettre à true si une instance unique est nécessaire pour tous les joueurs
  http_port: 80                       # Port du conteneur vers lequel Traefik redirige (Uniquement pour 'http', défaut : 80)
  published_ports:                    # Ports à exposer depuis le conteneur (Uniquement pour les playbooks 'tcp')
    - 1337                            # Port hôte aléatoire par équipe ; "22/ssh" ajoute un indice de schéma d'URL, "8080:80/http" est un mapping fixe
  env:                                # Variables d'environnement transmises au conteneur
    FLAG: "flag{flag_to_find_in_env}"
    TZ: Europe/Zurich
  resource_limits:                    # Limites de ressources (surcharge les valeurs par défaut, optionnel)
    cpus: "1"
    memory: "512M"
    pids_limit: 256
```

### Challenges multi-services (Docker Compose)

Pour les challenges nécessitant plusieurs conteneurs, placez un fichier Compose standard (`compose.yaml`, `compose.yml`, `docker-compose.yaml` ou `docker-compose.yml`) à côté de `challenge.yml`. Galvanize le détecte et utilise `custom_compose` comme `playbook_name` par défaut. Déclarez les services accessibles aux joueurs avec un bloc `expose` au lieu d'écrire à la main les labels Traefik, les réseaux ou les ports hôtes :

```yaml
type: zync
deploy_parameters:
  unique: false
  expose:
    - service: web      # routé par Traefik -> https://<instance>.<domaine>/
      port: 80
      type: http
    - service: ssh      # publié sur un port hôte aléatoire par équipe
      port: 22
      type: tcp
      scheme: ssh       # optionnel, change uniquement l'URL de connexion affichée
```

Notes :

- `challenges.sh` construit chaque service ayant une clé `build:` et, s'il n'a pas d'`image:`, l'étiquette `<challenge>_<service>:latest` dans le fichier compose pour que Galvanize puisse déployer l'image construite localement. Avec un instancer distant, rien n'est construit : donnez à chaque service `build:` une `image:` étiquetée que l'hôte Docker de l'instancer peut récupérer (l'ingestion rejette les services construits sans image).
- Ne définissez ni `container_name` ni `ports:` vous-même : Galvanize nomme chaque projet par équipe et câble le réseau à partir de `expose`.
- Les contextes `build:` et les montages sont résolus sur l'hôte de déploiement : privilégiez des images pré-construites.

## Configuration générée

Le script d'installation génère automatiquement :
- **Clé secrète CTFd** (32 caractères)
- **Mot de passe de la base de données** (16 caractères)
- **Mot de passe root de la base de données** (16 caractères)
- **Secret JWT Galvanize** (48 caractères)

Tous les secrets sont écrits dans `<deploy-dir>/.secrets` (chmod 600) et dans `.env`.

Les identifiants du fournisseur DNS (pour les certificats TLS wildcard) sont écrits dans `<deploy-dir>/traefik.env` (chmod 600). C'est le seul fichier d'environnement transmis au conteneur Traefik : Traefik ne voit donc jamais les mots de passe de la base de données, la `SECRET_KEY` de CTFd ni le secret JWT de Zync. Les déploiements antérieurs à ce changement conservaient leurs identifiants DNS dans `.env` : relancer `setup.sh` les copie dans `traefik.env`, après quoi ils peuvent être retirés de `.env`.

**Comment le setup écrit la configuration.** `deploy/.env` est la source des réglages du déploiement : le setup calcule d'abord toutes les valeurs (à partir des options, du `.env` et du `.secrets` existants), puis les écrit dans `.env` en une seule passe. Les clés qu'il ne gère pas, comme celles que vous ajoutez à la main, sont conservées. Docker Compose lit tout le reste directement dans `.env`, `docker-compose.yml` n'est donc jamais modifié. Les deux fichiers YAML générés, la configuration Galvanize et la configuration statique de Traefik, sont chacun remplis par un seul appel à `yq` à partir des mêmes valeurs. Dans `config/traefik/traefik.yml`, le setup ne remplace que les marqueurs `__BASE_DOMAIN__`, `__ACME_EMAIL__` et `__DNS_PROVIDER__` : les autres valeurs que vous modifiez dans ce modèle (par exemple `caServer`, pour utiliser le serveur de test de Let's Encrypt) sont conservées. `COMPOSE_PROJECT_NAME` est pris dans l'environnement, sinon dans `.env`, sinon `ctfd_infra`.

Le port du tableau de bord Traefik (`9090`) est publié sur toutes les interfaces pour les déploiements HTTP uniquement, où le tableau de bord est activé, et seulement sur l'interface de loopback en HTTPS, où il est désactivé. C'est la valeur `TRAEFIK_DASHBOARD_BIND` de `.env`.

> **Relancer le setup est sans risque** : si des secrets existent déjà dans `.env`, ils sont préservés. Seuls les secrets manquants sont générés, donc relancer `setup.sh` ne cassera pas les conteneurs existants.

## Intégration continue

`.github/workflows/setup-e2e.yml` s'exécute à chaque push sur une branche autre que `main` (sauf changements de documentation uniquement), et peut être lancé manuellement depuis l'onglet Actions. Les branches sont fusionnées dans `main` une fois leur exécution réussie, `main` n'est donc pas retestée. Il exécute réellement `setup.sh` sur des runners Ubuntu 24.04 neufs, dans cinq jobs :

- **sans HTTPS** : `./setup.sh --domain <IP du runner> --yes`, avec l'instancer Galvanize intégré. Ce job vérifie aussi qu'un `--domain` de loopback est refusé, puis réexécute le setup avec `--instancer-url` pour vérifier que le passage à un instancer externe arrête et supprime l'instancer local.
- **HTTPS** : `./setup.sh --domain <ip-du-runner>.sslip.io --acme-email … --dns-provider cloudflare --yes`, avec l'instancer intégré, face à [Pebble](https://github.com/letsencrypt/pebble), le serveur ACME de test de Let's Encrypt, lancé sur le runner. sslip.io résout le domaine et tous ses sous-domaines vers le runner. Pour ce job uniquement, la CI fait pointer le modèle Traefik du dépôt vers Pebble et le challenge DNS-01 vers le fournisseur `exec` de lego, qui n'exécute rien (Pebble accepte tous les challenges), et pré-remplit `traefik.env` avec un faux jeton Cloudflare que `--yes` doit conserver. Ni l'API d'un vrai fournisseur DNS ni les vrais serveurs Let's Encrypt ne sont sollicités.
- **`--no-instancer`** et **`--instancer-url`** (sans HTTPS) : CTFd sans instancer local. Les vérifications s'assurent qu'aucun conteneur d'instancer, aucune donnée Galvanize, aucun utilisateur Ansible ni clé SSH n'est créé, que rien n'est routé sur `instancer.<domaine>`, et que `.env` contient les bonnes valeurs de `INSTANCER_MODE`, `COMPOSE_PROFILES` et `ZYNC_DEPLOYER_URL`.
- **Debian 13** (sans HTTPS, instancer intégré) : GitHub ne propose pas de runner Debian, ce job démarre donc une machine virtuelle Debian 13 neuve sur le runner avec [Incus](https://linuxcontainers.org/incus/) (KVM), avec seulement un utilisateur sudo et sshd, et y exécute `setup.sh` et les vérifications ci-dessous. Contrairement aux runners Ubuntu, où Docker est préinstallé, le setup installe ici Docker depuis le dépôt Debian de Docker.

Chaque job ensuite :

1. vérifie la stack (`.github/scripts/setup-e2e/check-stack.sh`) : santé des conteneurs, routage Traefik vers CTFd et l'instancer, `.env`, `traefik.env` et configuration Galvanize générés, propriété des données, accès SSH d'Ansible, tâche cron et exécution d'une sauvegarde. En mode HTTPS, il vérifie aussi qu'un certificat wildcard est émis pour le domaine et valide face à la racine de Pebble, la redirection HTTP vers HTTPS, l'en-tête HSTS, et que le port du tableau de bord Traefik est fermé ;
2. avec l'instancer intégré, déploie puis arrête une instance de challenge via l'API Galvanize avec un JWT comme celui de Zync (`deploy-challenge.sh`), en y accédant en HTTPS via Traefik (certificat vérifié en mode HTTPS) ;
3. réexécute `setup.sh --yes`, vérifie que les secrets n'ont pas changé, puis refait les vérifications (et le déploiement, avec la clé SSH recréée).

En cas d'échec, les logs des conteneurs et les configurations expurgées sont publiés dans l'artefact `setup-e2e-diagnostics-<job>`.

---

Ces scripts ont initialement été développés pour l'équipe PolyCyber afin d'automatiser l'installation et la gestion des serveurs CTFd. Ils ont été conçus pour fonctionner spécifiquement avec l'instancer [Galvanize](https://github.com/28Pollux28/galvanize) et le plugin [Zync](https://github.com/28Pollux28/zync).
