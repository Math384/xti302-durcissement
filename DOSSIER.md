# Dossier - Durcissement d'un serveur Debian 13 (XTI302-CYB)

Contexte C - Laboratoire BioLab. Groupe : Mathurin, Gabriel, Teo.

Résultat : sur la VM reconstruite depuis le snapshot vierge par `installer.sh`,
`verifier.sh` réussit **97 tests sur 97**.

Références ANSSI citées :
- **BP-028** : *Recommandations de configuration d'un système GNU/Linux*, v2.0
  (numéros R1 à R80) ;
- **SSH** : *Recommandations pour un usage sécurisé d'(Open)SSH*, note technique
  DAT-NT-007 (numéros R1 à R31).

## 1. Tableau de conformité

| ID | Ce qui a été fait | Test(s) de `verifier.sh` | ANSSI |
|---|---|---|---|
| **C1** | `creer_comptes.sh` lit `comptes.csv`, crée les groupes (`groupadd` si absent), crée ou met à jour chaque compte (`useradd` / `usermod`) : relançable sans doublon ni erreur | `test_C1` : chaque compte du CSV existe, avec ses groupes principal et secondaires (13 tests) | SSH R21 (un compte par personne) |
| **C2** | `/srv/donnees_brutes`, `analyses`, `publications` en `root:root 770`, ACL de groupe et **ACL par défaut** (`setfacl -m` et `-d -m`), remises à zéro à chaque passage | `test_C2` : pour chaque répertoire × groupe, un membre essaie de créer puis de lister (12 tests) ; ACL par défaut présentes ; héritage réel (fichier de `okenobi` lisible par `hsolo`) | BP-028 R50 |
| **C3** | `/etc/sudoers.d/xti302` (440, validé par `visudo -cf`) : `%admins` tous droits avec mot de passe ; `support` seulement `/usr/local/sbin/analyse_logs.sh` en root ; groupe `sudo` vidé | `test_C3` : fichier, syntaxe, identique au dépôt, chaque admin a `(ALL : ALL) ALL`, une seule règle pour `support`, script non modifiable, **aucun autre compte** n'a sudo | BP-028 R38, R33, R43 (voir partie 2) |
| **C4** | `passwd -l root` ; homes en 700, `HOME_MODE 0700` et `DIR_MODE=0700` pour les futurs comptes | `test_C4` : root `L`, tous les homes en `x00`, `HOME_MODE` | BP-028 R50 |
| **S1** | `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey` | `test_S1` : 3 options (`sshd -T`) + connexion réelle : le serveur ne propose que `publickey` | SSH R17 |
| **S2** | `PermitRootLogin no` | `test_S2` | SSH R21 |
| **S3** | `AllowGroups acces_ssh` ; clés publiques du dépôt installées ; `invite` : `nologin`, `ForceCommand internal-sftp`, `ChrootDirectory /srv` | `test_S3` : option, clé de chaque membre identique au dépôt, configuration effective d'un invité, `/srv` utilisable en chroot | SSH R22, R24 |
| **S4** | `MaxAuthTries 3`, `ChannelTimeout session=10m`, `ClientAliveInterval 60` × 3, `LoginGraceTime 30` | `test_S4` : MaxAuthTries ≤ 4, inactivité ≤ 15 min | BP-028 R32 (même principe pour les sessions locales) |
| **S5** | `/etc/ssh/sshd_config.d/00-xti302.conf` ; `sshd -t` avant `systemctl reload`, ancienne configuration remise en cas d'erreur | `test_S5` : fichier identique au dépôt, ligne `Include`, `sshd -t` | SSH R23, R27, R28 (options annexes) |
| **J1** | fail2ban, prison `sshd`, `backend = systemd`, bannissement par nftables, mode `aggressive` | `test_J1` : service actif, prison active, action nftables, fichier identique au dépôt | BP-028 R79 |
| **J2** | `/etc/nftables.conf` : `policy drop` en entrée, sauf connexions établies, `lo`, ICMPv6 de voisinage et TCP 22 ; service activé au démarrage ; pas de `flush ruleset` | `test_J2` : politique, règle SSH, règle « établies », chargé au démarrage, n'efface pas fail2ban | BP-028 R80 |
| **J3** | `/etc/systemd/journald.conf.d/xti302.conf` : `Storage=persistent` | `test_J3` : valeur effective, fichiers dans `/var/log/journal` | BP-028 R71 |
| **J4** | `analyse_logs.sh` : échecs par IP, comptes visés, connexions réussies, IP bannies ; options `-s` et `-H` ; codes 0, 1 (alerte), 2, 3 | `test_J4` : script installé identique, code 0 sous le seuil, **code 1** au-dessus, code 2 sur argument invalide | BP-028 R71 |
| **B1** | `sauvegarde.sh` : `rsync -aAXH --link-dest` de `/etc` et `/srv` vers `/sauvegardes/AAAA-MM-JJ_HHMMSS` sur le 2e disque, 14 versions gardées | `test_B1` : disque séparé, version complète, **même inode** d'un fichier inchangé dans 2 versions, ACL conservées, rotation | - |
| **B2** | `sauvegarde.timer` (2 h, `Persistent=true`) ; journalisation par `logger -t sauvegarde` | `test_B2` : timer actif, unités identiques au dépôt, exécution journalisée | BP-028 R71 |
| **B3** | `/sauvegardes` en `root:admins 750` | `test_B3` : droits, un chercheur refusé, un admin autorisé | BP-028 R50 |
| **B4** | Procédure (partie 4) et test réel de restauration | `test_B4` : restauration de `/etc/hostname` dans un dossier temporaire, comparée à l'original | - |
| **D1** | `unattended-upgrades`, `APT::Periodic` à 1, minuteurs `apt-daily*` | `test_D1` : paquet, configuration, minuteur | BP-028 R61 |
| **D2** | `ss -tulpn` : seuls `sshd` et le client DHCP ; avahi et ModemManager masqués | `test_D2` : sshd sur 22, aucune autre écoute réseau | BP-028 R62, R80 ; SSH R3 |
| **D3** | Aucun fichier modifiable par tous ; SUID listés et expliqués (partie 2) | `test_D3` : fichiers et répertoires modifiables par tous, SUID comparés à `config/suid_attendus.txt` | BP-028 R54, R56, R57 |

Les fichiers en service sont comparés à ceux du dépôt (`cmp`) : toute modification
manuelle de `sudoers`, `sshd_config.d`, `nftables.conf`, fail2ban ou des scripts est
détectée par `verifier.sh`. Contrairement aux autres scripts, il n'utilise pas
`set -e` ni `pipefail` : son rôle est de lancer des commandes qui échouent (un
doctorant qui essaie d'écrire) et de continuer ; `pipefail` ferait aussi échouer
`commande | grep -q` (grep s'arrête au premier résultat, la commande reçoit SIGPIPE).
Seul `-u` est gardé, et `LC_ALL=C` rend les sorties analysées indépendantes de la langue.

## 2. Choix techniques

### Comptes et sudo (C1 à C4)

- **Scripts idempotents** : chaque étape de `creer_comptes.sh` et `installer.sh`
  vérifie l'état avant d'agir. `installer.sh` a été relancé plusieurs fois sans
  dégât, et il a remis en conformité deux comptes créés à la main avant le snapshot
  (voir partie 5). Tous fixent leur `PATH` : `su -c` garde celui de l'utilisateur,
  sans `/usr/sbin`, et un script lancé en root ne doit pas dépendre du `PATH` de
  l'appelant (programme piégé).
- **sudoers validé par `visudo -cf` avant installation** : un fichier invalide
  casserait sudo pour tout le monde. **Garde-fou** : avant de vider le groupe `sudo`
  et de verrouiller root, `installer.sh` vérifie qu'au moins un admin a une clé SSH
  **et** un mot de passe, sinon il s'arrête (code 6).
- **Scripts appelés en root** dans `/usr/local/sbin`, `root:root 755` : si `support`
  pouvait modifier `analyse_logs.sh`, il y écrirait `bash` et deviendrait root par sudo.
- **Mot de passe provisoire des admins** : ils se connectent par clé, mais sudo
  demande leur mot de passe (traçabilité, protection d'une session laissée
  ouverte). `creer_comptes.sh` le fait saisir au clavier (jamais stocké), le
  transmet à `chpasswd` par un tube (invisible dans `ps`) et force son changement à
  la première connexion (`chage -d 0`). Un mot de passe existant n'est pas modifié.
- **`support` en `NOPASSWD`** : ce compte n'a pas de mot de passe (clé seule). Les
  arguments ne sont pas figés (BP-028 R43 le recommande) car le script accepte `-s`
  et `-H` ; en contrepartie le script n'accepte que des entiers et n'ouvre jamais de
  pager (`--no-pager`, `SYSTEMD_PAGER=""`) : un `less` lancé en root donnerait un
  shell root par `!sh` (GTFOBins).
- **Mode 770 + ACL sur `/srv`** : les « autres » n'ont aucun accès ; chaque groupe
  métier reçoit `rwx` (lecture/écriture) ou `r-x` (lecture : le `x` est nécessaire
  pour entrer dans un répertoire, il disparaît sur les fichiers créés en 0666). Les
  admins n'ont pas d'ACL : ils passent par sudo, ce qui est tracé.

### SSH (S1 à S5)

- **`MaxAuthTries 3`** (maximum imposé : 4) : fail2ban prend le relais.
- **`ChannelTimeout session=10m`** (maximum imposé : 15 min) : c'est lui qui ferme une
  session **inactive**. `ClientAliveInterval 60` × `ClientAliveCountMax 3` ne
  détecte qu'un client disparu (coupure réseau) : un client vivant répond aux
  sondes même si personne n'est devant l'écran.
- **Fichier `00-xti302.conf`** : `sshd_config` inclut `sshd_config.d/*.conf` en tête
  et la **première** valeur lue l'emporte ; le préfixe `00-` garantit la priorité.
  `Match all` termine les blocs `Match` pour ne pas capturer la suite de
  `sshd_config`. La configuration est validée par `sshd -t` avant le rechargement ;
  si elle est invalide, l'ancien fichier est remis et l'accès n'est pas coupé.
- **Redirection d'agent** refusée sauf pour `admins` (SSH R19, R20 : rebond vers
  GitHub pour `git pull`) ; X11, TCP et tunnels désactivés (SSH R27, R28) ;
  `PermitUserEnvironment no` (SSH R23).
- **Invités** : `ForceCommand internal-sftp -d /publications` et `ChrootDirectory
  /srv` (SSH R24). `/srv` doit appartenir à root et ne pas être modifiable par
  d'autres, sinon sshd refuse le chroot.
- **Port 22 conservé** : SSH R26 propose un autre port sur un réseau non maîtrisé ;
  ici le réseau est interne et fail2ban + clés suffisent.

### Journaux et défense (J1 à J4)

- **fail2ban : 5 échecs en 10 min, bannissement 10 min, doublé à chaque récidive
  jusqu'à 1 jour.** 10 min décourage un robot sans bloquer longtemps un utilisateur
  qui se trompe ; la récidive pénalise l'attaquant obstiné. `mode = aggressive` :
  le mot de passe étant désactivé, les seuls échecs possibles sont « clé refusée »,
  « compte non autorisé » ou une déconnexion avant authentification.
  `backend = systemd` : pas de `/var/log/auth.log` sur une Debian 13 minimale.
- **nftables sans `flush ruleset`** : le fichier ne remplace que la table
  `inet filtre` (`table … {}` puis `delete table …`), la table `inet f2b-table` de
  fail2ban survit au rechargement. ICMPv6 de voisinage autorisé : IPv6 ne
  fonctionne pas sans. Les refus sont journalisés, limités à 5 par minute. Les
  règles sont vérifiées par `nft -c` et la configuration fail2ban par
  `fail2ban-client -t` avant d'être appliquées.
- **Journal : 200 Mo et 3 mois maximum** : de quoi remonter un incident découvert
  tard, sans risquer de remplir le disque.
- **Seuil d'alerte de `analyse_logs.sh` : 10 échecs par IP sur 24 h.** fail2ban
  bannit déjà à 5 en 10 min ; 10 sur 24 h signifie que l'adresse a déjà été bannie,
  ou qu'elle attaque lentement pour rester sous le seuil de fail2ban : un humain
  doit regarder. Source : `journalctl -u ssh.service`, expressions vérifiées sur les
  lignes réelles d'OpenSSH 10.

### Sauvegarde (B1 à B3)

- **`--link-dest`** : chaque version paraît complète, mais un fichier inchangé est un
  lien physique vers celui de la version précédente.
- **14 versions quotidiennes à 2 h** (minimum imposé : 7) : deux semaines de retour
  arrière, pour un volume faible (`/etc` et `/srv`). `Persistent=true` rattrape une
  sauvegarde manquée si la VM était éteinte.
- **Sécurités** : le script refuse de tourner si `/sauvegardes` n'est pas monté (il
  remplirait le disque système) ; écriture dans un dossier `.en_cours` renommé en
  fin de copie (une version datée est toujours complète) ; verrou `flock`.
- **Disque jamais reformaté** : formaté seulement s'il ne porte aucun système de
  fichiers, réutilisé s'il porte l'étiquette `sauvegardes`, refusé sinon. Montage
  par UUID avec `nodev,nosuid,noexec,nofail` (BP-028 R28 pour les options).

### D1 - Mises à jour

`unattended-upgrades` installe chaque jour les mises à jour des origines définies
dans `50unattended-upgrades` (dépôt `debian-security`).

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
viennent d'une installation plus large que nécessaire (BP-028 R58). Piste
d'amélioration : désinstaller les paquets correspondants, ou retirer le bit SUID de
façon durable avec `dpkg-statoverride` (un simple `chmod u-s` serait annulé à la
prochaine mise à jour du paquet). `verifier.sh` signale tout nouveau fichier SUID :
un `chmod u+s` ajouté par un attaquant (ou par le jury) est détecté.

`find` ne parcourt que les vrais systèmes de fichiers (`findmnt -t ext4,…` et
`-xdev`) : pas de `/proc` ni de `/sys`. `-type f` ignore les liens symboliques,
toujours affichés en 777. Les `/tmp` privés des services
(`/var/tmp/systemd-private-*/tmp`) sont des répertoires temporaires, donc exclus.

## 3. Défense

| Attaque | Ce qui la rend plus difficile | Ce qui n'est pas couvert |
|---|---|---|
| **Force brute SSH** depuis Internet ou le réseau | Mot de passe refusé (S1) : il n'y a rien à deviner. `AllowGroups` (S3) et `PermitRootLogin no` (S2) réduisent les comptes visés. 3 essais par connexion (S4), puis fail2ban bannit l'adresse (J1) ; `analyse_logs.sh` alerte sur les attaques lentes (J4). Démontré : 6 tentatives `pirate` ont banni l'IP Tailscale du PC hôte. | Un réseau de machines (botnet) change d'adresse à chaque essai. SSH écoute sur toutes les interfaces (SSH R25 recommande une interface d'administration). |
| **Vol du mot de passe d'un admin** (hameçonnage, mot de passe réutilisé) | Le mot de passe seul ne permet pas de se connecter : il faut aussi la clé privée (S1). Il ne sert qu'à sudo, une fois connecté. | Le vol du PC de l'admin (clé privée + mot de passe) donne tout. Pas de double authentification (TOTP). Les clés de test sont sans phrase de passe. |
| **Utilisateur métier curieux** (un doctorant veut lire les données brutes des autres, un technicien les analyses) | ACL par groupe et ACL par défaut (C2), homes en 700 (C4), sauvegardes réservées aux admins (B3), pas d'accès SSH (S3). Chaque droit et chaque refus est testé par `verifier.sh`. | Un membre du bon groupe peut tout lire ou modifier dans son répertoire, y compris les fichiers de ses collègues (pas de sticky bit, pas de chiffrement). |
| **Compte invité compromis** | Pas de shell (`nologin`), SFTP seul (`ForceCommand`), enfermé dans `/srv` (`ChrootDirectory`), lecture seule de `/publications` (ACL) : il ne peut ni exécuter de commande, ni écrire, ni voir le reste du système. | Il peut télécharger toutes les publications ; aucune limite de volume ou d'horaire. |
| **Compte `support` compromis** | sudo limité à un seul script, par chemin absolu, en root ; script non modifiable par `support` ; arguments numériques seulement, aucun pager. | `support` lit le rapport, donc les noms de comptes et les adresses IP. |
| **Rançongiciel ou suppression accidentelle** | Sauvegarde quotidienne **versionnée** sur 14 jours (B1) : on revient à la version d'avant l'incident, alors qu'un miroir aurait copié les fichiers chiffrés. Disque monté `noexec`, accessible aux seuls admins (B3). | Le disque est dans la **même machine** : un attaquant root le chiffre aussi. Il manque une copie hors site, hors ligne (règle 3-2-1). |

**Limites générales**, pistes pour aller plus loin : pas de partitionnement séparé de
`/tmp`, `/var`, `/home` (BP-028 R28) ; pas d'`umask` 0077 (R36) ni des directives
sudo de R39 (`use_pty`, `noexec`…) ; pas de journalisation `auditd` (R73) ni de
renvoi des journaux vers une autre machine ; pas de contrôle d'intégrité des
fichiers (R76) ; pas de profil AppArmor dédié (R45).

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

### 4.5 Test réalisé (6 novembre 2026)

1. Création d'un fichier par un chercheur :
   `sudo -u okenobi sh -c 'echo "resultats" > /srv/publications/test_restauration.txt'`
2. Sauvegarde : `sudo systemctl start sauvegarde.service`
3. Suppression : `sudo rm /srv/publications/test_restauration.txt`
4. Restauration depuis la dernière version datée (commande de 4.1 puis 4.2).
5. Contrôle : propriétaire `okenobi`, ACL `group:chercheurs:rw-`,
   `group:doctorants:r--` et `group:invite:r--` revenues, comme avant la suppression.

Deux erreurs rencontrées, qui ont amélioré la procédure : `ls | tail -n 1` a
désigné `lost+found` au lieu de la dernière version (d'où la sélection par
`find -name '20*'`), et `ls -l` sans `sudo` est refusé à un admin, ce qui confirme
que les ACL de C2 ne lui donnent aucun accès aux données métier.

## 5. Environnement et répartition du travail

- **Snapshot « vierge »** : il contient déjà les comptes `gabriel` et `teo`, créés à
  la main le premier jour, et l'installation de Debian n'était pas strictement
  minimale (avahi, ModemManager, Xorg, ppp). `installer.sh` a remis ces comptes en
  conformité sans les recréer et neutralise les services inutiles.
- **Accès à la VM** : réseau host-only (`192.168.64.0/24`) depuis le PC hôte ;
  redirection du port 2222 de l'adresse Tailscale du PC vers le port 22 de la VM
  pour les autres membres. Tailscale n'est installé que sur le PC hôte (la VM ne
  contient que des paquets Debian officiels). Les connexions par ce chemin
  apparaissent dans la VM avec l'adresse Tailscale du PC.
### Répartition du travail

Le travail a été réparti à parts égales entre les trois membres. Il a été réalisé
ensemble, à trois devant le poste de Mathurin, qui héberge la VM : c'est pourquoi la
plupart des commits sont au nom de Mathurin. Les derniers portent la mention
`Co-authored-by`, et chacun a poussé lui-même sa clé publique.

Chaque membre a pris en charge un tiers des exigences, qu'il présente et défend à
la soutenance ; tous ont participé à l'ensemble et peuvent l'expliquer.

| Membre | Exigences | Scripts et fichiers |
|---|---|---|
| **Mathurin** | C1 à C4, J1, J2 | `creer_comptes.sh`, `installer.sh`, `config/sudoers.d`, `config/nftables.conf`, `config/fail2ban` |
| **Gabriel** | S1 à S5, D2, D3 | `config/ssh/sshd_config.d`, `config/suid_attendus.txt`, structure de `verifier.sh` |
| **Teo** | J3, J4, B1 à B4, D1 | `analyse_logs.sh`, `sauvegarde.sh`, `config/systemd`, `config/journald.conf`, `config/apt` |
