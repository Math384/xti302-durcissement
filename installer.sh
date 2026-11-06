#!/usr/bin/env bash
#
# installer.sh - Reconstruit toute la configuration sur une VM Debian 13 vierge
#
# Relançable sans danger : chaque étape vérifie l'état avant d'agir.
# Étapes déjà en place : paquets, scripts, comptes (C1, C2), sudo (C3), root et homes (C4),
#                        SSH (S1-S5), journald, nftables, fail2ban (J1-J3), mises à jour (D1),
#                        disque et planification de la sauvegarde (B1-B3), services inutiles (D2).
#
# Usage : sudo ./installer.sh   (ou en root : ./installer.sh)
#
# Codes de sortie :
#   0 succès | 1 erreur générale | 2 pas root | 5 configuration invalide | 6 garde-fou anti-blocage
#   7 disque de sauvegarde introuvable ou refusé

set -euo pipefail

# PATH fixé : ne pas dépendre de celui de l'appelant (su -c garde le PATH utilisateur,
# sans /usr/sbin où sont useradd, visudo...), ni exécuter un programme piégé en root
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Paramètres --------------------------------------------------------------

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$REPO_DIR/config"
SCRIPTS_DIR="/usr/local/sbin"            # scripts appelés par root ou via sudo
GROUPE_ADMINS="admins"

# python3-systemd : permet à fail2ban de lire journald (backend = systemd)
PAQUETS=(sudo acl openssh-server nftables fail2ban python3-systemd unattended-upgrades rsync)

# Second disque de la VM, réservé aux sauvegardes. Autre nom possible :
#   sudo DISQUE_SAUVEGARDE=/dev/sdc ./installer.sh
DISQUE_SAUVEGARDE="${DISQUE_SAUVEGARDE:-/dev/sdb}"

# D2 : services réseau inutiles sur un serveur, installés quand l'installation de
# Debian n'était pas strictement minimale. avahi-daemon (mDNS, ports 5353...) écoute
# sur le réseau ; ModemManager pilote des modems 3G/4G absents ici.
SERVICES_INUTILES=(avahi-daemon.socket avahi-daemon.service ModemManager.service)
ETIQUETTE_SAUVEGARDE="sauvegardes"
POINT_MONTAGE="/sauvegardes"

# --- Fonctions utilitaires ---------------------------------------------------

info()   { echo "[INFO] $*"; }
etape()  { echo; echo "=== $* ==="; }
erreur() { echo "[ERREUR] $1" >&2; exit "${2:-1}"; }

verifier_root() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit être lancé en root (sudo $0)" 2
}

# Liste des comptes du groupe admins : membres secondaires ET comptes dont c'est
# le groupe principal (ces derniers n'apparaissent pas dans la 4e colonne de getent group)
membres_admins() {
    local gid
    gid="$(getent group "$GROUPE_ADMINS" | cut -d: -f3)"
    {
        getent group "$GROUPE_ADMINS" | cut -d: -f4 | tr ',' '\n'
        getent passwd | awk -F: -v g="$gid" '$4 == g { print $1 }'
    } | grep -v '^$' | sort -u
}

# --- Étapes ------------------------------------------------------------------

installer_paquets() {
    etape "Paquets"
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${PAQUETS[@]}"
}

# Les scripts exécutés en root appartiennent à root et ne sont modifiables que par lui.
# Pour analyse_logs.sh c'est vital : support peut le lancer en root via sudo ;
# s'il pouvait le modifier, il lui suffirait d'y écrire "bash" pour devenir root.
installer_scripts() {
    etape "Scripts dans $SCRIPTS_DIR"
    local script
    for script in analyse_logs.sh sauvegarde.sh; do
        install -m 755 -o root -g root "$REPO_DIR/$script" "$SCRIPTS_DIR/$script"
        info "$script installé (root:root, 755)"
    done
}

# C1, C2 : comptes, groupes, clés, /srv
creer_comptes() {
    etape "Comptes et répertoires (C1, C2)"
    bash "$REPO_DIR/creer_comptes.sh" "$REPO_DIR/comptes.csv"
}

# C3 : droits sudo. Le fichier est validé AVANT d'être mis en place :
# un sudoers invalide casserait sudo pour tout le monde.
configurer_sudo() {
    etape "sudo (C3)"
    local source="$CONFIG/sudoers.d/xti302"
    visudo -cf "$source" >/dev/null || erreur "syntaxe invalide dans $source" 5
    install -m 440 -o root -g root "$source" /etc/sudoers.d/xti302
    info "/etc/sudoers.d/xti302 installé (root:root, 440)"
}

# Garde-fou : avant de retirer les anciens accès root, on vérifie qu'au moins
# un administrateur pourra encore se connecter (clé SSH) ET utiliser sudo (mot de passe).
verifier_admin_utilisable() {
    local login home
    for login in $(membres_admins); do
        home="$(getent passwd "$login" | cut -d: -f6)"
        if [[ "$(passwd -S "$login" | awk '{print $2}')" == "P" && -s "$home/.ssh/authorized_keys" ]]; then
            info "administrateur utilisable : $login"
            return 0
        fi
    done
    erreur "aucun membre de $GROUPE_ADMINS n'a à la fois une clé SSH et un mot de passe : arrêt pour ne pas bloquer l'accès" 6
}

# C3 : aucun autre compte n'a sudo. L'installation de Debian a pu mettre le
# premier utilisateur dans le groupe "sudo" : on vide ce groupe.
vider_groupe_sudo() {
    local membre
    for membre in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
        gpasswd -d "$membre" sudo >/dev/null
        info "$membre retiré du groupe sudo"
    done
}

# C4 : répertoires personnels privés, existants et futurs
proteger_homes() {
    etape "Répertoires personnels (C4)"
    local d
    for d in /home/*/; do
        chmod 700 "$d"
    done
    # Mode des homes créés plus tard par useradd (login.defs) et adduser (adduser.conf)
    if grep -q '^HOME_MODE' /etc/login.defs; then
        sed -i 's/^HOME_MODE.*/HOME_MODE\t0700/' /etc/login.defs
    else
        printf 'HOME_MODE\t0700\n' >> /etc/login.defs
    fi
    if [[ -f /etc/adduser.conf ]]; then
        sed -i 's/^#\?DIR_MODE=.*/DIR_MODE=0700/' /etc/adduser.conf
    fi
    info "homes en 700, HOME_MODE et DIR_MODE à 0700"
}

# S1 à S5 : configuration SSH. Le fichier est mis en place puis toute la
# configuration est validée par sshd -t AVANT de recharger le service ; si elle
# est invalide, l'ancien fichier est remis et sshd n'est pas rechargé : la
# configuration en service reste celle d'avant, et l'accès n'est pas coupé.
configurer_ssh() {
    etape "SSH (S1 à S5)"
    local source="$CONFIG/ssh/sshd_config.d/00-xti302.conf"
    local dest="/etc/ssh/sshd_config.d/00-xti302.conf"
    local ancien=""

    if [[ -f "$dest" ]]; then
        ancien="$(mktemp)"
        cp -p "$dest" "$ancien"
    fi
    install -m 644 -o root -g root "$source" "$dest"

    if ! sshd -t; then
        if [[ -n "$ancien" ]]; then
            mv "$ancien" "$dest"
        else
            rm -f "$dest"
        fi
        erreur "configuration SSH invalide (sshd -t) : ancienne configuration conservée" 5
    fi
    rm -f "$ancien"
    systemctl reload ssh
    info "$dest installé, validé par sshd -t, service ssh rechargé"
}

# J3 : journal persistant (un fichier de complément plutôt que modifier journald.conf)
configurer_journald() {
    etape "Journal persistant (J3)"
    install -D -m 644 -o root -g root "$CONFIG/journald.conf" /etc/systemd/journald.conf.d/xti302.conf
    systemctl restart systemd-journald
    journalctl --flush          # recopie sur disque ce qui était encore en mémoire
    info "journal conservé dans /var/log/journal"
}

# J2 : pare-feu. Les règles sont vérifiées (nft -c) avant d'être installées, puis
# chargées tout de suite ; nftables.service les recharge à chaque démarrage.
configurer_pare_feu() {
    etape "Pare-feu nftables (J2)"
    nft -c -f "$CONFIG/nftables.conf" || erreur "règles nftables invalides" 5
    install -m 755 -o root -g root "$CONFIG/nftables.conf" /etc/nftables.conf
    systemctl enable nftables >/dev/null 2>&1
    nft -f /etc/nftables.conf   # ne remplace que la table inet filtre, pas celle de fail2ban
    info "règles chargées, nftables activé au démarrage"
}

# J1 : fail2ban. La configuration complète est testée (fail2ban-client -t) ;
# si elle est invalide, notre fichier est retiré.
configurer_fail2ban() {
    etape "fail2ban (J1)"
    local dest="/etc/fail2ban/jail.d/xti302.conf"
    install -m 644 -o root -g root "$CONFIG/fail2ban/jail.d/xti302.conf" "$dest"
    if ! fail2ban-client -t >/dev/null; then
        rm -f "$dest"
        erreur "configuration fail2ban invalide (fail2ban-client -t)" 5
    fi
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    info "prison sshd active"
}

# D1 : mises à jour de sécurité automatiques
configurer_maj_auto() {
    etape "Mises à jour automatiques (D1)"
    install -m 644 -o root -g root "$CONFIG/apt/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
    info "unattended-upgrades activé (vérification quotidienne)"
}

# D2 : arrête et masque les services inutiles. "mask" plutôt que "disable" : un
# service désactivé peut encore être démarré par un autre (activation D-Bus ou
# socket, c'est le cas d'avahi) ; un service masqué ne peut plus démarrer du tout.
# On ne désinstalle pas : supprimer un paquet peut entraîner la suppression d'autres.
desactiver_services_inutiles() {
    etape "Services inutiles (D2)"
    local service
    for service in "${SERVICES_INUTILES[@]}"; do
        if systemctl list-unit-files --no-legend "$service" 2>/dev/null | grep -q .; then
            systemctl disable --now "$service" >/dev/null 2>&1 || true
            systemctl mask "$service" >/dev/null 2>&1
            info "$service arrêté et masqué"
        fi
    done
}

# B1, B3 : second disque monté sur /sauvegardes, accessible aux seuls admins.
# Relançable sans danger : le disque n'est formaté QUE s'il ne contient aucun
# système de fichiers. Un disque qui contient déjà nos sauvegardes (étiquette
# "sauvegardes") est réutilisé tel quel ; tout autre contenu arrête le script.
preparer_disque() {
    etape "Disque de sauvegarde (B1, B3)"
    local disque="$DISQUE_SAUVEGARDE" uuid

    [[ -b "$disque" ]] || erreur "disque $disque introuvable (lsblk pour le trouver)" 7
    # Garde-fous : jamais le disque système, jamais un disque partitionné
    if lsblk -n -o MOUNTPOINT "$disque" | grep -qx '/'; then
        erreur "$disque porte le système : refus de l'utiliser" 7
    fi
    if lsblk -n -o TYPE "$disque" | grep -qx part; then
        erreur "$disque contient des partitions : il n'est pas touché" 7
    fi

    if ! blkid "$disque" >/dev/null 2>&1; then
        mkfs.ext4 -q -L "$ETIQUETTE_SAUVEGARDE" "$disque"
        info "$disque vierge : formaté en ext4 (étiquette $ETIQUETTE_SAUVEGARDE)"
    elif [[ "$(blkid -o value -s LABEL "$disque")" != "$ETIQUETTE_SAUVEGARDE" ]]; then
        erreur "$disque contient déjà un autre système de fichiers : il n'est pas touché" 7
    else
        info "$disque déjà préparé : réutilisé sans formatage (sauvegardes conservées)"
    fi

    # Montage permanent par UUID (le nom sdb peut changer d'un démarrage à l'autre).
    # nodev,nosuid,noexec : rien ne peut être exécuté depuis les sauvegardes ;
    # nofail : la machine démarre même si le disque est absent.
    uuid="$(blkid -o value -s UUID "$disque")"
    install -d -m 750 -o root -g root "$POINT_MONTAGE"
    if ! grep -q "^UUID=$uuid " /etc/fstab; then
        echo "UUID=$uuid $POINT_MONTAGE ext4 defaults,nodev,nosuid,noexec,nofail 0 2" >> /etc/fstab
        info "ligne ajoutée à /etc/fstab"
    fi
    systemctl daemon-reload
    if ! mountpoint -q "$POINT_MONTAGE"; then
        mount "$POINT_MONTAGE"
    fi

    # B3 : appliqué APRÈS le montage, sur la racine du disque elle-même
    chown root:"$GROUPE_ADMINS" "$POINT_MONTAGE"
    chmod 750 "$POINT_MONTAGE"
    info "$POINT_MONTAGE monté, root:$GROUPE_ADMINS 750"
}

# B2 : sauvegarde quotidienne par un timer systemd, et une première sauvegarde tout de suite
configurer_sauvegarde() {
    etape "Planification de la sauvegarde (B2)"
    install -m 644 -o root -g root "$CONFIG/systemd/sauvegarde.service" /etc/systemd/system/sauvegarde.service
    install -m 644 -o root -g root "$CONFIG/systemd/sauvegarde.timer" /etc/systemd/system/sauvegarde.timer
    systemctl daemon-reload
    systemctl enable --now sauvegarde.timer >/dev/null 2>&1
    systemctl start sauvegarde.service
    info "timer actif, première sauvegarde faite (journalctl -t sauvegarde)"
}

# C4 : le compte root est verrouillé (plus de connexion par mot de passe, ni su)
verrouiller_root() {
    etape "Compte root (C4)"
    passwd -l root >/dev/null
    info "root verrouillé"
}

# --- Programme principal -----------------------------------------------------

main() {
    verifier_root
    installer_paquets
    installer_scripts
    creer_comptes
    configurer_sudo
    verifier_admin_utilisable
    vider_groupe_sudo
    configurer_ssh
    configurer_journald
    configurer_pare_feu
    configurer_fail2ban
    configurer_maj_auto
    desactiver_services_inutiles
    preparer_disque
    configurer_sauvegarde
    proteger_homes
    verrouiller_root
    etape "Terminé"
}

main "$@"
