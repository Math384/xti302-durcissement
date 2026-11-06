#!/usr/bin/env bash
#
# verifier.sh - Vérifie automatiquement chaque exigence du cahier des charges
#
# Affiche un résultat [OK] / [KO] par test, puis le bilan.
# Ne modifie jamais le système : les seuls fichiers créés sont des fichiers de test
# dans /srv, supprimés à la fin (trap EXIT), même si le script est interrompu.
#
# Usage : sudo ./verifier.sh
#
# Codes de sortie : 0 tout est conforme | 1 au moins un test échoue | 2 pas root

# Pas de "set -e" : ce script lance volontairement des commandes qui peuvent échouer
#   (un commercial qui essaie d'écrire...) et doit continuer après chaque échec.
# Pas de "set -o pipefail" : on teste souvent "commande | grep -q" ; grep -q s'arrête
#   au premier résultat, la commande reçoit alors SIGPIPE et pipefail ferait échouer le test.
# "set -u" est gardé : une variable mal orthographiée doit être une erreur, pas une chaîne vide.
set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_ALL=C          # sorties des commandes en anglais : les grep ne dépendent pas de la langue

# --- Paramètres --------------------------------------------------------------

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV="$REPO_DIR/comptes.csv"
GROUPE_ADMINS="admins"
SCRIPT_SUPPORT="/usr/local/sbin/analyse_logs.sh"

REPERTOIRES=(/srv/donnees_brutes /srv/analyses /srv/publications)
GROUPES_METIER=(technique chercheurs doctorants invite)

# Droits attendus (tableau du contexte C) : rw = lecture/écriture, r = lecture, - = aucun accès
declare -A DROITS=(
    [/srv/donnees_brutes:technique]=rw [/srv/donnees_brutes:chercheurs]=r
    [/srv/donnees_brutes:doctorants]=r [/srv/donnees_brutes:invite]=-
    [/srv/analyses:technique]=-        [/srv/analyses:chercheurs]=rw
    [/srv/analyses:doctorants]=rw      [/srv/analyses:invite]=-
    [/srv/publications:technique]=-    [/srv/publications:chercheurs]=rw
    [/srv/publications:doctorants]=r   [/srv/publications:invite]=r
)

NB_OK=0
NB_TESTS=0
FICHIERS_TEST=()

# --- Affichage ---------------------------------------------------------------

# Couleurs seulement si la sortie est un terminal (pas dans un fichier ou un tube)
if [[ -t 1 ]]; then
    VERT=$'\e[32m'; ROUGE=$'\e[31m'; RAZ=$'\e[0m'
else
    VERT=""; ROUGE=""; RAZ=""
fi

ok() { NB_OK=$((NB_OK + 1)); NB_TESTS=$((NB_TESTS + 1)); echo "${VERT}[OK]${RAZ} $1  $2"; }
ko() { NB_TESTS=$((NB_TESTS + 1)); echo "${ROUGE}[KO]${RAZ} $1  $2"; }

libelle() {
    case "$1" in
        rw) echo "lecture/écriture" ;;
        r)  echo "lecture" ;;
        *)  echo "aucun accès" ;;
    esac
}

# --- Outils ------------------------------------------------------------------

# Supprime les fichiers de test, appelé automatiquement à la sortie du script
nettoyer() {
    if (( ${#FICHIERS_TEST[@]} > 0 )); then
        rm -f "${FICHIERS_TEST[@]}"
    fi
}
trap nettoyer EXIT

lignes_csv() {
    tail -n +2 "$CSV" | tr -d '\r' | grep -v '^[[:space:]]*$'
}

# Premier login du CSV dont le groupe principal est $1 (sert d'utilisateur de test)
premier_membre() {
    lignes_csv | awk -F';' -v g="$1" '$3 == g { print $1; exit }'
}

# Comptes du groupe admins : membres secondaires et comptes dont c'est le groupe principal
membres_admins() {
    local gid
    gid="$(getent group "$GROUPE_ADMINS" | cut -d: -f3)"
    {
        getent group "$GROUPE_ADMINS" | cut -d: -f4 | tr ',' '\n'
        getent passwd | awk -F: -v g="$gid" '$4 == g { print $1 }'
    } | grep -v '^$' | sort -u
}

# Teste un droit à la place d'un utilisateur (root peut tout faire, pas lui)
peut_lister() {
    sudo -u "$1" ls "$2" >/dev/null 2>&1
}
peut_creer() {
    local fichier="$2/.verifier_$1_$$"
    FICHIERS_TEST+=("$fichier")
    sudo -u "$1" touch "$fichier" 2>/dev/null
}

# Valeur d'une option dans la configuration EFFECTIVE de sshd (sshd -T), telle que
# sshd l'applique après lecture de tous les fichiers. Avec un 2e argument, la
# configuration est calculée pour cet utilisateur (blocs Match compris).
option_sshd() {
    local cmd=(sshd -T)
    if [[ -n "${2:-}" ]]; then
        cmd+=(-C "user=$2,host=localhost,addr=127.0.0.1")
    fi
    "${cmd[@]}" 2>/dev/null | awk -v o="$1" '$1 == o { $1 = ""; sub(/^ /, ""); print; exit }'
}

# Convertit une durée sshd en secondes : 600 -> 600, 10m -> 600, 1h -> 3600
en_secondes() {
    local v="$1"
    if [[ ! "$v" =~ ^[0-9]+[smh]?$ ]]; then
        echo 999999            # valeur absente ou illisible : considérée comme trop grande
        return
    fi
    case "$v" in
        *h) echo $(( ${v%h} * 3600 )) ;;
        *m) echo $(( ${v%m} * 60 )) ;;
        *s) echo "${v%s}" ;;
        *)  echo "$v" ;;
    esac
}

# Vérifie qu'une option sshd a la valeur attendue
attendu_sshd() {
    local id="$1" option="$2" attendu="$3" libelle="$4" valeur
    valeur="$(option_sshd "$option")"
    if [[ "$valeur" == "$attendu" ]]; then
        ok "$id" "$libelle ($option $valeur)"
    else
        ko "$id" "$option vaut '${valeur:-absent}' (attendu : $attendu)"
    fi
}

# --- C1 : comptes et groupes conformes à comptes.csv -------------------------

test_C1() {
    if [[ ! -r "$CSV" ]]; then
        ko "C1" "comptes.csv introuvable ($CSV)"
        return
    fi
    local login nom gp gs g liste erreurs
    while IFS=';' read -r login nom gp gs; do
        if ! id "$login" &>/dev/null; then
            ko "C1" "compte $login absent"
            continue
        fi
        erreurs=""
        if [[ "$(id -gn "$login")" != "$gp" ]]; then
            erreurs+=" principal=$gp"
        fi
        IFS=',' read -ra liste <<< "$gs"
        for g in "${liste[@]}"; do
            if ! id -Gn "$login" | tr ' ' '\n' | grep -qx "$g"; then
                erreurs+=" $g"
            fi
        done
        if [[ -z "$erreurs" ]]; then
            ok "C1" "compte $login présent, groupes conformes"
        else
            ko "C1" "compte $login : groupes manquants ou faux :$erreurs"
        fi
    done < <(lignes_csv)
}

# --- C2 : répertoires /srv, droits, ACL et ACL par défaut --------------------

test_C2() {
    local rep groupe user attendu obtenu
    for rep in "${REPERTOIRES[@]}"; do
        if [[ ! -d "$rep" ]]; then
            ko "C2" "$rep n'existe pas"
            continue
        fi
        # Droits effectifs de chaque groupe métier, testés avec un de ses membres
        for groupe in "${GROUPES_METIER[@]}"; do
            user="$(premier_membre "$groupe")"
            if [[ -z "$user" ]]; then
                ko "C2" "aucun membre de $groupe dans comptes.csv pour tester $rep"
                continue
            fi
            attendu="${DROITS[$rep:$groupe]}"
            if peut_creer "$user" "$rep"; then
                obtenu="rw"
            elif peut_lister "$user" "$rep"; then
                obtenu="r"
            else
                obtenu="-"
            fi
            if [[ "$obtenu" == "$attendu" ]]; then
                ok "C2" "$rep : $groupe ($user) a $(libelle "$attendu")"
            else
                ko "C2" "$rep : $groupe ($user) a $(libelle "$obtenu"), attendu : $(libelle "$attendu")"
            fi
        done
        # ACL par défaut : les droits s'appliqueront aux fichiers créés plus tard
        if getfacl -p "$rep" 2>/dev/null | grep -q '^default:group:'; then
            ok "C2" "$rep : ACL par défaut présentes"
        else
            ko "C2" "$rep : pas d'ACL par défaut (setfacl -d)"
        fi
    done

    # Héritage réel : un fichier créé par un chercheur dans publications est lisible par un invité
    local auteur lecteur fichier="/srv/publications/.verifier_heritage_$$"
    auteur="$(premier_membre chercheurs)"
    lecteur="$(premier_membre invite)"
    FICHIERS_TEST+=("$fichier")
    if sudo -u "$auteur" touch "$fichier" 2>/dev/null \
       && sudo -u "$lecteur" cat "$fichier" >/dev/null 2>&1; then
        ok "C2" "héritage : fichier créé par $auteur lisible par $lecteur"
    else
        ko "C2" "héritage : fichier créé par $auteur non lisible par $lecteur"
    fi
}

# --- C3 : sudo pour admins, support limité à analyse_logs.sh, personne d'autre

test_C3() {
    local f="/etc/sudoers.d/xti302"
    if [[ -f "$f" && "$(stat -c '%U:%G %a' "$f")" == "root:root 440" ]]; then
        ok "C3" "$f présent (root:root 440)"
    else
        ko "C3" "$f absent ou mauvais propriétaire/droits"
    fi

    # Le fichier en service est-il celui du dépôt ? (détecte une modification à la main)
    if cmp -s "$f" "$REPO_DIR/config/sudoers.d/xti302"; then
        ok "C3" "$f identique à la version du dépôt"
    else
        ko "C3" "$f différent de config/sudoers.d/xti302 (diff pour voir l'écart)"
    fi

    if visudo -c >/dev/null 2>&1; then
        ok "C3" "configuration sudo valide (visudo -c)"
    else
        ko "C3" "configuration sudo invalide (visudo -c)"
    fi

    local admins login
    admins="$(membres_admins)"
    if [[ -z "$admins" ]]; then
        ko "C3" "le groupe $GROUPE_ADMINS est vide ou absent"
    fi
    for login in $admins; do
        if sudo -l -U "$login" 2>/dev/null | grep -q '(ALL : ALL) ALL'; then
            ok "C3" "$login (admins) a tous les droits sudo"
        else
            ko "C3" "$login (admins) n'a pas sudo"
        fi
    done

    # Les commandes autorisées sont les lignes indentées qui commencent par "("
    local regles
    regles="$(sudo -l -U support 2>/dev/null | grep -E '^[[:space:]]+\(')"
    if [[ "$(grep -c . <<< "$regles")" -eq 1 && "$regles" == *"(root) NOPASSWD: $SCRIPT_SUPPORT" ]]; then
        ok "C3" "le compte support ne peut lancer que analyse_logs.sh"
    else
        ko "C3" "droits sudo de support incorrects : $(echo $regles)"
    fi

    # Le script lancé en root par support ne doit pas être modifiable par lui
    if [[ -f "$SCRIPT_SUPPORT" && "$(stat -c '%U' "$SCRIPT_SUPPORT")" == "root" \
          && -z "$(find "$SCRIPT_SUPPORT" -perm /022)" ]]; then
        ok "C3" "$SCRIPT_SUPPORT appartient à root, non modifiable par les autres"
    else
        ko "C3" "$SCRIPT_SUPPORT absent ou modifiable par un autre que root"
    fi

    # Aucun autre compte n'a sudo (y compris le compte créé à l'installation)
    local u autres=""
    while IFS=: read -r u _; do
        if [[ "$u" == "root" || "$u" == "support" ]] || grep -qx "$u" <<< "$admins"; then
            continue
        fi
        if ! sudo -l -U "$u" 2>&1 | grep -q 'is not allowed to run sudo'; then
            autres+=" $u"
        fi
    done < <(getent passwd)
    if [[ -z "$autres" ]]; then
        ok "C3" "aucun autre compte n'a sudo"
    else
        ko "C3" "comptes avec sudo non prévus :$autres"
    fi
}

# --- C4 : root verrouillé, répertoires personnels privés ---------------------

test_C4() {
    if [[ "$(passwd -S root | awk '{print $2}')" == "L" ]]; then
        ok "C4" "compte root verrouillé"
    else
        ko "C4" "compte root non verrouillé (passwd -S root)"
    fi

    local d ouverts=""
    for d in /home/*/; do
        # Les deux derniers chiffres (groupe, autres) doivent être 0
        if [[ ! "$(stat -c %a "$d")" =~ 00$ ]]; then
            ouverts+=" ${d%/}"
        fi
    done
    if [[ -z "$ouverts" ]]; then
        ok "C4" "répertoires personnels inaccessibles aux autres utilisateurs"
    else
        ko "C4" "répertoires personnels accessibles à d'autres :$ouverts"
    fi

    if grep -qE '^HOME_MODE[[:space:]]+0?700$' /etc/login.defs; then
        ok "C4" "futurs répertoires personnels créés en 700 (HOME_MODE)"
    else
        ko "C4" "HOME_MODE n'est pas à 0700 dans /etc/login.defs"
    fi
}

# --- S1 : connexion par clé uniquement -----------------------------------------

test_S1() {
    attendu_sshd "S1" passwordauthentication no "mot de passe refusé"
    attendu_sshd "S1" kbdinteractiveauthentication no "keyboard-interactive refusé"
    attendu_sshd "S1" authenticationmethods publickey "seule méthode : clé publique"

    # Test réel : le serveur ne propose QUE publickey à un client qui se connecte
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null nobody@127.0.0.1 true 2>&1 \
       | grep -q 'Permission denied (publickey)'; then
        ok "S1" "le serveur ne propose que l'authentification par clé"
    else
        ko "S1" "le serveur propose une autre méthode que publickey (ou ne répond pas)"
    fi
}

# --- S2 : root ne peut pas se connecter ---------------------------------------

test_S2() {
    attendu_sshd "S2" permitrootlogin no "connexion root refusée"
}

# --- S3 : seuls les membres de acces_ssh, avec leur clé du dépôt --------------

test_S3() {
    attendu_sshd "S3" allowgroups acces_ssh "seul le groupe acces_ssh est autorisé"

    # Chaque membre de acces_ssh a exactement la clé publique du dépôt
    local login home
    for login in $(getent group acces_ssh | cut -d: -f4 | tr ',' ' '); do
        home="$(getent passwd "$login" | cut -d: -f6)"
        if cmp -s "$home/.ssh/authorized_keys" "$REPO_DIR/config/cles/$login.pub"; then
            ok "S3" "$login : clé SSH installée, identique au dépôt"
        else
            ko "S3" "$login : authorized_keys absent ou différent de config/cles/$login.pub"
        fi
    done

    # Contexte C : un invité n'a ni shell ni commande, seulement SFTP enfermé dans /srv
    local invite
    invite="$(premier_membre invite)"
    if [[ "$(getent passwd "$invite" | cut -d: -f7)" == "/usr/sbin/nologin" \
          && "$(option_sshd forcecommand "$invite")" == internal-sftp* \
          && "$(option_sshd chrootdirectory "$invite")" == "/srv" ]]; then
        ok "S3" "invite ($invite) : SFTP seul (nologin, internal-sftp, chroot /srv)"
    else
        ko "S3" "invite ($invite) : shell, ForceCommand ou ChrootDirectory incorrect"
    fi
    # sshd refuse le chroot si /srv n'appartient pas à root ou est modifiable par d'autres
    if [[ "$(stat -c %U /srv)" == "root" && -z "$(find /srv -maxdepth 0 -perm /022)" ]]; then
        ok "S3" "/srv utilisable comme chroot (root, non modifiable par d'autres)"
    else
        ko "S3" "/srv n'appartient pas à root ou est modifiable par d'autres : chroot refusé"
    fi
}

# --- S4 : essais limités, sessions inactives fermées ---------------------------

test_S4() {
    local essais
    essais="$(option_sshd maxauthtries)"
    if [[ "$essais" =~ ^[0-9]+$ ]] && (( essais >= 1 && essais <= 4 )); then
        ok "S4" "au plus 4 essais par connexion (MaxAuthTries $essais)"
    else
        ko "S4" "MaxAuthTries vaut '${essais:-absent}' (attendu : 4 au plus)"
    fi

    local inactivite
    inactivite="$(option_sshd channeltimeout | grep -o 'session=[^ ]*' | cut -d= -f2)"
    if (( $(en_secondes "$inactivite") <= 900 )); then
        ok "S4" "session inactive fermée après ${inactivite} (15 min au plus)"
    else
        ko "S4" "pas de fermeture des sessions inactives en 15 min (ChannelTimeout session=${inactivite:-absent})"
    fi
}

# --- S5 : configuration dans sshd_config.d et valide ---------------------------

test_S5() {
    local f="/etc/ssh/sshd_config.d/00-xti302.conf"
    if cmp -s "$f" "$REPO_DIR/config/ssh/sshd_config.d/00-xti302.conf"; then
        ok "S5" "$f présent et identique au dépôt"
    else
        ko "S5" "$f absent ou différent de la version du dépôt"
    fi
    if grep -qE '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config; then
        ok "S5" "sshd_config inclut bien sshd_config.d/*.conf"
    else
        ko "S5" "la ligne Include de sshd_config est absente ou commentée"
    fi
    if sshd -t 2>/dev/null; then
        ok "S5" "configuration SSH valide (sshd -t)"
    else
        ko "S5" "configuration SSH invalide (sshd -t)"
    fi
}

# --- J1 : fail2ban protège SSH -------------------------------------------------

test_J1() {
    if systemctl is-active --quiet fail2ban && systemctl is-enabled --quiet fail2ban; then
        ok "J1" "fail2ban actif et lancé au démarrage"
    else
        ko "J1" "fail2ban arrêté ou non activé au démarrage"
    fi
    if fail2ban-client status sshd >/dev/null 2>&1; then
        ok "J1" "prison sshd active"
    else
        ko "J1" "prison sshd inactive (fail2ban-client status sshd)"
    fi
    if fail2ban-client get sshd actions 2>/dev/null | grep -q nftables; then
        ok "J1" "bannissement par nftables"
    else
        ko "J1" "la prison sshd ne bannit pas par nftables"
    fi
    if cmp -s /etc/fail2ban/jail.d/xti302.conf "$REPO_DIR/config/fail2ban/jail.d/xti302.conf"; then
        ok "J1" "jail.d/xti302.conf identique au dépôt"
    else
        ko "J1" "/etc/fail2ban/jail.d/xti302.conf absent ou différent du dépôt"
    fi
}

# --- J2 : pare-feu nftables ----------------------------------------------------

test_J2() {
    local regles
    regles="$(nft list chain inet filtre entree 2>/dev/null)"
    if grep -q 'policy drop' <<< "$regles"; then
        ok "J2" "politique par défaut en entrée : drop"
    else
        ko "J2" "politique par défaut en entrée : $(grep -o 'policy [a-z]*' <<< "$regles" || echo 'table absente') (attendu : drop)"
    fi
    if grep -q 'tcp dport 22 .*accept' <<< "$regles"; then
        ok "J2" "SSH (22/tcp) autorisé"
    else
        ko "J2" "aucune règle n'autorise SSH (22/tcp)"
    fi
    if grep -q 'ct state established,related accept' <<< "$regles"; then
        ok "J2" "connexions établies autorisées"
    else
        ko "J2" "les connexions établies ne sont pas autorisées"
    fi
    # Survit au redémarrage : le service recharge /etc/nftables.conf, qui doit être le nôtre
    if systemctl is-enabled --quiet nftables \
       && cmp -s /etc/nftables.conf "$REPO_DIR/config/nftables.conf"; then
        ok "J2" "règles rechargées au démarrage (nftables activé, fichier identique au dépôt)"
    else
        ko "J2" "nftables non activé au démarrage ou /etc/nftables.conf différent du dépôt"
    fi
    if ! grep -qE '^[[:space:]]*flush[[:space:]]+ruleset' /etc/nftables.conf 2>/dev/null; then
        ok "J2" "le rechargement du pare-feu n'efface pas les règles de fail2ban"
    else
        ko "J2" "/etc/nftables.conf contient 'flush ruleset' : il efface les bannissements de fail2ban"
    fi
}

# --- J3 : journal persistant ---------------------------------------------------

test_J3() {
    local stockage
    # Configuration effective : fichier principal + journald.conf.d, la dernière valeur gagne
    stockage="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
                | grep -E '^Storage=' | tail -n 1 | cut -d= -f2)"
    if [[ "$stockage" == "persistent" ]]; then
        ok "J3" "journal configuré en Storage=persistent"
    else
        ko "J3" "Storage vaut '${stockage:-auto (défaut)}' (attendu : persistent)"
    fi
    if find /var/log/journal -name '*.journal' 2>/dev/null | grep -q .; then
        ok "J3" "journal écrit sur disque dans /var/log/journal"
    else
        ko "J3" "aucun fichier de journal dans /var/log/journal"
    fi
}

# --- J4 : analyse_logs.sh ------------------------------------------------------

test_J4() {
    if cmp -s "$SCRIPT_SUPPORT" "$REPO_DIR/analyse_logs.sh"; then
        ok "J4" "analyse_logs.sh installé, identique au dépôt"
    else
        ko "J4" "$SCRIPT_SUPPORT absent ou différent du dépôt"
    fi

    local sortie code
    sortie="$("$SCRIPT_SUPPORT" -s 1000000 -H 1 2>&1)"
    code=$?
    if (( code == 0 )) && grep -q "Connexions réussies" <<< "$sortie"; then
        ok "J4" "rapport produit, code de sortie 0 sous le seuil"
    else
        ko "J4" "rapport absent ou code de sortie $code sous le seuil (attendu : 0)"
    fi

    # test_S1 vient de provoquer un échec depuis 127.0.0.1 : avec un seuil de 1, alerte attendue
    "$SCRIPT_SUPPORT" -s 1 -H 1 >/dev/null 2>&1
    code=$?
    if (( code == 1 )); then
        ok "J4" "code de sortie 1 quand le seuil est dépassé"
    else
        ko "J4" "code de sortie $code avec un seuil dépassé (attendu : 1)"
    fi

    "$SCRIPT_SUPPORT" -s abc >/dev/null 2>&1
    code=$?
    if (( code == 2 )); then
        ok "J4" "argument invalide refusé (code 2)"
    else
        ko "J4" "argument invalide accepté (code $code, attendu : 2)"
    fi
}

# --- D1 : mises à jour de sécurité automatiques --------------------------------

test_D1() {
    if dpkg-query -W -f '${Status}' unattended-upgrades 2>/dev/null | grep -q 'install ok installed'; then
        ok "D1" "paquet unattended-upgrades installé"
    else
        ko "D1" "paquet unattended-upgrades absent"
    fi
    local conf
    conf="$(apt-config dump 2>/dev/null)"
    if grep -q '^APT::Periodic::Update-Package-Lists "1";' <<< "$conf" \
       && grep -q '^APT::Periodic::Unattended-Upgrade "1";' <<< "$conf"; then
        ok "D1" "mise à jour quotidienne activée (APT::Periodic)"
    else
        ko "D1" "APT::Periodic::Update-Package-Lists / Unattended-Upgrade ne valent pas 1"
    fi
    if systemctl is-enabled --quiet apt-daily-upgrade.timer; then
        ok "D1" "minuteur apt-daily-upgrade activé"
    else
        ko "D1" "minuteur apt-daily-upgrade désactivé"
    fi
}

# --- Programme principal -----------------------------------------------------

main() {
    if [[ $EUID -ne 0 ]]; then
        echo "[ERREUR] ce script doit être lancé en root (sudo $0)" >&2
        exit 2
    fi
    echo "=== Vérification de conformité - $(hostname) - $(date '+%F %T') ==="
    test_C1
    test_C2
    test_C3
    test_C4
    test_S1
    test_S2
    test_S3
    test_S4
    test_S5
    test_J1
    test_J2
    test_J3
    test_J4
    test_D1
    # À venir : test_B1..B4, test_D2, test_D3
    echo "--- $NB_OK / $NB_TESTS tests réussis"
    if (( NB_OK == NB_TESTS )); then
        exit 0
    fi
    exit 1
}

main "$@"
