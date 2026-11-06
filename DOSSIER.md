# Dossier - Durcissement d'un serveur Debian 13 (XTI302-CYB)

Contexte C - Laboratoire BioLab. Groupe : Mathurin, Gabriel, Teo.

## 1. Tableau de conformité

_À compléter : exigence → ce qui a été fait → test de `verifier.sh` → recommandation ANSSI._

## 2. Choix techniques

_À compléter._

## 3. Défense

_À compléter._

## 4. Procédure de restauration d'une sauvegarde

Les sauvegardes sont sur le second disque, monté sur `/sauvegardes` (lisible par
les seuls membres de `admins`). Chaque version est un dossier daté
`AAAA-MM-JJ_HHMMSS` qui contient une copie complète de `/etc` et de `/srv`, avec
les propriétaires, les droits et les ACL d'origine.

### 4.1 Trouver la bonne version

```bash
# Versions disponibles, de la plus ancienne à la plus récente
sudo ls /sauvegardes

# Dans quelles versions le fichier existe-t-il, et avec quelle taille / date ?
sudo ls -l /sauvegardes/*/srv/publications/rapport.pdf
```

Si le fichier a été supprimé ou chiffré (rançongiciel), on choisit la dernière
version **antérieure** à l'incident : c'est tout l'intérêt des versions datées
par rapport à une simple copie miroir.

### 4.2 Restaurer un fichier

```bash
# -a : propriétaire, droits, dates ; -A : ACL ; -X : attributs étendus
sudo rsync -aAX /sauvegardes/2026-11-06_020000/srv/publications/rapport.pdf /srv/publications/
```

Pour éviter d'écraser la version actuelle, on peut d'abord restaurer à côté puis comparer :

```bash
sudo rsync -aAX /sauvegardes/2026-11-06_020000/srv/publications/rapport.pdf /tmp/
sudo diff /tmp/rapport.pdf /srv/publications/rapport.pdf
```

### 4.3 Restaurer un répertoire entier

```bash
# La barre oblique finale de la source copie le CONTENU du dossier
sudo rsync -aAX /sauvegardes/2026-11-06_020000/srv/analyses/ /srv/analyses/
```

Ajouter `--delete` seulement pour remettre le dossier **exactement** dans l'état
de la sauvegarde (les fichiers créés depuis seraient alors supprimés).

### 4.4 Vérifier

```bash
ls -l /srv/publications/rapport.pdf
getfacl /srv/publications/rapport.pdf        # les ACL doivent être revenues
sudo ./verifier.sh                           # test_B4 restaure aussi un fichier à blanc
```

### 4.5 Test réalisé

_À compléter avec le test fait sur la VM : fichier supprimé, version utilisée,
commandes, résultat (B4)._
