#!/usr/bin/env bash
#
# installer.sh - Reconstruit toute la configuration sur une VM Debian 13 vierge
#
# Relançable sans danger : chaque étape vérifie l'état avant d'agir.
# Étapes déjà en place : paquets, scripts, comptes (C1, C2), sudo (C3), root et homes (C4),
#                        SSH (S1-S5).
# À venir : fail2ban / nftables / journald (J1-J4), mises à jour (D1), sauvegarde (B1-B3).
#
# Usage : sudo ./installer.sh   (ou en root : ./installer.sh)
#
# Codes de sortie :
#   0 succès | 1 erreur générale | 2 pas root | 5 configuration invalide | 6 garde-fou anti-blocage

set -euo pipefail

# PATH fixé : ne pas dépendre de celui de l'appelant (su -c garde le PATH utilisateur,
# sans /usr/sbin où sont useradd, visudo...), ni exécuter un programme piégé en root
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Paramètres --------------------------------------------------------------

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$REPO_DIR/config"
SCRIPTS_DIR="/usr/local/sbin"            # scripts appelés par root ou via sudo
GROUPE_ADMINS="admins"

PAQUETS=(sudo acl openssh-server)

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
    install -m 755 -o root -g root "$REPO_DIR/analyse_logs.sh" "$SCRIPTS_DIR/analyse_logs.sh"
    info "analyse_logs.sh installé (root:root, 755)"
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
    proteger_homes
    verrouiller_root
    etape "Terminé"
}

main "$@"
