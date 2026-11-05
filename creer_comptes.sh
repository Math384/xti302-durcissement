#!/usr/bin/env bash
#
# creer_comptes.sh - Comptes, groupes, clés SSH et répertoires /srv (contexte C : BioLab)
#
# Exigences couvertes :
#   C1 : comptes et groupes créés à partir de comptes.csv ; relançable sans doublon ni erreur
#   C2 : répertoires de /srv avec permissions, ACL et ACL par défaut
#   C4 : répertoires personnels non lisibles par les autres (chmod 700)
#
# Usage : sudo ./creer_comptes.sh [chemin/vers/comptes.csv]
#
# Codes de sortie :
#   0 succès | 1 erreur générale | 2 pas root | 3 CSV invalide | 4 dépendance manquante

set -euo pipefail

# PATH fixé : ne pas dépendre de celui de l'appelant (su -c garde le PATH utilisateur,
# sans /usr/sbin où sont useradd, groupadd...), ni exécuter un programme piégé en root
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- Paramètres --------------------------------------------------------------

# Dossier du dépôt = dossier qui contient ce script (fonctionne quel que soit le répertoire courant)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV="${1:-$REPO_DIR/comptes.csv}"
CLES_DIR="$REPO_DIR/config/cles"
ENTETE="login;nom;groupe_principal;groupes_secondaires"

GROUPE_ADMINS="admins"
GROUPE_SSH="acces_ssh"
GROUPE_SFTP="invite"                                   # pas de shell : SFTP uniquement
GROUPES_METIER=(technique chercheurs doctorants invite)

# Droits sur /srv (tableau du contexte C) : rwx = lecture/écriture, r-x = lecture.
# Sur un répertoire, x est nécessaire pour y entrer ; pour les fichiers créés
# plus tard, le x des ACL par défaut est neutralisé par le mode de création (0666).
declare -A ACL_SRV=(
    [/srv/donnees_brutes]="g:technique:rwx,g:chercheurs:r-x,g:doctorants:r-x"
    [/srv/analyses]="g:chercheurs:rwx,g:doctorants:rwx"
    [/srv/publications]="g:chercheurs:rwx,g:doctorants:r-x,g:invite:r-x"
)

# --- Fonctions utilitaires ---------------------------------------------------

info()   { echo "[INFO] $*"; }
alerte() { echo "[ATTENTION] $*" >&2; }
erreur() { echo "[ERREUR] $1" >&2; exit "${2:-1}"; }

# Vérifie les droits, le fichier CSV et les outils nécessaires
verifier_prerequis() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit être lancé en root (sudo $0)" 2
    [[ -r "$CSV" ]] || erreur "fichier introuvable ou illisible : $CSV" 3
    [[ "$(head -n 1 "$CSV" | tr -d '\r')" == "$ENTETE" ]] \
        || erreur "en-tête de $CSV invalide (attendu : $ENTETE)" 3
    command -v setfacl >/dev/null || erreur "setfacl introuvable : apt install acl" 4
}

# Affiche les lignes utiles du CSV : sans en-tête, sans \r (Windows), sans lignes vides
lignes_csv() {
    tail -n +2 "$CSV" | tr -d '\r' | grep -v '^[[:space:]]*$' || true
}

# --- Groupes -----------------------------------------------------------------

# Crée le groupe s'il n'existe pas encore (idempotent)
creer_groupe() {
    local groupe="$1"
    if ! getent group "$groupe" >/dev/null; then
        groupadd "$groupe"
        info "groupe créé : $groupe"
    fi
}

# Crée tous les groupes cités dans le CSV, plus les groupes métier utilisés par les ACL
creer_groupes() {
    local login nom gp gs g liste
    for g in "${GROUPES_METIER[@]}"; do
        creer_groupe "$g"
    done
    while IFS=';' read -r login nom gp gs <&3; do
        creer_groupe "$gp"
        IFS=',' read -ra liste <<< "$gs"
        for g in "${liste[@]}"; do
            creer_groupe "$g"
        done
    done 3< <(lignes_csv)
}

# --- Utilisateurs ------------------------------------------------------------

# Crée le compte, ou le met à jour pour qu'il corresponde exactement au CSV
creer_utilisateur() {
    local login="$1" nom="$2" gp="$3" gs="$4"
    local shell="/bin/bash"
    if [[ "$gp" == "$GROUPE_SFTP" ]]; then
        shell="/usr/sbin/nologin"
    fi

    if id "$login" &>/dev/null; then
        # -G remplace la liste des groupes secondaires : les ajouts manuels sont retirés
        usermod -c "$nom" -g "$gp" -G "$gs" -s "$shell" "$login"
        info "compte mis à jour : $login"
    else
        local options=(-m -c "$nom" -g "$gp" -s "$shell")
        if [[ -n "$gs" ]]; then
            options+=(-G "$gs")
        fi
        useradd "${options[@]}" "$login"
        info "compte créé : $login"
    fi

    # C4 : répertoire personnel accessible à son seul propriétaire
    chmod 700 "$(getent passwd "$login" | cut -d: -f6)"
}

# Installe config/cles/<login>.pub comme unique clé autorisée du compte
installer_cle() {
    local login="$1" gp="$2"
    local cle="$CLES_DIR/$login.pub" home
    home="$(getent passwd "$login" | cut -d: -f6)"

    if [[ ! -f "$cle" ]]; then
        alerte "pas de clé publique pour $login ($cle) : connexion SSH impossible"
        return 0
    fi
    install -d -m 700 -o "$login" -g "$gp" "$home/.ssh"
    install -m 600 -o "$login" -g "$gp" "$cle" "$home/.ssh/authorized_keys"
    info "clé SSH installée : $login"
}

# Les admins se connectent par clé, mais sudo leur demande leur mot de passe.
# Sans mot de passe, pas de sudo : on en saisit un provisoire (jamais stocké),
# à changer obligatoirement à la première connexion. Un mot de passe existant n'est pas modifié.
definir_mdp_admin() {
    local login="$1" etat mdp mdp2
    etat="$(passwd -S "$login" | awk '{print $2}')"
    if [[ "$etat" == "P" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        alerte "$login n'a pas de mot de passe (sudo impossible) : lancez 'passwd $login'"
        return 0
    fi
    while true; do
        read -rsp "Mot de passe provisoire pour $login : " mdp; echo
        read -rsp "Confirmation : " mdp2; echo
        if [[ -n "$mdp" && "$mdp" == "$mdp2" ]]; then
            break
        fi
        alerte "mots de passe vides ou différents, recommencez"
    done
    echo "$login:$mdp" | chpasswd      # par un tube : le mot de passe n'apparaît pas dans ps
    chage -d 0 "$login"                # changement obligatoire à la première connexion
    info "mot de passe provisoire défini : $login"
}

# Parcourt le CSV et applique chaque ligne
creer_utilisateurs() {
    local login nom gp gs
    while IFS=';' read -r login nom gp gs <&3; do
        if [[ ! "$login" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            alerte "login invalide, ligne ignorée : '$login'"
            continue
        fi
        creer_utilisateur "$login" "$nom" "$gp" "$gs"
        if [[ ",$gs," == *",$GROUPE_SSH,"* ]]; then
            installer_cle "$login" "$gp"
        fi
        if [[ "$gp" == "$GROUPE_ADMINS" ]]; then
            definir_mdp_admin "$login"
        fi
    done 3< <(lignes_csv)
}

# --- Répertoires /srv --------------------------------------------------------

# Crée les répertoires et applique les ACL (et ACL par défaut) du tableau ACL_SRV
creer_repertoires_srv() {
    local rep
    # /srv doit appartenir à root et ne pas être modifiable par d'autres (racine du chroot SFTP)
    install -d -m 755 -o root -g root /srv
    for rep in "${!ACL_SRV[@]}"; do
        install -d -m 770 -o root -g root "$rep"
        setfacl -b -k "$rep"                                            # repart de zéro
        setfacl -m "u::rwx,g::---,o::---,${ACL_SRV[$rep]}" "$rep"       # droits du répertoire
        setfacl -d -m "u::rwx,g::---,o::---,${ACL_SRV[$rep]}" "$rep"    # hérités par les futurs fichiers
        info "répertoire et ACL appliqués : $rep"
    done
}

# --- Programme principal -----------------------------------------------------

main() {
    verifier_prerequis
    creer_groupes
    creer_utilisateurs
    creer_repertoires_srv
    info "terminé"
}

main "$@"
