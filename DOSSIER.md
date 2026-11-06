# Dossier - Durcissement d'un serveur Debian 13 (XTI302-CYB)

Contexte C - Laboratoire BioLab. Groupe : Mathurin, Gabriel, Teo.

## 1. Tableau de conformité

_À compléter : exigence → ce qui a été fait → test de `verifier.sh` → recommandation ANSSI._

## 2. Choix techniques

_À compléter._

### D2 - Services en écoute

`ss -tulpn` ne montre que `sshd` (port 22) et le client DHCP `dhcpcd` (ports 68 en
IPv4 et 546 en IPv6). dhcpcd est nécessaire pour que la VM obtienne ses adresses :
c'est un client, il ne répond qu'aux réponses des serveurs DHCP, et le pare-feu
(J2) ne laisse de toute façon entrer que SSH.

L'installation de départ n'était pas strictement minimale : `avahi-daemon` (mDNS,
port 5353 et un port aléatoire) écoutait sur toutes les interfaces. `installer.sh`
l'arrête et le **masque**, ainsi que `ModemManager` (pilotage de modems 3G/4G).
Masquer plutôt que désactiver : avahi peut être relancé par D-Bus ou par sa socket ;
un service masqué ne peut plus démarrer. On ne désinstalle pas, pour ne pas
entraîner la suppression d'autres paquets.

### D3 - Fichiers SUID

Un fichier SUID s'exécute avec les droits de son propriétaire (ici root), quel que
soit l'utilisateur qui le lance. Chacun est donc une porte possible vers root
(voir GTFOBins). Liste relevée sur la VM (`config/suid_attendus.txt`) :

| Fichier | Pourquoi il est SUID |
|---|---|
| `/usr/bin/passwd` | un utilisateur change son propre mot de passe : il faut écrire dans `/etc/shadow`, lisible par root seul |
| `/usr/bin/chfn`, `/usr/bin/chsh` | changer ses informations (nom complet) ou son shell : écriture dans `/etc/passwd` |
| `/usr/bin/gpasswd`, `/usr/bin/newgrp` | gérer un groupe protégé par mot de passe, en changer pour la session |
| `/usr/bin/su` | devenir un autre utilisateur ; inutile en pratique car root est verrouillé (C4) |
| `/usr/bin/sudo` | élévation contrôlée par `/etc/sudoers.d/xti302` (C3) : indispensable |
| `/usr/bin/pkexec`, `/usr/lib/polkit-1/polkit-agent-helper-1` | équivalent de sudo piloté par polkit (CVE-2021-4034 « PwnKit » : à surveiller) |
| `/usr/lib/dbus-1.0/dbus-daemon-launch-helper` | lance les services système D-Bus à la demande |
| `/usr/bin/mount`, `/usr/bin/umount` | montage par un utilisateur des seuls volumes marqués `user` dans `/etc/fstab` |
| `/usr/bin/fusermount3` | montage de systèmes de fichiers FUSE par un utilisateur |
| `/usr/bin/ntfs-3g` | montage de disques NTFS (Windows) : inutile sur ce serveur |
| `/usr/lib/openssh/ssh-keysign` | authentification « host-based » d'OpenSSH (désactivée ici) : lit la clé privée de la machine |
| `/usr/lib/xorg/Xorg.wrap` | démarrage du serveur graphique : inutile, la VM n'a pas d'interface graphique |
| `/usr/sbin/pppd` | connexions PPP (modem) : inutile |

Les cinq derniers (`ntfs-3g`, `fusermount3`, `ssh-keysign`, `Xorg.wrap`, `pppd`)
viennent d'une installation plus large que nécessaire. Piste d'amélioration :
désinstaller les paquets correspondants, ou retirer le bit SUID de façon durable
avec `dpkg-statoverride` (un simple `chmod u-s` serait annulé à la prochaine mise à
jour du paquet). `verifier.sh` signale tout nouveau fichier SUID : un `chmod u+s`
ajouté par un attaquant (ou par le jury) est détecté.

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

Attention : le disque contient aussi `lost+found` (créé par ext4 pour `fsck`). Un
`ls /sauvegardes | tail -n 1` le choisit à la place de la dernière version, car
`l` est trié après les chiffres. On sélectionne donc explicitement une version
datée :

```bash
DERNIERE=$(sudo find /sauvegardes -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -n 1)
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

Un administrateur n'a pas accès aux répertoires métier (les ACL ne le prévoient
pas) : les vérifications se font avec `sudo`.

```bash
sudo ls -l /srv/publications/rapport.pdf
sudo getfacl /srv/publications/rapport.pdf   # les ACL doivent être revenues
sudo ./verifier.sh                           # test_B4 restaure aussi un fichier à blanc
```

### 4.5 Test réalisé

_À compléter avec le test fait sur la VM : fichier supprimé, version utilisée,
commandes, résultat (B4)._
