# Infrastructure CTFd

L'objectif de ce dépôt est de proposer un outil simple de configuration et de gestion des challenges pour les infrastructures CTFd. Il a été testé et validé sur les infrastructures CTFd de [PolyCyber](polycyber.io) (PolyPwn2025, PolyPwn2026, ainsi que le CTFd interne de PolyCyber).

## Scripts disponibles

### 1. Script d'installation CTFd (`setup.sh`)

Script Bash qui automatise l'installation et la configuration d'un serveur CTFd en utilisant le plugin [Zync](https://github.com/28Pollux28/zync) et son instancer dédié [Galvanize](https://github.com/28Pollux28/galvanize).

### 2. Outil de gestion des challenges (`challenges_management.sh`)

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
   - Entrer l'URL de votre instancer Galvanize et le secret JWT généré par le script d'installation

## Options du script d'installation

| Option                   | Description                                                             | Requis   |
|--------------------------|-------------------------------------------------------------------------|----------|
| `--domain URL/IP`      | URL/domaine de votre serveur CTFd                                       | ✅ Oui   |
| `--working-folder DIR`   | Répertoire de travail (défaut : `/home/$USER`)                          | ❌ Non   |
| `--theme DIR/URL`        | Permet l'utilisation d'un thème personnalisé                            | ❌ Non   |
| `--backup-schedule TYPE` | Fréquence des sauvegardes de la base de données (`daily` (défaut), `hourly`, `10min`) | ❌ Non   |
| `--no-https`             | Déploiement sans HTTPS                                                  | ❌ Non   |
| `--help`                 | Afficher l'aide                                                         | ❌ Non   |

## Exemples d'installation

```bash
# Installation basique avec domaine
./setup.sh --domain exemple.com

# Installation basique avec une IP - utilise automatiquement l'option --no-https
./setup.sh --domain 192.168.123.123

# Installation avec répertoire personnalisé
./setup.sh --domain exemple.com --working-folder /opt/ctfd

# Installation avec thème personnalisé
./setup.sh --domain exemple.com --theme /home/user/my-custom-theme

# Installation avec thème personnalisé téléchargé directement depuis github
./setup.sh --domain exemple.com --theme https://github.com/user/theme.git

# Sauvegarde horaire
./setup.sh --domain exemple.com --backup-schedule hourly

# Sauvegarde toutes les 10 minutes
./setup.sh --domain exemple.com --backup-schedule 10min

# Afficher l'aide
./setup.sh --help
```

## Configuration du thème personnalisé

Si vous utilisez l'option `--theme`, le script montera automatiquement le dossier du thème personnalisé dans le `docker-compose.yml`.

# Outil de gestion des challenges

## Actions disponibles

| Action    | Description                              |
|-----------|------------------------------------------|
| `all`     | Construction + ingestion (défaut)        |
| `build`   | Construction des images Docker seulement |
| `ingest`  | Ingestion des challenges dans CTFd       |
| `sync`    | Synchronisation des challenges existants |
| `status`  | Affichage du statut et des statistiques  |
| `cleanup` | Nettoyage des images Docker              |

## Options principales

| Option                 | Description                                                                          | Requis  |
|------------------------|--------------------------------------------------------------------------------------|---------|
| `--ctf-repo REPO`      | Nom du dépôt de challenges présent dans le répertoire de travail                     | ✅ Oui  |
| `--action ACTION`      | Action à effectuer (all (défaut), build, ingest, sync, status, cleanup)              | ❌ Non  |
| `--working-folder DIR` | Répertoire de travail (défaut : `/home/$USER`)                                       | ❌ Non  |
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

## Options de debug

| Option                | Description                          |
|-----------------------|--------------------------------------|
| `--debug`             | Activer la sortie de debug           |
| `--skip-docker-check` | Ignorer la vérification du daemon Docker |
| `--help`              | Afficher l'aide                      |
| `--version`           | Afficher les informations de version |

## Exemples de gestion des challenges

```bash
# Configuration complète (construction + ingestion)
./challenges_management.sh --ctf-repo challenge_repo

# Construction uniquement pour certaines catégories
./challenges_management.sh --action build --ctf-repo challenge_repo --categories "web,crypto"

# Synchronisation avec mise à jour forcée
./challenges_management.sh --action sync --ctf-repo challenge_repo --force

# Mode simulation pour voir les actions planifiées
./challenges_management.sh --ctf-repo challenge_repo --dry-run

# Traitement de challenges spécifiques
./challenges_management.sh --action build --ctf-repo challenge_repo --challenges "web-challenge-1,crypto-rsa"

# Construction parallèle avec 8 threads
./challenges_management.sh --action build --ctf-repo challenge_repo --parallel-builds 8

# Afficher le statut
./challenges_management.sh --action status --ctf-repo challenge_repo

# Nettoyer les images Docker
./challenges_management.sh --action cleanup --ctf-repo challenge_repo
```

### Fichier de configuration

Créez un fichier `.env` avec des paires `CLÉ=VALEUR` :

```bash
CTF_REPO=challenge_repo
WORKING_DIR=/opt/ctf
PARALLEL_BUILDS=8
FORCE=true
DEBUG=false
```

Utilisation :
```bash
./challenges_management.sh --config .env
```

# Fonctionnalités des scripts

## Script d'installation CTFd

### 1. Mise à jour du système
- Mise à jour des paquets système
- Installation des dépendances

### 2. Installation de Docker
- Ajout du dépôt Docker officiel
- Installation de Docker CE, Docker Compose, etc.
- Configuration des groupes d'utilisateurs

### 3. Configuration du thème (optionnel)
Si le flag `--theme` est utilisé :
- Montage le dossier `theme/custom/` dans le conteneur CTFd
- Permet l'utilisation de thèmes personnalisés

## Outil de gestion des challenges

### 1. Vérification des dépendances
- Vérification de la disponibilité de Docker et du daemon
- Vérification des outils système requis (curl, jq, yq)

### 2. Découverte des challenges
- Analyse de la structure du dépôt de challenges
- Identification des challenges Docker et statiques

### 3. Construction des images Docker
- Construction séquentielle ou parallèle des images
- Support du mode `--force` pour une reconstruction complète
- Gestion des erreurs avec rapports détaillés

### 4. Ingestion des challenges
- Installation via l'API CTFd dans l'instance CTFd

### 5. Synchronisation
- Mise à jour des challenges existants
- Option de sauvegarde avant la synchronisation
- Support du mode `--force` pour l'écrasement

### 6. Nettoyage
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

> [!WARNING]
> Le script d'ingestion des challenges fonctionne dans l'ordre alphabétique des catégories et des challenges. Si un challenge a des prérequis, il est nécessaire d'ingérer les prérequis au préalable en les nommant de manière appropriée.

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

requirements:
  - "Rules"

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

value: 5
type: zync                            # ou type: dynamic / static

# Les options suivantes sont réservées au type: zync. Voir https://github.com/28Pollux28/galvanize/blob/master/data/challenges/exemple/challenge.yml pour la configuration à jour

playbook_name: http                   # Utiliser 'http' pour les challenges web, 'tcp' pour les challenges TCP, ou 'custom_compose' pour les configurations Docker Compose personnalisées
deploy_parameters:
  image: nginx:alpine                 # Image Docker à déployer
  unique: false                       # Mettre à true si une instance unique est nécessaire pour tous les joueurs
  published_ports:                    # Ports à exposer depuis le conteneur (Uniquement pour les playbooks 'tcp')
    - 80                              # Port à exposer
  compose_definition: |-              # Définition Docker Compose (Uniquement pour les playbooks 'custom_compose')
    version: '3'
    services:
      web:
        image: nginx:alpine
        ports:
          - "80:80"
  env:                                # Variables d'environnement transmises au conteneur
    FLAG: "flag{flag_to_find_in_env}"
    TZ: Europe/Zurich
```

## Configuration générée

Le script d'installation génère automatiquement :
- **Clé secrète CTFd** (32 caractères)
- **Mot de passe de la base de données** (16 caractères)
- **Mot de passe root de la base de données** (16 caractères)

---

Ces scripts ont initialement été développés pour l'équipe PolyCyber afin d'automatiser l'installation et la gestion des serveurs CTFd. Ils ont été conçus pour fonctionner spécifiquement avec l'instancer [Galvanize](https://github.com/28Pollux28/galvanize) et le plugin [Zync](https://github.com/28Pollux28/zync).