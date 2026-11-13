#!/usr/bin/env bash
# DEADPIXEL audit for Linux - a read-only security check of a workstation or home server.
#
# It only READS the system: no package is installed, no setting is changed, nothing is sent anywhere.
# Works as an ordinary user; run with sudo to see what only root can read (firewall rules, /etc/shadow, sudoers).
#
#   ./audit.sh                  all checks, coloured report; exit code = number of critical and high findings
#   sudo ./audit.sh             the same, with root-only checks
#   ./audit.sh --lang uk        Ukrainian texts (default: from $LANG, otherwise English)
#   ./audit.sh --json out.json  also write the report as JSON (same result fields as the Windows audit)
#   ./audit.sh --area ssh       one area: system, ssh, network, accounts, hardening, persistence, secrets, devtools
#   ./audit.sh --list           list the checks
#
# Tested logic targets Debian/Ubuntu, Arch and Fedora families; unknown tools are skipped, not failed.

set -u
export LC_ALL=C

UI=""; JSON_OUT=""; ONLY_AREA=""; LIST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --lang) UI="${2:-}"; shift 2 ;;
        --json) JSON_OUT="${2:-}"; shift 2 ;;
        --area) ONLY_AREA="${2:-}"; shift 2 ;;
        --list) LIST=1; shift ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 255 ;;
    esac
done
if [ -z "$UI" ]; then case "${LANGUAGE:-}${LANG:-}" in uk*|*uk_UA*) UI=uk ;; *) UI=en ;; esac; fi

# t 'українською' 'English'
t() { if [ "$UI" = uk ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
# The person being audited: with sudo, look at the invoking user's home, not root's
AUDIT_USER="${SUDO_USER:-$(id -un)}"
AUDIT_HOME="$(getent passwd "$AUDIT_USER" 2>/dev/null | cut -d: -f6)"; [ -n "$AUDIT_HOME" ] || AUDIT_HOME="$HOME"

# ---------------------------------------------------------------- results

R_AREA=(); R_ID=(); R_TITLE=(); R_STATUS=(); R_SEV=(); R_VALUE=(); R_DETAIL=(); R_EV=()
CUR_AREA=""; CUR_ID=""; CUR_TITLE=""

# Status: ok | issue | info | unknown | na.  Severity (for issue): critical | high | medium | low
add() { # status severity value detail evidence(newline-separated)
    R_AREA+=("$CUR_AREA"); R_ID+=("$CUR_ID"); R_TITLE+=("$CUR_TITLE")
    R_STATUS+=("$1"); R_SEV+=("$2"); R_VALUE+=("$3"); R_DETAIL+=("${4:-}"); R_EV+=("${5:-}")
}
ok()      { add ok "" "$1" "${2:-}" "${3:-}"; }
issue()   { if [ "$1" = info ]; then add info info "$2" "${3:-}" "${4:-}"; else add issue "$1" "$2" "${3:-}" "${4:-}"; fi; }
unknown() { add unknown "" "?" "$1" ""; }
na()      { add na "" "-" "$1" ""; }
need_root() { unknown "$(t 'Потрібні права root: запустіть через sudo.' 'Needs root: run with sudo.')"; }

AREAS=(); AREA_TITLES=(); CHECKS=()
area() { AREAS+=("$1"); AREA_TITLES+=("$2"); }
check() { CHECKS+=("$1|$2|$3|$4"); }   # area|id|function|title

# ---------------------------------------------------------------- helpers

# Effective sshd option: `sshd -T` as root, otherwise the first occurrence in the config files (sshd uses the first one)
sshd_opt() { # name default
    local v=""
    if [ "$IS_ROOT" -eq 1 ] && have sshd; then v="$(sshd -T 2>/dev/null | awk -v k="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" '$1==k {print $2; exit}')"; fi
    if [ -z "$v" ]; then
        v="$(cat /etc/ssh/sshd_config.d/*.conf /etc/ssh/sshd_config 2>/dev/null | awk -v k="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" 'tolower($1)==k {print tolower($2); exit}')"
    fi
    printf '%s' "${v:-$2}"
}
# Value of a key in ~/.npmrc (last occurrence)
npmrc() { [ -r "$AUDIT_HOME/.npmrc" ] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$AUDIT_HOME/.npmrc" | tail -n1 | tr -d '"'; }
# Major version of npm without running it: package.json next to the real npm-cli
npm_major() {
    local p; p="$(command -v npm 2>/dev/null)" || return 1
    p="$(readlink -f "$p" 2>/dev/null)"; p="$(dirname "$(dirname "$p")")/package.json"
    [ -r "$p" ] && sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9]*\)\..*/\1/p' "$p" | head -n1
}
# Lines of a file without comments and blanks
clean_lines() { [ -r "$1" ] && grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null; }
# A private key: prints "plain" or "encrypted", nothing if the file is not a private key
ssh_key_state() {
    local f="$1" head
    head="$(head -n 3 "$f" 2>/dev/null)" || return
    case "$head" in
        *"BEGIN OPENSSH PRIVATE KEY"*)
            # openssh-key-v1: the cipher name follows the magic string; "none" means no passphrase
            if sed '1d;$d' "$f" | tr -d '\n' | base64 -d 2>/dev/null | head -c 48 | grep -aq 'none'; then echo plain; else echo encrypted; fi ;;
        *"BEGIN ENCRYPTED PRIVATE KEY"*) echo encrypted ;;
        *"PRIVATE KEY"*) if grep -q 'ENCRYPTED' "$f" 2>/dev/null; then echo encrypted; else echo plain; fi ;;
        PuTTY-User-Key-File*) if grep -q '^Encryption: none' "$f"; then echo plain; else echo encrypted; fi ;;
    esac
}
join_lines() { local IFS=$'\n'; printf '%s' "$*"; }

# ---------------------------------------------------------------- system

c_updates() {
    local n=0 sec=0 note=""
    if have apt; then
        n="$(apt list --upgradable 2>/dev/null | grep -c '/')"
        sec="$(apt list --upgradable 2>/dev/null | grep -ci -- '-security')"
        note="$(t 'За локальним списком пакетів (оновлюється командою apt update).' 'From the local package lists (refreshed by apt update).')"
    elif have pacman; then
        if have checkupdates; then n="$(checkupdates 2>/dev/null | grep -c .)"; note="checkupdates"
        else n="$(pacman -Qu 2>/dev/null | grep -c .)"; note="$(t 'За локальною базою pacman (оновлюється pacman -Sy); точніше - checkupdates з пакета pacman-contrib.' 'From the local pacman database (refreshed by pacman -Sy); checkupdates from pacman-contrib is more accurate.')"; fi
    elif have dnf; then
        n="$(dnf -C -q check-update 2>/dev/null | grep -cE '^[[:alnum:]]')"; note="$(t 'За кешем dnf.' 'From the dnf cache.')"
    elif have zypper; then
        n="$(zypper -n -q lu 2>/dev/null | grep -c '^v ')"
    else na "$(t 'Невідомий менеджер пакетів.' 'Unknown package manager.')"; return; fi
    if [ "$sec" -gt 0 ]; then issue high "$(t "$n оновлень, безпеки: $sec" "$n updates, security: $sec")" "$(t 'Є невстановлені оновлення безпеки: відомі вразливості лишаються відкритими.' 'Security updates are pending: known vulnerabilities stay open.') $note"
    elif [ "$n" -gt 50 ]; then issue medium "$(t "$n оновлень" "$n updates")" "$(t 'Система давно не оновлювалась.' 'The system has not been updated for a long time.') $note"
    elif [ "$n" -gt 0 ]; then issue low "$(t "$n оновлень" "$n updates")" "$note"
    else ok "$(t 'усе оновлено' 'up to date')" "$note"; fi
}

c_auto_updates() {
    if have apt; then
        if grep -rqsE 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/ 2>/dev/null; then ok "unattended-upgrades"
        else issue medium "$(t 'вимкнено' 'off')" "$(t 'Оновлення безпеки не встановлюються самі. Для сервера, який працює місяцями без нагляду, це головний ризик. Увімкнути: sudo apt install unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades' 'Security updates are not installed automatically. For a server that runs unattended for months this is the main risk. Enable: sudo apt install unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades')"; fi
    elif have dnf; then
        if systemctl is-enabled dnf-automatic.timer dnf5-automatic.timer 2>/dev/null | grep -q enabled; then ok "dnf-automatic"
        else issue low "$(t 'вимкнено' 'off')" "$(t 'Увімкнути: sudo dnf install dnf-automatic && sudo systemctl enable --now dnf-automatic.timer' 'Enable: sudo dnf install dnf-automatic && sudo systemctl enable --now dnf-automatic.timer')"; fi
    elif have pacman; then
        issue info "$(t 'вручну' 'manual')" "$(t 'Arch не підтримує автоматичні оновлення: оновлюйте регулярно (sudo pacman -Syu) і читайте новини archlinux.org перед великими оновленнями. Пакети з AUR переглядайте перед збиранням - їх ніхто не перевіряє.' 'Arch does not support unattended upgrades: update regularly (sudo pacman -Syu) and read archlinux.org news before large updates. Review AUR packages before building - nobody vets them.')"
    else na "$(t 'Невідомий менеджер пакетів.' 'Unknown package manager.')"; fi
}

c_reboot() {
    if [ -e /var/run/reboot-required ]; then issue medium "$(t 'потрібне' 'required')" "$(t 'Оновлення ядра чи бібліотек діє лише після перезавантаження.' 'A kernel or library update takes effect only after a reboot.')" "$(cat /var/run/reboot-required.pkgs 2>/dev/null | head -n 10)"
    elif [ ! -d "/lib/modules/$(uname -r)" ] && [ ! -d "/usr/lib/modules/$(uname -r)" ]; then issue medium "$(t 'потрібне' 'required')" "$(t "Ядро оновлено, а працює старе ($(uname -r)): нові модулі не завантажаться, виправлення не діють." "The kernel was updated but the old one is running ($(uname -r)): new modules will not load, fixes are not active.")"
    else ok "$(t 'не потрібне' 'not needed')" "$(t 'ядро' 'kernel') $(uname -r)"; fi
}

# ---------------------------------------------------------------- ssh

sshd_active() { systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null || pgrep -x sshd >/dev/null 2>&1; }

c_sshd() {
    if ! sshd_active; then
        if have sshd; then ok "$(t 'сервер не запущено' 'server not running')"; else na "$(t 'Сервер SSH не встановлено.' 'No SSH server installed.')"; fi; return
    fi
    local pw root empty ev="" sev=""
    pw="$(sshd_opt PasswordAuthentication yes)"; root="$(sshd_opt PermitRootLogin prohibit-password)"; empty="$(sshd_opt PermitEmptyPasswords no)"
    ev="PasswordAuthentication $pw"$'\n'"PermitRootLogin $root"$'\n'"PermitEmptyPasswords $empty"
    [ "$empty" = yes ] && sev=critical
    [ -z "$sev" ] && [ "$root" = yes ] && [ "$pw" = yes ] && sev=high
    [ -z "$sev" ] && [ "$pw" = yes ] && sev=medium
    [ -z "$sev" ] && [ "$root" = yes ] && sev=low
    if [ -z "$sev" ]; then ok "$(t 'лише ключі' 'keys only')" "" "$ev"; return; fi
    issue "$sev" "$(t 'вхід за паролем' 'password sign-in')" "$(t 'Паролі до SSH підбирають автоматично й цілодобово - і з інтернету, і з будь-якого зараженого пристрою у вашій мережі. Вхід лише за ключем робить підбір неможливим. У /etc/ssh/sshd_config.d/ створіть файл із PasswordAuthentication no і PermitRootLogin no, потім sudo systemctl reload ssh (спершу перевірте, що вхід за ключем працює).' 'SSH passwords are brute-forced automatically around the clock - from the internet and from any infected device on your network. Key-only sign-in makes guessing impossible. Create a file in /etc/ssh/sshd_config.d/ with PasswordAuthentication no and PermitRootLogin no, then sudo systemctl reload ssh (first make sure key sign-in works).')" "$ev"
}

c_ssh_keys() {
    local plain="" enc=0 f st
    for f in "$AUDIT_HOME"/.ssh/*; do
        [ -f "$f" ] || continue
        case "$f" in *.pub|*/known_hosts*|*/config|*/authorized_keys*) continue ;; esac
        st="$(ssh_key_state "$f")"
        [ "$st" = plain ] && plain="$plain$f"$'\n'
        [ "$st" = encrypted ] && enc=$((enc + 1))
    done
    plain="${plain%$'\n'}"
    if [ -z "$plain" ]; then ok "$(t "усі з паролем ($enc)" "all protected ($enc)")"; return; fi
    issue low "$(t "$(printf '%s\n' "$plain" | grep -c .) без пароля" "$(printf '%s\n' "$plain" | grep -c .) unprotected")" "$(t 'Приватний ключ без пароля - готовий доступ до інших машин: досить скопіювати файл. Додати пароль: ssh-keygen -p -f <ключ>; щоб не вводити щоразу - ssh-agent.' 'A private key without a passphrase is ready-made access to other machines: copying the file is enough. Add one: ssh-keygen -p -f <key>; use ssh-agent to avoid retyping it.')" "$plain"
}

c_authorized_keys() {
    local f="$AUDIT_HOME/.ssh/authorized_keys" n ev
    if [ ! -r "$f" ]; then ok "$(t 'немає' 'none')"; return; fi
    n="$(clean_lines "$f" | grep -c .)"
    ev="$(clean_lines "$f" | awk '{ c=$NF; if (NF<3) c="(no comment)"; print $1" … "c }' | head -n 20)"
    if [ "$n" -eq 0 ]; then ok "$(t 'немає' 'none')"
    else issue info "$(t "$n ключів" "$n keys")" "$(t 'Кожен із цих ключів дає вхід на цю машину без пароля. Шкідливі програми дописують сюди свій ключ, щоб лишитися після очищення. Впізнайте кожен.' 'Each of these keys signs in to this machine without a password. Malware appends its own key here to survive a cleanup. Make sure you recognize each one.')" "$ev"; fi
}

# ---------------------------------------------------------------- network

LISTEN=""   # proto<TAB>addr:port<TAB>process, non-loopback only
load_listen() {
    [ -n "$LISTEN" ] && return
    have ss || return
    LISTEN="$(ss -H -tulnp 2>/dev/null | awk '{
        proto=$1; local=$5; proc="";
        for (i=6;i<=NF;i++) if ($i ~ /users:/) { proc=$i; sub(/.*\(\("/,"",proc); sub(/".*/,"",proc) }
        if (local ~ /^(127\.|\[::1\]|localhost)/ || local ~ /%lo:/) next;
        print proto "\t" local "\t" proc }' | sort -u)"
}

c_firewall() {
    local active="" ev=""
    if have ufw; then
        if [ "$IS_ROOT" -eq 1 ]; then ufw status 2>/dev/null | grep -q 'Status: active' && active="ufw"
        else grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf && active="ufw"; fi
    fi
    [ -z "$active" ] && systemctl is-active --quiet firewalld 2>/dev/null && active="firewalld"
    if [ -z "$active" ] && have nft; then
        # A ruleset counts as a firewall only if it has an input chain that drops or rejects something
        if [ "$IS_ROOT" -eq 1 ]; then nft list ruleset 2>/dev/null | awk '/hook input/ {i=1} i && /(policy drop|drop|reject)/ {f=1} END {exit !f}' && active="nftables"
        else systemctl is-active --quiet nftables 2>/dev/null && active="nftables"; fi
    fi
    if [ -z "$active" ] && [ "$IS_ROOT" -eq 1 ] && have iptables; then iptables -S INPUT 2>/dev/null | head -n1 | grep -qE -- '-P INPUT (DROP|REJECT)' && active="iptables"; fi
    if [ -n "$active" ]; then ok "$active"; return; fi
    if [ "$IS_ROOT" -eq 0 ] && { have nft || have iptables; }; then unknown "$(t 'Правила брандмауера видно лише root: запустіть через sudo.' 'Firewall rules are visible only to root: run with sudo.')"; return; fi
    load_listen
    local n; n="$(printf '%s\n' "$LISTEN" | grep -c .)"
    issue "$([ "$n" -gt 0 ] && echo high || echo medium)" "$(t 'вимкнено' 'off')" "$(t "Жодного брандмауера: усі $n відкритих портів доступні кожному пристрою в мережі. Найпростіше: sudo ufw default deny incoming && sudo ufw allow ssh && sudo ufw enable (Arch: пакет ufw або nftables)." "No firewall: all $n open ports are reachable by every device on the network. Simplest fix: sudo ufw default deny incoming && sudo ufw allow ssh && sudo ufw enable (Arch: the ufw or nftables package).")"
}

c_listening() {
    have ss || { na "$(t 'Немає утиліти ss (пакет iproute2).' 'The ss tool is missing (iproute2 package).')"; return; }
    load_listen
    if [ -z "$LISTEN" ]; then ok "$(t 'немає' 'none')" "$(t 'Жодна програма не приймає з’єднань з мережі.' 'No program accepts connections from the network.')"; return; fi
    local risky="" ev="" line port name n
    while IFS=$'\t' read -r proto addr proc; do
        port="${addr##*:}"; name=""
        case "$port" in
            21) name="FTP" ;; 23) name="Telnet" ;; 111) name="rpcbind" ;; 139|445) name="SMB" ;; 2049) name="NFS" ;; 2375) name="Docker API $(t '(без захисту = root для всіх)' '(unprotected = root for everyone)')" ;;
            3306) name="MySQL" ;; 5432) name="PostgreSQL" ;; 6379) name="Redis" ;; 27017) name="MongoDB" ;; 9200) name="Elasticsearch" ;; 11211) name="memcached" ;;
            5900|5901) name="VNC" ;; 3389) name="RDP" ;; 1080|3128|9050) name="$(t 'проксі' 'proxy')" ;;
        esac
        if [ -n "$name" ]; then risky="$risky$port "; ev="$ev⚠ $proto $addr  ${proc:-?}  [$name]"$'\n'; else ev="$ev$proto $addr  ${proc:-?}"$'\n'; fi
    done <<< "$LISTEN"
    n="$(printf '%s\n' "$LISTEN" | grep -c .)"
    [ "$IS_ROOT" -eq 0 ] && ev="$ev$(t '(назви чужих процесів видно лише root)' '(other users'"'"' process names are visible only to root)')"
    if [ -n "$risky" ]; then issue medium "$(t "$n портів, ризикованих: $(printf '%s' "$risky" | wc -w)" "$n ports, risky: $(printf '%s' "$risky" | wc -w)")" "$(t 'Позначені ⚠ служби не розраховані на відкриту мережу: бази даних і Docker API часто без пароля, SMB/VNC/Telnet - улюблена ціль хробаків. Прив’яжіть їх до 127.0.0.1 або закрийте брандмауером.' 'Services marked ⚠ are not meant for an open network: databases and the Docker API often have no password, SMB/VNC/Telnet are worm favourites. Bind them to 127.0.0.1 or close them with the firewall.')" "${ev%$'\n'}"
    else issue info "$(t "$n портів" "$n ports")" "$(t 'Програми, що приймають з’єднання з мережі. Переконайтеся, що впізнаєте кожну і що вона має бути доступна іншим пристроям.' 'Programs accepting network connections. Make sure you recognize each and that it should be reachable by other devices.')" "${ev%$'\n'}"; fi
}

c_proxy_use() {
    local ev="" sev="" p
    p="$(pgrep -fal 'honeygain|packetstream|pawns|iproyal|earnapp|peer2profit|repocket|traffmonetizer|proxyrack|bytelixir|nodepay|getgrass|mysterium|brd_sdk|luminati' 2>/dev/null | grep -v pgrep | head -n 10)"
    [ -n "$p" ] && { ev="$(printf '%s\n' "$p" | sed 's/^/⚠ /')"; sev=medium; }
    if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = 1 ]; then
        ev="$ev${ev:+$'\n'}$(t 'net.ipv4.ip_forward = 1: машина пересилає пакети між мережами (потрібно Docker, VPN-серверу, віртуальним машинам).' 'net.ipv4.ip_forward = 1: the machine forwards packets between networks (needed by Docker, a VPN server, virtual machines).')"
        [ -z "$sev" ] && sev=info
    fi
    if [ -z "$ev" ]; then ok "$(t 'не знайдено' 'none found')"; return; fi
    if [ "$sev" = info ]; then issue info "$(t 'пересилання увімкнено' 'forwarding on')" "" "$ev"
    else issue medium "$(t 'програма-проксі' 'proxy program')" "$(t 'Ця програма пропускає через вашу IP-адресу чужий трафік. Що саме через неї йде, ви не контролюєте.' 'This program routes other people’s traffic through your IP address. You do not control what goes through it.')" "$ev"; fi
}

# ---------------------------------------------------------------- accounts

c_uid0() {
    local x; x="$(awk -F: '$3==0 && $1!="root" {print $1}' /etc/passwd 2>/dev/null)"
    if [ -n "$x" ]; then issue high "$(printf '%s\n' "$x" | grep -c .)" "$(t 'Облікові записи з UID 0 - це другий root під іншим іменем. У звичайній системі такий лише один.' 'Accounts with UID 0 are a second root under another name. A normal system has exactly one.')" "$x"
    else ok "$(t 'лише root' 'root only')"; fi
}

c_empty_passwords() {
    if [ "$IS_ROOT" -eq 0 ]; then need_root; return; fi
    local x; x="$(awk -F: '$2=="" {print $1}' /etc/shadow 2>/dev/null)"
    if [ -n "$x" ]; then issue critical "$(printf '%s\n' "$x" | grep -c .)" "$(t 'У ці облікові записи можна ввійти без пароля. Задайте пароль (passwd <ім’я>) або заблокуйте (passwd -l <ім’я>).' 'These accounts can be signed in to without a password. Set one (passwd <name>) or lock the account (passwd -l <name>).')" "$x"
    else ok "$(t 'немає' 'none')"; fi
}

c_sudo() {
    local ev="" sev=""
    if [ "$IS_ROOT" -eq 1 ]; then
        ev="$(grep -rsE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | sed 's/^/⚠ /' | head -n 20)"
        [ -n "$ev" ] && sev=medium
    elif have sudo && sudo -n true 2>/dev/null; then
        ev="⚠ $(t "$AUDIT_USER може виконувати sudo без пароля" "$AUDIT_USER can run sudo without a password")"; sev=medium
    fi
    if id -nG "$AUDIT_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        ev="$ev${ev:+$'\n'}⚠ $(t "$AUDIT_USER у групі docker: це права root без пароля (docker run -v /:/host)" "$AUDIT_USER is in the docker group: that is root without a password (docker run -v /:/host)")"; [ -z "$sev" ] && sev=low
    fi
    if [ -z "$ev" ]; then
        if [ "$IS_ROOT" -eq 0 ]; then ok "$(t 'sudo питає пароль' 'sudo asks for a password')" "$(t 'Повний перелік правил sudoers видно лише root.' 'The full sudoers rule list is visible only to root.')"; else ok "$(t 'sudo питає пароль' 'sudo asks for a password')"; fi; return
    fi
    issue "$sev" "$(t 'root без пароля' 'root without a password')" "$(t 'Будь-яка програма, запущена від вашого імені (скрипт встановлення пакета, зламаний застосунок), одразу отримує права root - без жодного запиту. Пароль sudo - остання перешкода між зараженим пакетом і всією системою.' 'Any program running as you (a package install script, a compromised app) gets root at once - with no prompt. The sudo password is the last barrier between an infected package and the whole system.')" "$ev"
}

# ---------------------------------------------------------------- hardening

c_sysctl() {
    local bad="" k want cur
    while read -r k want; do
        cur="$(sysctl -n "$k" 2>/dev/null)" || continue
        [ -z "$cur" ] && continue
        if [ "$cur" -lt "$want" ] 2>/dev/null; then bad="$bad$k = $cur ($(t 'рекомендовано' 'recommended') >= $want)"$'\n'; fi
    done <<'EOF'
kernel.kptr_restrict 1
kernel.dmesg_restrict 1
kernel.yama.ptrace_scope 1
kernel.unprivileged_bpf_disabled 1
net.ipv4.tcp_syncookies 1
net.ipv4.conf.all.rp_filter 1
fs.protected_symlinks 1
fs.protected_hardlinks 1
EOF
    if [ -z "$bad" ]; then ok "$(t 'як рекомендовано' 'as recommended')"
    else issue low "$(printf '%s' "$bad" | grep -c .)" "$(t 'Параметри ядра, що ускладнюють підвищення прав і підробку мережевих пакетів. Задаються у /etc/sysctl.d/99-hardening.conf, застосовуються sudo sysctl --system. ptrace_scope=1 не дає одній вашій програмі читати пам’ять іншої (так крадуть паролі з браузера й ssh-agent).' 'Kernel parameters that make privilege escalation and packet spoofing harder. Set them in /etc/sysctl.d/99-hardening.conf, apply with sudo sysctl --system. ptrace_scope=1 stops one of your programs from reading another’s memory (how passwords are stolen from a browser or ssh-agent).')" "${bad%$'\n'}"; fi
}

c_mac() {
    if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ]; then ok "AppArmor"
    elif have getenforce && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then ok "SELinux"
    elif have getenforce && [ "$(getenforce 2>/dev/null)" = Permissive ]; then issue low "SELinux permissive" "$(t 'SELinux лише записує порушення, але не блокує їх.' 'SELinux only logs violations and does not block them.')"
    else issue low "$(t 'немає' 'none')" "$(t 'Ні AppArmor, ні SELinux: зламана служба чи програма обмежена лише правами користувача. В Ubuntu AppArmor увімкнений типово; в Arch - пакет apparmor і параметр ядра lsm=.' 'Neither AppArmor nor SELinux: a compromised service or program is limited only by user permissions. Ubuntu enables AppArmor by default; on Arch install apparmor and set the lsm= kernel parameter.')"; fi
}

c_disk_encryption() {
    have lsblk || { na "lsblk"; return; }
    if lsblk -rno TYPE 2>/dev/null | grep -q crypt; then ok "LUKS"; return; fi
    if ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then issue medium "$(t 'немає' 'none')" "$(t 'Ноутбук без шифрування диска: загублений або вкрадений пристрій - це всі файли, ключі SSH і збережені паролі.' 'A laptop without disk encryption: a lost or stolen device means all files, SSH keys and saved passwords.')"
    else issue info "$(t 'немає' 'none')" "$(t 'Диск не зашифровано. Для стаціонарного ПК чи домашнього сервера це питання фізичного доступу до нього.' 'The disk is not encrypted. For a desktop or home server this is a matter of physical access to it.')"; fi
}

c_secure_boot() {
    local s=""
    if have mokutil; then s="$(mokutil --sb-state 2>/dev/null)"; elif have bootctl; then s="$(bootctl status 2>/dev/null | grep -i 'secure boot')"; fi
    case "$s" in
        *enabled*) ok "$(t 'увімкнено' 'on')" ;;
        *disabled*) issue info "$(t 'вимкнено' 'off')" "$(t 'Без Secure Boot завантажувач і ядро можна підмінити, маючи root або фізичний доступ.' 'Without Secure Boot the bootloader and kernel can be replaced by someone with root or physical access.')" ;;
        *) if [ -d /sys/firmware/efi ]; then unknown "$(t 'Стан не визначити (потрібен mokutil або bootctl).' 'Cannot tell (needs mokutil or bootctl).')"; else na "$(t 'Система завантажена не через UEFI.' 'The system is not booted through UEFI.')"; fi ;;
    esac
}

# ---------------------------------------------------------------- persistence

SUSPICIOUS='curl[^|;&]*\|[[:space:]]*(ba|z|da)?sh|wget[^|;&]*\|[[:space:]]*(ba|z|da)?sh|base64[[:space:]]+(-d|--decode)[^|]*\|[[:space:]]*(ba|z)?sh|/dev/tcp/|nc[[:space:]]+-[a-z]*e|python[0-9.]*[[:space:]]+-c[[:space:]].*(socket|base64)|/dev/shm/|/tmp/\.[[:alnum:]]'

c_cron() {
    local ev="" bad="" f
    ev="$(crontab -l 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' | sed "s/^/$AUDIT_USER: /")"
    if [ "$IS_ROOT" -eq 1 ]; then
        for f in /etc/crontab /etc/cron.d/* /var/spool/cron/* /var/spool/cron/crontabs/*; do
            [ -f "$f" ] && ev="$ev${ev:+$'\n'}$(clean_lines "$f" | grep -vE '^[A-Z_]+=' | sed "s|^|$f: |")"
        done
    fi
    ev="$(printf '%s\n' "$ev" | grep . | head -n 40)"
    if [ -z "$ev" ]; then ok "$(t 'порожньо' 'empty')"; return; fi
    bad="$(printf '%s\n' "$ev" | grep -E "$SUSPICIOUS")"
    if [ -n "$bad" ]; then issue high "$(printf '%s\n' "$bad" | grep -c .)" "$(t 'Завдання cron завантажує й виконує код з мережі або запускає файл із тимчасової папки - типове закріплення майнерів і ботів.' 'A cron job downloads and runs code from the network or launches a file from a temporary folder - typical persistence of miners and bots.')" "$(printf '%s\n' "$bad" | sed 's/^/⚠ /')"
    else issue info "$(printf '%s\n' "$ev" | grep -c .)" "$(t 'Завдання за розкладом. Переконайтеся, що впізнаєте кожне.' 'Scheduled jobs. Make sure you recognize each one.')" "$ev"; fi
}

c_user_units() {
    local ev="" bad="" f
    for f in "$AUDIT_HOME"/.config/systemd/user/*.service "$AUDIT_HOME"/.config/autostart/*.desktop; do
        [ -f "$f" ] || continue
        ev="$ev$f: $(grep -m1 -E '^(ExecStart|Exec)=' "$f" 2>/dev/null)"$'\n'
    done
    ev="${ev%$'\n'}"
    if [ -z "$ev" ]; then ok "$(t 'немає' 'none')"; return; fi
    bad="$(printf '%s\n' "$ev" | grep -E "$SUSPICIOUS|=(/tmp/|/var/tmp/)")"
    if [ -n "$bad" ]; then issue high "$(printf '%s\n' "$bad" | grep -c .)" "$(t 'Автозапуск користувача запускає файл із тимчасової папки або код з мережі.' 'A user autostart entry runs a file from a temporary folder or code from the network.')" "$(printf '%s\n' "$bad" | sed 's/^/⚠ /')"
    else issue info "$(printf '%s\n' "$ev" | grep -c .)" "$(t 'Те, що стартує разом із вашим сеансом без прав root. Шкідливі пакети npm і pip закріплюються саме тут.' 'What starts with your session without root. Malicious npm and pip packages persist exactly here.')" "$ev"; fi
}

c_shell_rc() {
    local bad="" f
    for f in .bashrc .bash_profile .profile .zshrc .zprofile .zshenv .config/fish/config.fish; do
        [ -r "$AUDIT_HOME/$f" ] && bad="$bad$(grep -nE "$SUSPICIOUS" "$AUDIT_HOME/$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|~/$f:|")"$'\n'
    done
    bad="$(printf '%s\n' "$bad" | grep . | head -n 20)"
    if [ -s /etc/ld.so.preload ]; then bad="$bad${bad:+$'\n'}/etc/ld.so.preload: $(tr '\n' ' ' < /etc/ld.so.preload)"; fi
    if [ -z "$bad" ]; then ok "$(t 'чисто' 'clean')"
    else issue high "$(printf '%s\n' "$bad" | grep -c .)" "$(t 'У файлах, які оболонка виконує під час кожного входу, є команда, що завантажує й запускає код, або /etc/ld.so.preload підвантажує бібліотеку в кожну програму. Перевірте кожен рядок.' 'Files the shell runs at every sign-in contain a command that downloads and runs code, or /etc/ld.so.preload injects a library into every program. Review each line.')" "$bad"; fi
}

# ---------------------------------------------------------------- secrets

c_tokens() {
    local found="" f pat
    while IFS='|' read -r f pat; do
        [ -e "$AUDIT_HOME/$f" ] || continue
        if [ -n "$pat" ]; then grep -qsE "$pat" "$AUDIT_HOME/$f" || continue; fi
        found="$found~/$f"$'\n'
    done <<'EOF'
.aws/credentials|aws_secret_access_key
.git-credentials|://[^/:]+:[^@]+@
.npmrc|(_authToken|_auth|_password)[[:space:]]*=[[:space:]]*[^$[:space:]]
.pypirc|^[[:space:]]*password
.netrc|password[[:space:]]
.docker/config.json|"auth"[[:space:]]*:[[:space:]]*"[A-Za-z0-9+/=]{8,}"
.kube/config|^[[:space:]]*(token|client-key-data|password):
.config/gh/hosts.yml|oauth_token:
.cargo/credentials.toml|^[[:space:]]*token
.config/gcloud/application_default_credentials.json|"(refresh_token|private_key)"
.config/rclone/rclone.conf|^[[:space:]]*(token|pass|secret_access_key)[[:space:]]*=
.terraform.d/credentials.tfrc.json|"token"
.config/hub|oauth_token
.vault-token|
EOF
    grep -qsE '^[[:space:]]*helper[[:space:]]*=[[:space:]]*store' "$AUDIT_HOME/.gitconfig" && found="$found~/.gitconfig (credential.helper = store)"$'\n'
    found="${found%$'\n'}"
    if [ -z "$found" ]; then ok "$(t 'не знайдено' 'none found')"
    else issue medium "$(printf '%s\n' "$found" | grep -c .)" "$(t 'Робочі токени й ключі у відкритих файлах. Заражений пакет чи скрипт читає їх за мить і діє від вашого імені без пароля й двофакторного коду. Значення у звіт не потрапляють.' 'Working tokens and keys in plain-text files. An infected package or script reads them in an instant and acts as you, with no password or two-factor code. Values are not copied into the report.')" "$found"; fi
}

c_env_secrets() {
    local ev="" f
    for f in .bashrc .bash_profile .profile .zshrc .zshenv .pam_environment .config/environment.d/*.conf; do
        [ -r "$AUDIT_HOME/$f" ] && ev="$ev$(grep -nE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_]*(TOKEN|SECRET|API_?KEY|PASSWORD|PASSWD|PRIVATE_KEY|ACCESS_KEY)[A-Za-z_]*=.{8,}' "$AUDIT_HOME/$f" 2>/dev/null | sed -E "s|^([0-9]+):[[:space:]]*(export[[:space:]]+)?([A-Za-z_]+)=.*|~/$f:\1 \3|")"$'\n'
    done
    ev="$(printf '%s\n' "$ev" | grep . | head -n 20)"
    if [ -z "$ev" ]; then ok "$(t 'не знайдено' 'none found')"
    else issue low "$(printf '%s\n' "$ev" | grep -c .)" "$(t 'Секрет у файлі запуску оболонки отримує кожна програма, яку ви запускаєте, - включно зі скриптами встановлення пакетів. Показано лише назви змінних.' 'A secret in a shell startup file is handed to every program you launch - including package install scripts. Only variable names are shown.')" "$ev"; fi
}

c_home_perms() {
    local ev="" m
    m="$(stat -c %a "$AUDIT_HOME" 2>/dev/null)"
    case "$m" in *[1-7]) ev="$AUDIT_HOME: $m ($(t 'доступна іншим користувачам' 'accessible to other users'))"$'\n' ;; esac
    if [ -d "$AUDIT_HOME/.ssh" ]; then m="$(stat -c %a "$AUDIT_HOME/.ssh" 2>/dev/null)"; [ "$m" != 700 ] && ev="$ev~/.ssh: $m ($(t 'має бути 700' 'should be 700'))"$'\n'; fi
    ev="${ev%$'\n'}"
    if [ -z "$ev" ]; then ok "$(t 'закрито' 'private')"
    else issue low "$(printf '%s\n' "$ev" | grep -c .)" "$(t 'Інші облікові записи на цій машині (і зламані служби, що працюють від них) можуть читати ваші файли. Виправити: chmod 750 ~ ; chmod 700 ~/.ssh' 'Other accounts on this machine (and compromised services running as them) can read your files. Fix: chmod 750 ~ ; chmod 700 ~/.ssh')" "$ev"; fi
}

# ---------------------------------------------------------------- devtools

c_npm() {
    have npm || { na "$(t 'npm не знайдено.' 'npm not found.')"; return; }
    local ev="" sev="" major; major="$(npm_major)"
    if [ "$(npmrc ignore-scripts)" = true ]; then ev="✓ ignore-scripts=true"
    else ev="⚠ $(t 'ignore-scripts не задано: кожен пакет виконує свої скрипти під час npm install' 'ignore-scripts is not set: every package runs its scripts during npm install')"; sev=medium; fi
    if [ -n "$(npmrc min-release-age)" ]; then ev="$ev"$'\n'"✓ min-release-age=$(npmrc min-release-age)"
    elif [ -n "$major" ] && [ "$major" -lt 11 ]; then ev="$ev"$'\n'"· $(t "npm $major: затримка для свіжих версій (min-release-age) потребує npm 11+" "npm $major: the release-age cooldown (min-release-age) needs npm 11+")"
    else ev="$ev"$'\n'"⚠ $(t 'min-release-age не задано: встановлюються версії, опубліковані щойно' 'min-release-age is not set: versions published minutes ago get installed')"; [ -z "$sev" ] && sev=low; fi
    if [ -z "$sev" ]; then ok "$(t 'захищено' 'hardened')" "" "$ev"
    else issue "$sev" "$(t 'типові налаштування' 'defaults')" "$(t 'Скрипт встановлення - головний шлях зараження через пакети (хробак Shai-Hulud, підроблені Web3-бібліотеки): він спрацьовує ще до того, як код пакета хтось викличе. Виправити: npm config set ignore-scripts true; npm 11+: npm config set min-release-age 7.' 'An install script is the main infection route through packages (the Shai-Hulud worm, fake Web3 libraries): it fires before anyone calls the package code. Fix: npm config set ignore-scripts true; npm 11+: npm config set min-release-age 7.')" "$ev"; fi
}

c_npm_worm() {
    local roots="" d hits=""
    for d in /usr/lib/node_modules /usr/local/lib/node_modules "$AUDIT_HOME/.npm-global/lib/node_modules" "$AUDIT_HOME"/.nvm/versions/node/*/lib/node_modules "$AUDIT_HOME/.local/share/pnpm/global" "$AUDIT_HOME"/.local/share/fnm/node-versions/*/installation/lib/node_modules; do
        [ -d "$d" ] && roots="$roots$d"$'\n'
    done
    if [ -z "$roots" ]; then na "$(t 'Глобальних пакетів npm не знайдено.' 'No global npm packages found.')"; return; fi
    while IFS= read -r d; do
        [ -n "$d" ] && hits="$hits$(find "$d" -type f \( -name bun_environment.js -size +1024k -o -name setup_bun.js \) 2>/dev/null | head -n 20)"$'\n'
    done <<< "$roots"
    hits="$(printf '%s\n' "$hits" | grep .)"
    [ -d "$AUDIT_HOME/.truffler-cache" ] && hits="$hits${hits:+$'\n'}$AUDIT_HOME/.truffler-cache"
    if [ -n "$hits" ]; then issue critical "Shai-Hulud" "$(t 'Знайдено файли хробака Shai-Hulud (npm, листопад 2025). Вважайте токени GitHub і npm, ключі SSH і хмар з цієї машини викраденими: видаліть заражені пакети і перевипустіть усе з іншого пристрою.' 'Files of the Shai-Hulud worm (npm, November 2025) were found. Treat GitHub and npm tokens, SSH and cloud keys on this machine as stolen: remove the infected packages and reissue everything from another device.')" "$hits"
    else ok "$(t 'слідів немає' 'no traces')" "$(t 'Перевірено лише глобально встановлені пакети, не проєкти.' 'Only globally installed packages were checked, not projects.')"; fi
}

c_agents() {
    local ev=""
    grep -qs '"bypassPermissions"' "$AUDIT_HOME/.claude/settings.json" "$AUDIT_HOME/.claude/settings.local.json" 2>/dev/null && ev="$ev⚠ Claude Code: bypassPermissions"$'\n'
    grep -qsE '^[[:space:]]*sandbox_mode[[:space:]]*=[[:space:]]*"danger-full-access"' "$AUDIT_HOME/.codex/config.toml" && ev="$ev⚠ Codex: sandbox_mode = danger-full-access"$'\n'
    grep -qsE '^[[:space:]]*approval_policy[[:space:]]*=[[:space:]]*"never"' "$AUDIT_HOME/.codex/config.toml" && ev="$ev⚠ Codex: approval_policy = never"$'\n'
    grep -qsE '"chat\.tools(\.global)?\.autoApprove"[[:space:]]*:[[:space:]]*true|"task\.allowAutomaticTasks"[[:space:]]*:[[:space:]]*"on"|"security\.workspace\.trust\.enabled"[[:space:]]*:[[:space:]]*false' "$AUDIT_HOME"/.config/{Code,"Code - Insiders",Cursor,VSCodium}/User/settings.json 2>/dev/null && ev="$ev⚠ $(t 'редактор: автосхвалення інструментів, автозапуск завдань або вимкнена довіра до робочих папок' 'editor: tool auto-approval, automatic tasks or Workspace Trust turned off')"$'\n'
    ev="${ev%$'\n'}"
    if [ -z "$ev" ]; then ok "$(t 'запит перед виконанням' 'asks before running')"
    else issue high "$(printf '%s\n' "$ev" | grep -c .)" "$(t 'ШІ-агент виконує команди без підтвердження. Прихована інструкція в README, коментарі чи відповіді інструмента виконається одразу. Такий режим доречний лише в одноразовій віртуальній машині без ваших ключів.' 'An AI agent runs commands without approval. A hidden instruction in a README, a comment or tool output runs at once. This mode is appropriate only in a disposable VM that holds none of your keys.')" "$ev"; fi
}

# ---------------------------------------------------------------- registry

area system      "$(t 'Система й оновлення' 'System and updates')"
area ssh         "SSH"
area network     "$(t 'Мережа' 'Network')"
area accounts    "$(t 'Облікові записи' 'Accounts')"
area hardening   "$(t 'Посилений захист' 'Hardening')"
area persistence "$(t 'Автозапуск і закріплення' 'Autostart and persistence')"
area secrets     "$(t 'Паролі й секрети' 'Passwords and secrets')"
area devtools    "$(t 'Розробка й ШІ-агенти' 'Development and AI agents')"

check system updates c_updates "$(t 'Оновлення пакетів' 'Package updates')"
check system auto-updates c_auto_updates "$(t 'Автоматичні оновлення безпеки' 'Automatic security updates')"
check system reboot c_reboot "$(t 'Перезавантаження після оновлень' 'Reboot after updates')"
check ssh sshd c_sshd "$(t 'Вхід на сервер SSH' 'SSH server sign-in')"
check ssh ssh-keys c_ssh_keys "$(t 'Ключі SSH без пароля' 'SSH keys without a passphrase')"
check ssh authorized-keys c_authorized_keys "$(t 'Ключі, яким дозволено вхід' 'Keys allowed to sign in')"
check network firewall c_firewall "$(t 'Брандмауер' 'Firewall')"
check network listening-ports c_listening "$(t 'Програми, що приймають з’єднання' 'Programs accepting connections')"
check network proxy-use c_proxy_use "$(t 'Машина як чужий проксі' 'The machine as someone else’s proxy')"
check accounts uid0 c_uid0 "$(t 'Облікові записи з правами root' 'Accounts with root rights')"
check accounts empty-passwords c_empty_passwords "$(t 'Облікові записи без пароля' 'Accounts without a password')"
check accounts sudo c_sudo "$(t 'root без пароля (sudo, docker)' 'Root without a password (sudo, docker)')"
check hardening sysctl c_sysctl "$(t 'Параметри ядра' 'Kernel parameters')"
check hardening mac c_mac "AppArmor / SELinux"
check hardening disk-encryption c_disk_encryption "$(t 'Шифрування диска' 'Disk encryption')"
check hardening secure-boot c_secure_boot "Secure Boot"
check persistence cron c_cron "$(t 'Завдання cron' 'Cron jobs')"
check persistence user-autostart c_user_units "$(t 'Автозапуск користувача' 'User autostart')"
check persistence shell-rc c_shell_rc "$(t 'Файли запуску оболонки' 'Shell startup files')"
check secrets plaintext-tokens c_tokens "$(t 'Токени й ключі у відкритих файлах' 'Tokens and keys in plain-text files')"
check secrets env-secrets c_env_secrets "$(t 'Секрети у змінних середовища' 'Secrets in environment variables')"
check secrets home-permissions c_home_perms "$(t 'Доступ до домашньої папки' 'Home folder permissions')"
check devtools npm c_npm "$(t 'Захист npm' 'npm hardening')"
check devtools npm-worm c_npm_worm "$(t 'Хробак Shai-Hulud у пакетах npm' 'Shai-Hulud worm in npm packages')"
check devtools agent-permissions c_agents "$(t 'Права ШІ-агентів' 'AI agent permissions')"

if [ "$LIST" -eq 1 ]; then
    for i in "${!AREAS[@]}"; do
        printf '%s - %s\n' "${AREAS[$i]}" "${AREA_TITLES[$i]}"
        for c in "${CHECKS[@]}"; do IFS='|' read -r a id _ title <<< "$c"; [ "$a" = "${AREAS[$i]}" ] && printf '  %-20s %s\n' "$id" "$title"; done
    done
    exit 0
fi

for c in "${CHECKS[@]}"; do
    IFS='|' read -r CUR_AREA CUR_ID fn CUR_TITLE <<< "$c"
    [ -n "$ONLY_AREA" ] && [ "$ONLY_AREA" != "$CUR_AREA" ] && continue
    before=${#R_ID[@]}
    "$fn" 2>/dev/null
    # A check that returned nothing must not vanish from the report
    [ ${#R_ID[@]} -eq "$before" ] && unknown "$(t 'Перевірка не повернула результат.' 'The check returned no result.')"
done

# ---------------------------------------------------------------- score and report

# Each finding takes a percentage of what is left (same weights as the Windows audit); a critical caps the score at 39, a high at 79
score_of() { # area or "" for all
    local left=100 i w crit=0 high=0
    for i in "${!R_ID[@]}"; do
        [ -n "$1" ] && [ "${R_AREA[$i]}" != "$1" ] && continue
        [ "${R_STATUS[$i]}" = issue ] || continue
        case "${R_SEV[$i]}" in critical) w=40; crit=1 ;; high) w=15; high=1 ;; medium) w=6 ;; *) w=2 ;; esac
        left=$(( left * (100 - w) / 100 ))
    done
    [ "$crit" -eq 1 ] && [ "$left" -gt 39 ] && left=39
    [ "$crit" -eq 0 ] && [ "$high" -eq 1 ] && [ "$left" -gt 79 ] && left=79
    printf '%s' "$left"
}

if [ -t 1 ]; then C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_CYN=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else C_RED=""; C_YEL=""; C_GRN=""; C_CYN=""; C_DIM=""; C_OFF=""; fi

OS_NAME="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}")"
printf '%s\n' "DEADPIXEL - $(t 'аудит Linux' 'Linux audit') · $(hostname 2>/dev/null) · $OS_NAME · $(uname -r)$([ "$IS_ROOT" -eq 1 ] && printf ' · root')"
for a in "${!AREAS[@]}"; do
    shown=0
    for i in "${!R_ID[@]}"; do
        [ "${R_AREA[$i]}" = "${AREAS[$a]}" ] || continue
        if [ "$shown" -eq 0 ]; then printf '\n%s%s  %s/100%s\n' "$C_CYN" "${AREA_TITLES[$a]}" "$(score_of "${AREAS[$a]}")" "$C_OFF"; shown=1; fi
        case "${R_STATUS[$i]}:${R_SEV[$i]}" in
            issue:critical) tag="$(t 'КРИТ' 'CRIT')"; col="$C_RED" ;; issue:high) tag="$(t 'ВИС ' 'HIGH')"; col="$C_RED" ;;
            issue:medium) tag="$(t 'СЕР ' 'MED ')"; col="$C_YEL" ;; issue:low) tag="$(t 'НИЗ ' 'LOW ')"; col="$C_YEL" ;;
            ok:*) tag=" OK "; col="$C_GRN" ;; info:*) tag="$(t 'ІНФО' 'INFO')"; col="$C_CYN" ;; unknown:*) tag=" ?  "; col="$C_DIM" ;; *) tag=" -  "; col="$C_DIM" ;;
        esac
        printf '  %s[%s]%s %s  %s%s%s\n' "$col" "$tag" "$C_OFF" "${R_TITLE[$i]}" "$C_DIM" "${R_VALUE[$i]}" "$C_OFF"
        case "${R_STATUS[$i]}" in issue|info|unknown)
            [ -n "${R_DETAIL[$i]}" ] && printf '%s\n' "${R_DETAIL[$i]}" | fold -s -w 100 | sed "s/^/         $C_DIM/; s/\$/$C_OFF/"
            [ -n "${R_EV[$i]}" ] && printf '%s\n' "${R_EV[$i]}" | sed 's/^/           /' ;;
        esac
    done
done
SCORE="$(score_of "")"
if [ "$SCORE" -ge 85 ]; then GRADE="$(t 'Добре' 'Good')"; col="$C_GRN"; elif [ "$SCORE" -ge 70 ]; then GRADE="$(t 'Є що покращити' 'Room to improve')"; col="$C_YEL"
elif [ "$SCORE" -ge 40 ]; then GRADE="$(t 'Ризиковано' 'Risky')"; col="$C_YEL"; else GRADE="$(t 'Небезпечно' 'Dangerous')"; col="$C_RED"; fi
printf '\n%s%s: %s/100 - %s%s\n' "$col" "$(t 'Загальна оцінка' 'Overall score')" "$SCORE" "$GRADE" "$C_OFF"
[ "$IS_ROOT" -eq 0 ] && printf '%s%s%s\n' "$C_DIM" "$(t 'Частина перевірок неповна без root: sudo ./audit.sh' 'Some checks are incomplete without root: sudo ./audit.sh')" "$C_OFF"

# ---------------------------------------------------------------- JSON

json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"; s="${s//$'\n'/\\n}"; printf '"%s"' "$s"; }
if [ -n "$JSON_OUT" ]; then
    {
        printf '{\n  "Error": null,\n  "Time": %s,\n  "Host": %s,\n  "Os": %s,\n  "IsAdmin": %s,\n  "Score": %s,\n  "Grade": %s,\n  "Lang": %s,\n  "Results": [\n' \
            "$(json_str "$(date +%Y-%m-%dT%H:%M:%S)")" "$(json_str "$(hostname 2>/dev/null)")" "$(json_str "$OS_NAME")" "$([ "$IS_ROOT" -eq 1 ] && echo true || echo false)" "$SCORE" "$(json_str "$GRADE")" "$(json_str "$UI")"
        for i in "${!R_ID[@]}"; do
            printf '    {"Id": %s, "Area": %s, "Title": %s, "Status": %s, "Severity": %s, "Value": %s, "Detail": %s, "Evidence": [' \
                "$(json_str "${R_ID[$i]}")" "$(json_str "${R_AREA[$i]}")" "$(json_str "${R_TITLE[$i]}")" "$(json_str "${R_STATUS[$i]}")" "$(json_str "${R_SEV[$i]}")" "$(json_str "${R_VALUE[$i]}")" "$(json_str "${R_DETAIL[$i]}")"
            first=1
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                [ "$first" -eq 1 ] || printf ', '
                json_str "$line"; first=0
            done <<< "${R_EV[$i]}"
            printf ']}%s\n' "$([ "$i" -lt $(( ${#R_ID[@]} - 1 )) ] && printf ',')"
        done
        printf '  ]\n}\n'
    } > "$JSON_OUT" && printf '%s%s %s%s\n' "$C_DIM" "$(t 'Звіт JSON:' 'JSON report:')" "$JSON_OUT" "$C_OFF"
fi

# Exit code = number of critical and high findings (0 - none), as in the Windows audit
n=0; for i in "${!R_ID[@]}"; do [ "${R_STATUS[$i]}" = issue ] && case "${R_SEV[$i]}" in critical|high) n=$((n + 1)) ;; esac; done
[ "$n" -gt 254 ] && n=254
exit "$n"
