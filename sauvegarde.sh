#!/usr/bin/env bash
#
# sauvegarde.sh - Sauvegarde incrémentale et versionnée de /srv et /etc (exigences B1, B2)
#
# Chaque exécution crée une version datée : /sauvegardes/AAAA-MM-JJ_HHMMSS/{etc,srv}.
# Incrémentale : rsync --link-dest compare avec la version précédente ; un fichier
# inchangé n'est pas recopié mais lié (lien physique) au fichier de la version
# précédente. Chaque version paraît complète, mais n'occupe que la place des
# fichiers modifiés.
# Droits, propriétaires et ACL conservés (-a -A -X), liens physiques aussi (-H).
# Les GARDER versions les plus récentes sont gardées, les plus anciennes supprimées.
# Chaque exécution est journalisée dans journald : journalctl -t sauvegarde
#
# Usage : sudo sauvegarde.sh        (lancé chaque nuit par sauvegarde.timer)
#
# Codes de sortie :
#   0 succès | 1 échec de rsync | 2 pas root | 3 disque de sauvegarde non monté
#   4 rsync absent | 5 une sauvegarde est déjà en cours

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C

# --- Paramètres --------------------------------------------------------------

SOURCES=(/srv /etc)
DESTINATION="/sauvegardes"
# 14 versions quotidiennes = 2 semaines de retour arrière (le sujet impose au moins 7)
GARDER=14
FORMAT_VERSION='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'
VERROU="/run/sauvegarde.lock"

# --- Fonctions utilitaires ---------------------------------------------------

# Écrit dans journald (et à l'écran si le script est lancé à la main)
journal() {
    logger -t sauvegarde -p "user.${2:-info}" -- "$1"
    if [[ -t 1 ]]; then
        echo "$1"
    fi
}

echec() {
    journal "ÉCHEC : $1" err
    echo "[ERREUR] $1" >&2
    exit "${2:-1}"
}

verifier_prerequis() {
    [[ $EUID -eq 0 ]] || echec "ce script doit être lancé en root (sudo $0)" 2
    # Sans ce contrôle, si le disque n'est pas monté, la sauvegarde remplirait
    # silencieusement le disque système, et disparaîtrait avec lui
    mountpoint -q "$DESTINATION" \
        || echec "$DESTINATION n'est pas monté : sauvegarde annulée" 3
    command -v rsync >/dev/null || echec "rsync introuvable : apt install rsync" 4
}

# Empêche deux sauvegardes simultanées (timer + lancement manuel, par exemple)
prendre_verrou() {
    exec 9> "$VERROU"
    flock -n 9 || echec "une sauvegarde est déjà en cours" 5
}

# Versions existantes, de la plus ancienne à la plus récente (le format daté se trie seul)
versions() {
    find "$DESTINATION" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | grep -E "$FORMAT_VERSION" | sort || true
}

# --- Sauvegarde --------------------------------------------------------------

sauvegarder() {
    local horodatage cible precedente stats code=0
    local options=(-aAXH --numeric-ids --stats)

    horodatage="$(date +%F_%H%M%S)"
    cible="$DESTINATION/$horodatage"
    precedente="$(versions | tail -n 1)"
    if [[ -n "$precedente" ]]; then
        options+=(--link-dest="$DESTINATION/$precedente")
    fi

    # Restes d'une sauvegarde interrompue (coupure, disque plein...) : jamais réutilisés
    rm -rf "$DESTINATION"/*.en_cours

    journal "début : ${SOURCES[*]} -> $cible (base : ${precedente:-aucune, copie complète})"

    # On écrit dans un dossier .en_cours, renommé seulement si rsync réussit :
    # une version datée est donc toujours complète
    stats="$(rsync "${options[@]}" "${SOURCES[@]}" "$cible.en_cours/" 2>&1)" || code=$?
    # Code 24 : des fichiers ont disparu pendant la copie (normal sur un système actif)
    if (( code != 0 && code != 24 )); then
        rm -rf "$cible.en_cours"
        echec "rsync a échoué (code $code) : $(tail -n 1 <<< "$stats")" 1
    fi
    mv "$cible.en_cours" "$cible"

    journal "fin : version $horodatage créée, $(grep -m1 'Number of regular files transferred' <<< "$stats" | sed 's/.*: //') fichier(s) copié(s), les autres liés à la version précédente"
}

# Supprime les versions les plus anciennes au-delà de GARDER
supprimer_anciennes() {
    local liste nb v
    mapfile -t liste < <(versions)
    nb=${#liste[@]}
    if (( nb <= GARDER )); then
        return
    fi
    for v in "${liste[@]:0:nb - GARDER}"; do
        rm -rf -- "${DESTINATION:?}/$v"
        journal "version supprimée (plus de $GARDER versions) : $v"
    done
}

# --- Programme principal -----------------------------------------------------

main() {
    verifier_prerequis
    prendre_verrou
    sauvegarder
    supprimer_anciennes
    journal "terminé : $(versions | wc -l) version(s) conservée(s) dans $DESTINATION"
}

main "$@"
