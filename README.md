# xti302-durcissement

Projet XTI302-CYB - Administration systèmes avancée et scripting : durcir un
serveur Debian 13 et le prouver.

**Contexte choisi : C - Laboratoire BioLab.** Groupe : Mathurin, Gabriel, Teo.

| Groupe | Répertoires de `/srv` |
|---|---|
| `technique` | `donnees_brutes` (lecture/écriture) |
| `chercheurs` | `donnees_brutes` (lecture), `analyses` et `publications` (lecture/écriture) |
| `doctorants` | `donnees_brutes` et `publications` (lecture), `analyses` (lecture/écriture) |
| `invite` | `publications` (lecture), **en SFTP uniquement**, sans shell |

Comptes : `admins` (mathurin, gabriel, teo), `support` (sudo limité à
`analyse_logs.sh`), utilisateurs métier définis dans [`comptes.csv`](comptes.csv).

## Prérequis

- Une VM **Debian 13** installée en minimal, sans interface graphique, avec le
  serveur SSH, et un compte utilisateur créé à l'installation.
- Un **second disque virtuel** de 1 à 2 Go, vide (`/dev/sdb` par défaut), pour les
  sauvegardes.
- Un accès Internet depuis la VM (dépôts Debian officiels uniquement).
- Les clés **publiques** des comptes autorisés en SSH dans `config/cles/<login>.pub`.

## Installer

Les scripts sont lancés en root : ils doivent appartenir à root et n'être
modifiables que par lui. Le dépôt est donc cloné **par root** dans `/opt/xti302`
(un clone dans un répertoire personnel est refusé par `installer.sh`).

Sur la VM, connecté en SSH avec redirection d'agent (`ssh -A`) depuis le compte créé
à l'installation, pour que root puisse utiliser la clé GitHub du poste :

```bash
su -c "apt install -y git"
su -c "git clone git@github.com:Math384/xti302-durcissement.git /opt/xti302"
su -c "/opt/xti302/installer.sh"
```

Mettre à jour plus tard, depuis un compte administrateur (`ssh -A`) :

```bash
sudo --preserve-env=SSH_AUTH_SOCK git -C /opt/xti302 pull
sudo /opt/xti302/installer.sh
```

`installer.sh` reconstruit toute la configuration ; il peut être relancé sans
danger (le disque de sauvegarde n'est jamais reformaté). Il demande un **mot de
passe provisoire** pour chaque administrateur : sudo en a besoin, et il devra être
changé à la première connexion.

> ⚠️ À la fin, root est verrouillé, le compte d'installation perd sudo et l'accès
> SSH, et seule l'authentification par clé est acceptée. Garder la session ouverte
> et tester la connexion d'un administrateur dans un second terminal :
> `ssh mathurin@<IP de la VM>`.

Disque de sauvegarde sous un autre nom : `sudo DISQUE_SAUVEGARDE=/dev/sdc /opt/xti302/installer.sh`.

## Vérifier

```bash
sudo /opt/xti302/verifier.sh
```

Un résultat `[OK]` / `[KO]` par test, puis le bilan ; code de sortie 0 si tout est
conforme, 1 sinon. Le script ne modifie rien (les fichiers de test sont supprimés).

## Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `installer.sh` | reconstruit la configuration sur une VM vierge |
| `creer_comptes.sh` | comptes, groupes, clés SSH, répertoires `/srv` et ACL, depuis `comptes.csv` |
| `comptes.csv` | liste des comptes (`login;nom;groupe_principal;groupes_secondaires`) |
| `verifier.sh` | teste chaque exigence du cahier des charges |
| `analyse_logs.sh` | rapport des connexions SSH ; code 1 si le seuil d'alerte est dépassé |
| `sauvegarde.sh` | sauvegarde incrémentale et datée de `/srv` et `/etc` |
| `config/` | configurations copiées par `installer.sh` (SSH, sudoers, nftables, fail2ban, journald, apt, systemd) et clés publiques |
| `DOSSIER.md` | conformité, choix techniques, défense, restauration |

## Commandes utiles

```bash
sudo /usr/local/sbin/analyse_logs.sh -s 5 -H 24     # rapport SSH (seuil 5, dernières 24 h)
sudo fail2ban-client status sshd                    # adresses bannies
sudo fail2ban-client set sshd unbanip <IP>          # débannir
sudo systemctl start sauvegarde.service             # sauvegarde immédiate
journalctl -t sauvegarde                            # historique des sauvegardes
systemctl list-timers sauvegarde.timer              # prochaine sauvegarde
```
