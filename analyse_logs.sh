#!/usr/bin/env bash
#
# analyse_logs.sh - Rapport des connexions SSH (exigence J4)
#
# Source : le journal systemd du service ssh. Sur une Debian 13 minimale, rsyslog
# n'est pas installé : /var/log/auth.log n'existe pas, tout est dans journald.
#
# Le rapport donne :
#   - les échecs d'authentification par adresse IP,
#   - les comptes visés,
#   - les connexions réussies,
#   - les adresses actuellement bannies par fail2ban.
#
# Usage : sudo analyse_logs.sh [-s SEUIL] [-H HEURES] [-h]
#   -s SEUIL   alerte si une même adresse IP cumule au moins SEUIL échecs (défaut : 10)
#   -H HEURES  période analysée, en heures (défaut : 24, maximum : 8760)
#
# Codes de sortie :
#   0 rien d'anormal | 1 ALERTE : seuil dépassé | 2 argument invalide | 3 pas root
#
# Sécurité : le compte support lance ce script en root via sudo. Il appartient donc
# à root et n'est modifiable que par lui (installer.sh), il n'accepte que des nombres
# en argument, et il n'ouvre jamais de pager : un "less" lancé en root permet
# d'obtenir un shell root en tapant "!sh" (voir GTFOBins, journalctl).

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C                 # messages des outils en anglais, triés de façon stable
export SYSTEMD_PAGER=""         # aucun pager, en plus de --no-pager

# --- Paramètres --------------------------------------------------------------

# Seuil par défaut : fail2ban bannit à 5 échecs en 10 min. 10 échecs sur 24 h depuis
# une même adresse signifie qu'elle a déjà été bannie, ou qu'elle attaque lentement
# pour passer sous le radar de fail2ban : dans les deux cas, un humain doit regarder.
SEUIL=10
HEURES=24
SERVICE="ssh.service"

ECHECS=""                       # une ligne par échec : "compte adresse"
SUCCES=""                       # une ligne par connexion : "compte adresse méthode"

# --- Fonctions utilitaires ---------------------------------------------------

usage() {
    echo "Usage : sudo $(basename "$0") [-s SEUIL] [-H HEURES] [-h]"
    echo "  -s SEUIL   alerte à partir de SEUIL échecs pour une même adresse IP (défaut : 10)"
    echo "  -H HEURES  période analysée en heures, de 1 à 8760 (défaut : 24)"
    echo "Codes de sortie : 0 normal, 1 alerte, 2 argument invalide, 3 pas root"
}

erreur() {
    echo "[ERREUR] $1" >&2
    exit "${2:-2}"
}

# Entier strictement positif, sans zéro en tête (bash lirait "08" comme de l'octal)
est_entier() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

lire_options() {
    local opt
    while getopts ":s:H:h" opt; do
        case "$opt" in
            s) SEUIL="$OPTARG" ;;
            H) HEURES="$OPTARG" ;;
            h) usage; exit 0 ;;
            :) usage >&2; erreur "l'option -$OPTARG attend une valeur" ;;
            *) usage >&2; erreur "option inconnue : -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))
    if (( $# > 0 )); then
        erreur "argument inattendu : $1"
    fi
    est_entier "$SEUIL" || erreur "SEUIL doit être un entier supérieur ou égal à 1"
    if ! est_entier "$HEURES" || (( HEURES > 8760 )); then
        erreur "HEURES doit être un entier entre 1 et 8760"
    fi
}

# Messages du service ssh sur la période (texte seul, sans date ni pager)
journal_ssh() {
    journalctl --no-pager -q -o cat -u "$SERVICE" --since "-${HEURES}h" || true
}

# --- Extraction --------------------------------------------------------------

# Échecs, d'après les lignes réelles d'OpenSSH 10 sur Debian 13 :
#   Invalid user admin from 203.0.113.5 port 51514
#   User askywalker from 10.0.2.2 not allowed because none of user's groups are listed in AllowGroups
#   Failed publickey for mathurin from 10.0.2.2 port 50122 ssh2: ED25519 SHA256:...
#   Connection closed by authenticating user root 10.0.2.2 port 50124 [preauth]
# Chaque ligne devient "compte adresse".
extraire_echecs() {
    journal_ssh | sed -nE \
        -e 's/.*Invalid user (\S*) from ([0-9a-fA-F.:]+) port.*/\1 \2/p' \
        -e 's/.*User (\S+) from ([0-9a-fA-F.:]+) not allowed.*/\1 \2/p' \
        -e 's/.*Failed \S+ for (invalid user )?(\S+) from ([0-9a-fA-F.:]+) port.*/\2 \3/p' \
        -e 's/.*Connection closed by authenticating user (\S+) ([0-9a-fA-F.:]+) port.*\[preauth\].*/\1 \2/p'
}

# Connexions réussies :
#   Accepted publickey for mathurin from 10.0.2.2 port 50126 ssh2: ED25519 SHA256:...
# Chaque ligne devient "compte adresse méthode".
extraire_succes() {
    journal_ssh | sed -nE 's/.*Accepted (\S+) for (\S+) from ([0-9a-fA-F.:]+) port.*/\2 \3 \1/p'
}

# Nombre de lignes non vides d'un texte
compter() {
    if [[ -z "$1" ]]; then
        echo 0
    else
        grep -c . <<< "$1"
    fi
}

# Classement par nombre d'occurrences de la colonne $2 du texte $1
classer() {
    if [[ -z "$1" ]]; then
        echo "    (aucun)"
        return
    fi
    awk -v c="$2" '{ print $c }' <<< "$1" | sort | uniq -c | sort -rn \
        | awk '{ printf "    %5d  %s\n", $1, $2 }'
}

# Adresses ayant atteint le seuil, sous la forme "adresse nombre"
adresses_en_alerte() {
    if [[ -z "$ECHECS" ]]; then
        return
    fi
    awk '{ print $2 }' <<< "$ECHECS" | sort | uniq -c \
        | awk -v s="$SEUIL" '$1 >= s { print $2, $1 }'
}

# --- Rapport -----------------------------------------------------------------

afficher_rapport() {
    echo "=== Rapport des connexions SSH - $(hostname) - $(date '+%F %T') ==="
    echo "Période : $HEURES dernière(s) heure(s) | seuil d'alerte : $SEUIL échecs par adresse IP"
    echo

    echo "--- Échecs d'authentification : $(compter "$ECHECS")"
    echo "  Par adresse IP :"
    classer "$ECHECS" 2
    echo "  Comptes visés :"
    classer "$ECHECS" 1
    echo

    echo "--- Connexions réussies : $(compter "$SUCCES")"
    if [[ -z "$SUCCES" ]]; then
        echo "    (aucune)"
    else
        sort <<< "$SUCCES" | uniq -c | sort -rn \
            | awk '{ printf "    %5d  %s depuis %s (%s)\n", $1, $2, $3, $4 }'
    fi
    echo

    echo "--- Adresses actuellement bannies par fail2ban"
    if command -v fail2ban-client >/dev/null && fail2ban-client status sshd >/dev/null 2>&1; then
        fail2ban-client status sshd | sed -n 's/.*Banned IP list:[[:space:]]*/    /p'
    else
        echo "    (fail2ban indisponible)"
    fi
    echo
}

# --- Programme principal -----------------------------------------------------

main() {
    lire_options "$@"
    if [[ $EUID -ne 0 ]]; then
        erreur "ce script doit être lancé en root (sudo $0)" 3
    fi

    ECHECS="$(extraire_echecs)"
    SUCCES="$(extraire_succes)"
    afficher_rapport

    local alertes
    alertes="$(adresses_en_alerte)"
    if [[ -n "$alertes" ]]; then
        while read -r adresse nombre; do
            echo "[ALERTE] $adresse : $nombre échecs (seuil : $SEUIL)"
        done <<< "$alertes"
        exit 1
    fi
    echo "[OK] aucune adresse n'atteint le seuil de $SEUIL échecs"
    exit 0
}

main "$@"
