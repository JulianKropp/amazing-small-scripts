#!/usr/bin/env bash
#
#  NVIDIA driver installer for Debian-based systems.
#
#  Looks for NVIDIA*.run files next to this script, picks the newest one
#  (or lets you choose), prepares the system and runs the installer.
#  If no .run file is found it reports the NVIDIA GPUs in this machine
#  and tells you where to download the driver.
#
#  Usage:  ./install-nvidia-driver.sh [options]
#
set -Eeuo pipefail

# update-grub, update-initramfs & friends live in sbin, which is not on a
# regular user's PATH.
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SELF_VERSION="1.0.0"

# --------------------------------------------------------------------------
#  Options
# --------------------------------------------------------------------------
OPT_YES=0          # assume "yes" for every prompt
OPT_DRYRUN=0       # print commands instead of running them
OPT_FILE=""        # pre-selected .run file
OPT_KEEP_X=0       # do not stop the display manager
OPT_SILENT=0       # run the NVIDIA installer unattended
OPT_NO_VERIFY=0    # skip the archive integrity check
OPT_NO_REBOOT=0    # never offer/perform a reboot
OPT_RESUMED=0      # internal: we are the sudo child, the user already confirmed
OPT_LOCAL=0        # skip the source menu, use a local .run file
OPT_ONLINE=0       # skip the source menu, download from NVIDIA
OPT_COLOR="auto"

usage() {
    cat <<EOF
NVIDIA driver installer ${SELF_VERSION}

  ${SCRIPT_NAME} [options]

Options:
  -f, --file PATH     Install this .run file (skips the search/menu)
  -l, --local         Straight to the local .run files, no source menu
  -o, --online        Straight to the online driver search at NVIDIA
  -y, --yes           Non-interactive: accept every prompt
  -s, --silent        Run the NVIDIA installer unattended (--silent --dkms)
  -k, --keep-x        Do not stop the display manager (installation may fail)
  -n, --dry-run       Show what would happen, change nothing
      --no-verify     Skip the .run archive integrity check
      --no-reboot     Do not offer to reboot at the end
      --no-color      Disable colored output
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)    OPT_FILE="${2:-}"; shift 2 ;;
        -l|--local)   OPT_LOCAL=1; OPT_ONLINE=0; shift ;;
        -o|--online)  OPT_ONLINE=1; OPT_LOCAL=0; shift ;;
        -y|--yes)     OPT_YES=1; shift ;;
        -s|--silent)  OPT_SILENT=1; shift ;;
        -k|--keep-x)  OPT_KEEP_X=1; shift ;;
        -n|--dry-run) OPT_DRYRUN=1; shift ;;
        --no-verify)  OPT_NO_VERIFY=1; shift ;;
        --no-reboot)  OPT_NO_REBOOT=1; shift ;;
        --no-color)   OPT_COLOR="never"; shift ;;
        --resumed)    OPT_RESUMED=1; shift ;;   # internal, set by the sudo re-exec
        -h|--help)    usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------
#  Colors & symbols
# --------------------------------------------------------------------------
setup_colors() {
    local enable=0
    if [[ "$OPT_COLOR" == "auto" ]]; then
        [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]] && enable=1
    fi
    if (( enable )); then
        local e=$'\033'
        C_RESET="${e}[0m"; C_BOLD="${e}[1m"; C_DIM="${e}[2m"
        C_RED="${e}[38;5;203m"; C_YELLOW="${e}[38;5;221m"
        C_BLUE="${e}[38;5;75m";  C_GREY="${e}[38;5;245m"
        if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
            C_NV="${e}[38;2;118;185;0m"        # NVIDIA green
        else
            C_NV="${e}[38;5;112m"
        fi
        C_LINE="$C_GREY"
    else
        C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_YELLOW="" C_BLUE="" C_GREY="" C_NV="" C_LINE=""
    fi
}
setup_colors

S_OK="✔"; S_ERR="✖"; S_WARN="!"; S_INFO="i"; S_ARROW="›"

TERM_COLS="$( { tput cols; } 2>/dev/null || echo 80 )"
(( TERM_COLS < 40 )) && TERM_COLS=40
BOX_W=$(( TERM_COLS < 72 ? TERM_COLS : 72 ))

strip_ansi() {
    local s="$1"
    while [[ "$s" =~ $'\033'\[[0-9\;]*m ]]; do s="${s/"${BASH_REMATCH[0]}"/}"; done
    printf '%s' "$s"
}
vlen() { local s; s="$(strip_ansi "$1")"; printf '%s' "${#s}"; }
repeat() { local ch="$1" n="$2" out=""; while (( n-- > 0 )); do out+="$ch"; done; printf '%s' "$out"; }

box_top()    { printf '%s╭%s╮%s\n' "$C_LINE" "$(repeat ─ $((BOX_W-2)))" "$C_RESET"; }
box_bottom() { printf '%s╰%s╯%s\n' "$C_LINE" "$(repeat ─ $((BOX_W-2)))" "$C_RESET"; }
box_sep()    { printf '%s├%s┤%s\n' "$C_LINE" "$(repeat ─ $((BOX_W-2)))" "$C_RESET"; }
box_line() {
    local text="${1:-}" pad
    pad=$(( BOX_W - 4 - $(vlen "$text") ))
    (( pad < 0 )) && pad=0
    printf '%s│%s %s%s %s│%s\n' "$C_LINE" "$C_RESET" "$text" "$(repeat ' ' "$pad")" "$C_LINE" "$C_RESET"
}
# Shorten a plain (uncolored) string so it still fits into the box.
fit() {
    local s="$1" max="$2"
    (( max < 4 )) && max=4
    if (( ${#s} > max )); then printf '%s…' "${s:0:max-1}"; else printf '%s' "$s"; fi
}
# box_kv <key> <plain value> [color]
box_kv() {
    local key="$1" val="${2:-}" color="${3:-}" kw=18 maxv
    maxv=$(( BOX_W - 4 - kw ))
    box_line "$(printf '%s%-*s%s%s%s%s' "$C_GREY" "$kw" "$key" "$C_RESET" "$color" "$(fit "$val" "$maxv")" "$C_RESET")"
}

say()   { printf '  %s\n' "$*"; }
ok()    { printf '  %s%s%s %s\n' "$C_NV"     "$S_OK"   "$C_RESET" "$*"; }
fail()  { printf '  %s%s%s %s\n' "$C_RED"    "$S_ERR"  "$C_RESET" "$*"; }
warn()  { printf '  %s%s%s %s\n' "$C_YELLOW" "$S_WARN" "$C_RESET" "$*"; }
info()  { printf '  %s%s%s %s\n' "$C_BLUE"   "$S_INFO" "$C_RESET" "$*"; }
hint()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
blank() { printf '\n'; }

STEP_NO=0
STEP_TOTAL=7
step() {
    STEP_NO=$((STEP_NO+1))
    local title="[${STEP_NO}/${STEP_TOTAL}] $1" pad
    pad=$(( TERM_COLS - 6 - ${#title} ))
    (( pad < 0 )) && pad=0
    blank
    printf '%s━━━%s %s%s%s %s%s%s\n' \
        "$C_NV" "$C_RESET" "$C_BOLD" "$title" "$C_RESET" \
        "$C_LINE" "$(repeat ─ "$pad")" "$C_RESET"
}

banner() {
    blank
    if (( TERM_COLS >= 46 )); then
        printf '%s%s' "$C_NV" "$C_BOLD"
        cat <<'ART'
   ███╗   ██╗██╗   ██╗██╗██████╗ ██╗ █████╗
   ████╗  ██║██║   ██║██║██╔══██╗██║██╔══██╗
   ██╔██╗ ██║██║   ██║██║██║  ██║██║███████║
   ██║╚██╗██║╚██╗ ██╔╝██║██║  ██║██║██╔══██║
   ██║ ╚████║ ╚████╔╝ ██║██████╔╝██║██║  ██║
   ╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═════╝ ╚═╝╚═╝  ╚═╝
ART
        printf '%s' "$C_RESET"
    else
        printf '  %s%sNVIDIA%s\n' "$C_NV" "$C_BOLD" "$C_RESET"
    fi
    printf '   %sDriver Installer%s %sv%s%s\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$SELF_VERSION" "$C_RESET"
    blank
}

# --------------------------------------------------------------------------
#  Prompts
# --------------------------------------------------------------------------
# Prompts read from the controlling terminal so that piping something into the
# script does not swallow the answers. Where there is none, stdin has to do.
TTY_IN=""
if { : </dev/tty; } 2>/dev/null; then TTY_IN="/dev/tty"; fi

read_line() {
    local __var="$1" __line=""
    if [[ -n "$TTY_IN" ]]; then
        read -r __line <"$TTY_IN" || __line=""
    else
        read -r __line || __line=""
    fi
    printf -v "$__var" '%s' "$__line"
}

confirm() {
    local prompt="$1" default="${2:-y}" reply hintstr
    (( OPT_YES )) && { info "$prompt ${C_DIM}(auto-yes)${C_RESET}"; return 0; }
    [[ "$default" == "y" ]] && hintstr="[Y/n]" || hintstr="[y/N]"
    while true; do
        printf '  %s%s%s %s %s%s%s ' "$C_NV" "$S_ARROW" "$C_RESET" "$prompt" "$C_DIM" "$hintstr" "$C_RESET"
        read_line reply
        reply="${reply:-$default}"
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

die() { blank; fail "$*"; blank; exit 1; }

# --------------------------------------------------------------------------
#  Command execution (with spinner)
# --------------------------------------------------------------------------
LOG_FILE=""
init_log() {
    LOG_FILE="/var/log/nvidia-driver-installer.log"
    if ! { : >>"$LOG_FILE"; } 2>/dev/null; then
        LOG_FILE="${TMPDIR:-/tmp}/nvidia-driver-installer.log"
        : >>"$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
    fi
    [[ "$LOG_FILE" != /dev/null ]] && printf '\n===== %s =====\n' "$(date -Is)" >>"$LOG_FILE"
}

# run "Description" cmd args...
run() {
    local desc="$1"; shift
    if (( OPT_DRYRUN )); then
        printf '  %s%s%s %s\n' "$C_BLUE" "$S_ARROW" "$C_RESET" "$desc"
        hint "$*"
        return 0
    fi
    [[ "$LOG_FILE" != /dev/null ]] && printf '\n$ %s\n' "$*" >>"$LOG_FILE"

    if [[ ! -t 1 ]]; then
        if "$@" >>"$LOG_FILE" 2>&1; then ok "$desc"; return 0; fi
        fail "$desc"; return 1
    fi

    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 rc=0
    "$@" >>"$LOG_FILE" 2>&1 &
    local pid=$!
    printf '\033[?25l'
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s' "$C_NV" "${frames:i++%10:1}" "$C_RESET" "$desc"
        sleep 0.08
    done
    printf '\033[?25h\r\033[K'
    wait "$pid" || rc=$?
    if (( rc == 0 )); then ok "$desc"; else fail "$desc ${C_DIM}(exit $rc)${C_RESET}"; fi
    return $rc
}

# Same as run(), but keeps the command attached to the terminal.
run_tty() {
    local desc="$1"; shift
    if (( OPT_DRYRUN )); then
        printf '  %s%s%s %s\n' "$C_BLUE" "$S_ARROW" "$C_RESET" "$desc"
        hint "$*"
        return 0
    fi
    [[ "$LOG_FILE" != /dev/null ]] && printf '\n$ %s\n' "$*" >>"$LOG_FILE"
    "$@"
}

show_log_tail() {
    [[ "$LOG_FILE" == /dev/null || ! -s "$LOG_FILE" ]] && return 0
    blank
    say "${C_DIM}last lines of ${LOG_FILE}:${C_RESET}"
    tail -n 12 "$LOG_FILE" | sed "s/^/    ${C_DIM}/;s/\$/${C_RESET}/"
}

# --------------------------------------------------------------------------
#  System inspection
# --------------------------------------------------------------------------
GPU_LIST=()          # human readable GPU names
GPU_IDS=()           # PCI ids, e.g. 10de:2684
DEV_IDS=()           # device ids only, uppercase, e.g. 2684
KERNEL="$(uname -r)"
ARCH="$(uname -m)"
INSTALLED_DRIVER=""
SECUREBOOT="unknown"

detect_gpus() {
    GPU_LIST=(); GPU_IDS=(); DEV_IDS=()
    if command -v lspci >/dev/null 2>&1; then
        local line name id
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            id="$(grep -oE '\[10de:[0-9a-fA-F]{4}\]' <<<"$line" | head -1 | tr -d '[]')"
            # "01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GA107 [10de:25bb] (rev a1)"
            name="$(sed -E 's/^[0-9a-f:.]+ [^:]+: //; s/ \[10de:[0-9a-f]{4}\]//; s/ \(rev [0-9a-f]+\)$//' <<<"$line")"
            GPU_LIST+=("$name")
            GPU_IDS+=("${id:-10de:????}")
            [[ -n "$id" ]] && DEV_IDS+=("$(tr '[:lower:]' '[:upper:]' <<<"${id#10de:}")")
        done < <(lspci -nn 2>/dev/null | grep -Ei '(VGA compatible controller|3D controller|Display controller)' | grep -i 'nvidia' || true)
    fi
    # Fallback: read the PCI bus straight from sysfs.
    if (( ${#GPU_LIST[@]} == 0 )); then
        local d vendor device
        for d in /sys/bus/pci/devices/*; do
            [[ -r "$d/vendor" ]] || continue
            vendor="$(<"$d/vendor")"
            [[ "$vendor" == "0x10de" ]] || continue
            device="$(<"$d/device")"
            GPU_LIST+=("NVIDIA device ${device#0x} (PCI $(basename "$d"))")
            GPU_IDS+=("10de:${device#0x}")
            DEV_IDS+=("$(tr '[:lower:]' '[:upper:]' <<<"${device#0x}")")
        done
    fi
}

detect_installed_driver() {
    if [[ -r /proc/driver/nvidia/version ]]; then
        INSTALLED_DRIVER="$(grep -oE 'Kernel Module +[0-9.]+' /proc/driver/nvidia/version | grep -oE '[0-9.]+' | head -1)"
    fi
    if [[ -z "$INSTALLED_DRIVER" ]] && command -v modinfo >/dev/null 2>&1; then
        INSTALLED_DRIVER="$(modinfo -F version nvidia 2>/dev/null | head -1 || true)"
    fi
}

detect_secureboot() {
    if command -v mokutil >/dev/null 2>&1; then
        case "$(mokutil --sb-state 2>/dev/null)" in
            *enabled*)  SECUREBOOT="enabled" ;;
            *disabled*) SECUREBOOT="disabled" ;;
        esac
    elif [[ -d /sys/firmware/efi ]]; then
        local f
        f="$(echo /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1)"
        if [[ -r "$f" ]]; then
            [[ "$(od -An -t u1 "$f" 2>/dev/null | awk '{print $5}')" == "1" ]] \
                && SECUREBOOT="enabled" || SECUREBOOT="disabled"
        fi
    else
        SECUREBOOT="disabled (legacy BIOS)"
    fi
}

on_real_vt() { [[ "$(tty 2>/dev/null || true)" =~ ^/dev/tty[0-9]+$ ]]; }

display_manager() {
    local unit
    unit="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"
    [[ -n "$unit" && "$unit" != "display-manager.service" ]] && { printf '%s' "$unit"; return; }
    local c
    for c in gdm3 gdm lightdm sddm lxdm xdm nodm ly greetd; do
        if systemctl list-unit-files "${c}.service" >/dev/null 2>&1 \
           && systemctl is-active --quiet "${c}.service"; then
            printf '%s' "${c}.service"; return
        fi
    done
    printf ''
}

# --------------------------------------------------------------------------
#  Driver file discovery
# --------------------------------------------------------------------------
RUN_FILES=()     # sorted, newest driver version first
RUN_VERS=()
RUN_SIZES=()
RUN_DATES=()

file_version() {
    local base; base="$(basename "$1")"
    grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' <<<"$base" | head -1
}

discover_run_files() {
    RUN_FILES=(); RUN_VERS=(); RUN_SIZES=(); RUN_DATES=()
    local raw=() line ver path
    while IFS= read -r line; do
        [[ -n "$line" ]] && raw+=("$line")
    done < <(
        find "$SCRIPT_DIR" -maxdepth 1 -type f -iname 'NVIDIA*.run' -printf '%T@\t%p\n' 2>/dev/null |
        while IFS=$'\t' read -r mtime path; do
            ver="$(file_version "$path")"
            printf '%s\t%s\t%s\n' "${ver:-0}" "$mtime" "$path"
        done | sort -t$'\t' -k1,1Vr -k2,2nr
    )
    for line in "${raw[@]}"; do
        IFS=$'\t' read -r ver _ path <<<"$line"
        RUN_FILES+=("$path")
        RUN_VERS+=("$( [[ "$ver" == "0" ]] && echo "unknown" || echo "$ver" )")
        RUN_SIZES+=("$(du -h --apparent-size "$path" 2>/dev/null | cut -f1)")
        RUN_DATES+=("$(date -r "$path" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '-')")
    done
}

# --------------------------------------------------------------------------
#  Screens
# --------------------------------------------------------------------------
show_system_card() {
    box_top
    box_line "${C_BOLD}System${C_RESET}"
    box_sep
    if (( ${#GPU_LIST[@]} )); then
        local i label
        for i in "${!GPU_LIST[@]}"; do
            (( i == 0 )) && label="GPU" || label=""
            box_kv "$label" "${GPU_LIST[$i]}" "$C_NV"
            box_kv "" "PCI ID ${GPU_IDS[$i]}" "$C_DIM"
        done
    else
        box_kv "GPU" "none detected" "$C_RED"
    fi
    box_kv "Kernel" "$KERNEL ($ARCH)"
    if [[ -d "/lib/modules/$KERNEL/build" ]]; then
        box_kv "Headers" "present" "$C_NV"
    else
        box_kv "Headers" "missing – will be installed" "$C_YELLOW"
    fi
    if [[ -n "$INSTALLED_DRIVER" ]]; then
        box_kv "Loaded driver" "$INSTALLED_DRIVER"
    else
        box_kv "Loaded driver" "none" "$C_DIM"
    fi
    if [[ "$SECUREBOOT" == "enabled" ]]; then
        box_kv "Secure Boot" "enabled" "$C_YELLOW"
    else
        box_kv "Secure Boot" "$SECUREBOOT"
    fi
    box_bottom
}

# --------------------------------------------------------------------------
#  NVIDIA download server
# --------------------------------------------------------------------------
NV_BASE="https://download.nvidia.com/XFree86/Linux-${ARCH}"

# http_get <url> [timeout] -> body on stdout
http_get() {
    local url="$1" t="${2:-15}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time "$t" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout="$t" --tries=1 "$url" 2>/dev/null
    else
        return 127
    fi
}

have_downloader() { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }

# Content-Length of a URL, in bytes ("" when the server does not say).
remote_size() {
    local url="$1" len=""
    if command -v curl >/dev/null 2>&1; then
        len="$(curl -fsIL --max-time 15 "$url" 2>/dev/null \
               | grep -i '^content-length:' | tail -1 | tr -dc '0-9' || true)"
    elif command -v wget >/dev/null 2>&1; then
        len="$(wget --spider -S --timeout=15 "$url" 2>&1 \
               | grep -i 'content-length:' | tail -1 | tr -dc '0-9' || true)"
    fi
    printf '%s' "$len"
}

human_size() {
    local b="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$b"
    else
        awk -v b="$b" 'BEGIN{ printf "%.0f MB", b/1048576 }'
    fi
}

# The newest production ("stable") release, e.g. 580.126.09
latest_stable_version() {
    http_get "${NV_BASE}/latest.txt" 8 | head -1 | awk '{print $1}'
}

# --------------------------------------------------------------------------
#  Online driver search
# --------------------------------------------------------------------------
ONLINE_VERS=()      # driver versions that support this GPU, newest first
ONLINE_NAMES=()     # the GPU name as that driver calls it
ONLINE_STABLE=""    # version from latest.txt
ONLINE_DEFAULT=0    # index of the entry preselected in the menu

# Does driver <version> support one of this machine's GPUs?
# Prints the marketing name on success.
version_supports_gpu() {
    local ver="$1" html id name
    html="$(http_get "${NV_BASE}/${ver}/README/supportedchips.html" 25)" || return 1
    [[ -n "$html" ]] || return 1
    for id in "${DEV_IDS[@]}"; do
        # <tr id="devid25BB"> <td>NVIDIA RTX A500 Laptop GPU</td> <td>25BB</td>
        name="$(grep -A1 -i "id=\"devid${id}\"" <<<"$html" \
                | sed -n 's:.*<td>\([^<]*\)</td>.*:\1:p' | head -1 || true)"
        [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
        if grep -qiE ">${id}</td>" <<<"$html"; then printf 'supported'; return 0; fi
    done
    return 1
}

# All driver versions the archive offers for this architecture, newest first.
fetch_version_index() {
    http_get "${NV_BASE}/" 20 \
        | grep -oE "href='[0-9]+\.[0-9]+(\.[0-9]+)?/'" \
        | tr -d "href='/" \
        | grep -E '^[0-9]{3}\.' \
        | sort -Vr
}

# Fills ONLINE_VERS / ONLINE_NAMES. Returns 1 when nothing usable was found.
online_search() {
    ONLINE_VERS=(); ONLINE_NAMES=(); ONLINE_DEFAULT=0

    if ! have_downloader; then
        blank
        fail "Neither curl nor wget is installed – an online search is not possible."
        hint "sudo apt-get install curl"
        return 1
    fi

    blank
    say "${C_BOLD}Searching drivers on download.nvidia.com${C_RESET}"
    blank

    ONLINE_STABLE="$(latest_stable_version || true)"
    if [[ -z "$ONLINE_STABLE" ]]; then
        fail "No connection to download.nvidia.com."
        hint "Check your internet connection, proxy or DNS and try again."
        hint "Test: curl -I ${NV_BASE}/latest.txt"
        return 1
    fi
    ok "Connected ${C_DIM}·${C_RESET} newest stable release: ${C_NV}${C_BOLD}${ONLINE_STABLE}${C_RESET}"

    local all=()
    mapfile -t all < <(fetch_version_index || true)
    if (( ${#all[@]} == 0 )); then
        fail "The driver index could not be read."
        hint "${NV_BASE}/ did not return a usable listing."
        return 1
    fi
    ok "${#all[@]} driver releases available for ${ARCH}"

    if (( ${#DEV_IDS[@]} == 0 )); then
        warn "No NVIDIA GPU detected – showing the newest releases unfiltered."
        local v
        for v in "${all[@]:0:12}"; do ONLINE_VERS+=("$v"); ONLINE_NAMES+=("not checked"); done
        pick_online_default
        return 0
    fi

    # Checking a release means downloading its supported-GPU table, so only
    # look at a window of candidates and widen it if nothing matches. The
    # stable release is always part of the window – it is the default.
    local window=13 offset=0 round v batch=()
    for round in 1 2; do
        batch=()
        [[ -n "$ONLINE_STABLE" && $round -eq 1 ]] && batch+=("$ONLINE_STABLE")
        for v in "${all[@]:offset:window}"; do
            [[ "$v" == "$ONLINE_STABLE" ]] || batch+=("$v")
        done
        (( ${#batch[@]} == 0 )) && break
        mapfile -t batch < <(printf '%s\n' "${batch[@]}" | sort -Vr)
        scan_versions "${batch[@]}"
        (( ${#ONLINE_VERS[@]} > 0 )) && break
        offset=$(( offset + window ))
        (( round == 1 )) && { blank; warn "None of the newest releases support your GPU – looking further back."; }
    done

    if (( ${#ONLINE_VERS[@]} == 0 )); then
        blank
        fail "No driver found that supports ${GPU_LIST[0]:-your GPU} (${DEV_IDS[0]:-?})."
        hint "Older cards need a legacy branch:"
        hint "  https://www.nvidia.com/en-us/drivers/unix/legacy-gpu/"
        return 1
    fi
    pick_online_default
    return 0
}

# Check a batch of versions in parallel and append the supported ones.
scan_versions() {
    local vers=("$@")
    local tmp v pids=() done_n=0 total=${#vers[@]}
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    local i chunk=6
    for (( i=0; i<total; i+=chunk )); do
        pids=()
        for v in "${vers[@]:i:chunk}"; do
            ( version_supports_gpu "$v" >"$tmp/$v" 2>/dev/null || rm -f "$tmp/$v" ) &
            pids+=($!)
        done
        if [[ -t 1 ]]; then
            local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' f=0
            while kill -0 "${pids[0]}" 2>/dev/null; do
                printf '\r  %s%s%s Checking GPU support %s(%d/%d)%s' \
                    "$C_NV" "${frames:f++%10:1}" "$C_RESET" "$C_DIM" "$done_n" "$total" "$C_RESET"
                sleep 0.08
            done
        fi
        wait "${pids[@]}" 2>/dev/null || true
        done_n=$(( done_n + ${#pids[@]} ))
    done
    [[ -t 1 ]] && printf '\r\033[K'

    for v in "${vers[@]}"; do
        if [[ -s "$tmp/$v" ]]; then
            ONLINE_VERS+=("$v")
            ONLINE_NAMES+=("$(<"$tmp/$v")")
        fi
    done
    ok "Checked ${total} releases ${C_DIM}·${C_RESET} ${#ONLINE_VERS[@]} support your GPU"
}

# Put the newest stable release first – that is the default – and keep the
# remaining releases in descending version order behind it.
pick_online_default() {
    local i stable_i=-1
    local nv=() nn=()
    for i in "${!ONLINE_VERS[@]}"; do
        if [[ "${ONLINE_VERS[$i]}" == "$ONLINE_STABLE" ]]; then
            nv+=("${ONLINE_VERS[$i]}"); nn+=("${ONLINE_NAMES[$i]}"); stable_i=$i; break
        fi
    done
    for i in "${!ONLINE_VERS[@]}"; do
        (( i == stable_i )) && continue
        nv+=("${ONLINE_VERS[$i]}"); nn+=("${ONLINE_NAMES[$i]}")
    done
    ONLINE_VERS=("${nv[@]}"); ONLINE_NAMES=("${nn[@]}")
    ONLINE_DEFAULT=0
}

# Menu over the search results; sets ONLINE_PICK.
ONLINE_PICK=""
online_select() {
    local n=${#ONLINE_VERS[@]} def=$(( ONLINE_DEFAULT + 1 )) i marker tag

    blank
    say "${C_BOLD}Drivers for ${GPU_LIST[0]:-your GPU}${C_RESET}"
    blank
    for i in "${!ONLINE_VERS[@]}"; do
        if (( i == ONLINE_DEFAULT )); then marker="${C_NV}${S_ARROW}${C_RESET}"; else marker=" "; fi
        if [[ "${ONLINE_VERS[$i]}" == "$ONLINE_STABLE" ]]; then
            tag="${C_NV}stable${C_RESET}"
        elif [[ -n "$ONLINE_STABLE" ]] \
             && [[ "$(printf '%s\n%s\n' "${ONLINE_VERS[$i]}" "$ONLINE_STABLE" | sort -Vr | head -1)" == "${ONLINE_VERS[$i]}" ]]; then
            tag="${C_YELLOW}beta branch${C_RESET}"
        else
            tag="${C_DIM}older${C_RESET}"
        fi
        printf '  %s %s%2d)%s %s%-12s%s  %-14s %s%s%s\n' \
            "$marker" "$C_BOLD" "$((i+1))" "$C_RESET" \
            "$C_NV" "${ONLINE_VERS[$i]}" "$C_RESET" \
            "$tag" "$C_DIM" "${ONLINE_NAMES[$i]}" "$C_RESET"
    done
    blank
    if [[ "${ONLINE_VERS[$ONLINE_DEFAULT]}" == "$ONLINE_STABLE" ]]; then
        say "${C_DIM}Entry ${def} is the newest stable release – press Enter to take it.${C_RESET}"
    else
        say "${C_DIM}Entry ${def} is the newest release – press Enter to take it.${C_RESET}"
    fi
    say "${C_DIM}\"beta branch\" releases are newer than stable but less tested.${C_RESET}"
    blank

    if (( OPT_YES )); then
        ONLINE_PICK="${ONLINE_VERS[$ONLINE_DEFAULT]}"
        info "Auto-selected ${C_BOLD}${ONLINE_PICK}${C_RESET}"
        return 0
    fi

    local choice
    while true; do
        printf '  %s%s%s Select driver %s[1-%d, default %d]%s ' \
            "$C_NV" "$S_ARROW" "$C_RESET" "$C_DIM" "$n" "$def" "$C_RESET"
        read_line choice
        choice="${choice:-$def}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            ONLINE_PICK="${ONLINE_VERS[$((choice-1))]}"
            return 0
        fi
        warn "Please enter a number between 1 and ${n}."
    done
}

# Download the selected release next to this script; sets SELECTED.
DL_PART=""
download_driver() {
    local ver="$1"
    local file="NVIDIA-Linux-${ARCH}-${ver}.run"
    local url="${NV_BASE}/${ver}/${file}"
    local dest="${SCRIPT_DIR}/${file}"

    blank
    if [[ -f "$dest" ]]; then
        info "${file} is already in this folder."
        if confirm "Use the existing file?" y; then
            SELECTED="$dest"; SELECTED_VER="$ver"; return 0
        fi
    fi

    if (( OPT_DRYRUN )); then
        info "Dry run – the driver would be downloaded now:"
        say "    ${C_DIM}from ${url}${C_RESET}"
        say "    ${C_DIM}to   ${dest}${C_RESET}"
        blank
        ok "Nothing was downloaded, nothing was changed."
        blank
        exit 0
    fi

    [[ -w "$SCRIPT_DIR" ]] || die "No write permission in ${SCRIPT_DIR}."

    local bytes size="unknown size"
    bytes="$(remote_size "$url")"
    [[ -n "$bytes" ]] && size="$(human_size "$bytes")"
    info "Download size: ${C_BOLD}${size}${C_RESET}"
    confirm "Download now?" y || die "Aborted by the user."

    blank
    say "${C_BOLD}Downloading${C_RESET} ${C_DIM}${file}${C_RESET}"

    DL_PART="${dest}.part"
    trap 'rm -f "$DL_PART"; if [[ -t 1 ]]; then printf "\033[?25h"; fi; exit 130' INT TERM
    local rc=0
    if command -v curl >/dev/null 2>&1; then
        if [[ -t 1 ]]; then
            curl -fL --progress-bar -o "$DL_PART" "$url" || rc=$?
        else
            curl -fsSL -o "$DL_PART" "$url" || rc=$?
        fi
    else
        if [[ -t 1 ]]; then
            wget -q --show-progress -O "$DL_PART" "$url" || rc=$?
        else
            wget -q -O "$DL_PART" "$url" || rc=$?
        fi
    fi
    trap 'if [[ -t 1 ]]; then printf "\033[?25h"; fi' INT TERM

    if (( rc != 0 )); then
        rm -f "$DL_PART"
        blank
        fail "Download failed (exit ${rc})."
        hint "$url"
        hint "Check your connection and try again, or download the file by hand."
        exit 1
    fi

    mv "$DL_PART" "$dest"
    DL_PART=""
    chmod +x "$dest" 2>/dev/null || true
    blank
    ok "Saved: ${C_BOLD}${file}${C_RESET} ($(du -h "$dest" | cut -f1))"
    SELECTED="$dest"; SELECTED_VER="$ver"
}

# Shown when no .run file was found next to the script.
show_download_help() {
    local url_arch="${NV_BASE}/"
    local latest="" latest_ver="" latest_url=""
    latest="$(http_get "${url_arch}latest.txt" 6 | head -1 || true)"
    # latest.txt holds e.g. "580.126.09 580.126.09/NVIDIA-Linux-x86_64-580.126.09.run"
    if [[ -n "$latest" ]]; then
        latest_ver="$(awk '{print $1}' <<<"$latest")"
        latest_url="${url_arch}$(awk '{print $2}' <<<"$latest")"
    fi

    blank
    box_top
    box_line "${C_YELLOW}No NVIDIA*.run file found${C_RESET}"
    box_sep
    box_line "Searched in:"
    box_line "  ${C_DIM}$(fit "$SCRIPT_DIR" $((BOX_W-6)))${C_RESET}"
    box_bottom
    blank

    if (( ${#GPU_LIST[@]} )); then
        say "${C_BOLD}NVIDIA hardware in this machine${C_RESET}"
        local i
        for i in "${!GPU_LIST[@]}"; do
            ok "${GPU_LIST[$i]} ${C_DIM}[${GPU_IDS[$i]}]${C_RESET}"
        done
    else
        warn "No NVIDIA GPU detected on the PCI bus."
        hint "Nothing to install here – check the hardware first."
        command -v lspci >/dev/null 2>&1 || hint "Tip: install 'pciutils' for better detection (sudo apt-get install pciutils)."
    fi

    blank
    say "${C_BOLD}Where to get the driver${C_RESET}"
    if [[ -n "$latest_ver" ]]; then
        info "Latest production driver for ${ARCH}: ${C_NV}${C_BOLD}${latest_ver}${C_RESET}"
        say "  ${C_BLUE}${latest_url}${C_RESET}"
        blank
        say "  ${C_DIM}Download it straight into this folder:${C_RESET}"
        say "  ${C_DIM}wget -P '${SCRIPT_DIR}' '${latest_url}'${C_RESET}"
    else
        info "Driver search page:"
        say "  ${C_BLUE}https://www.nvidia.com/en-us/drivers/${C_RESET}"
        info "All Unix drivers for ${ARCH}:"
        say "  ${C_BLUE}${url_arch}${C_RESET}"
    fi
    blank
    say "  ${C_DIM}Driver search page ....... https://www.nvidia.com/en-us/drivers/${C_RESET}"
    say "  ${C_DIM}Unix driver archive ...... https://www.nvidia.com/en-us/drivers/unix/${C_RESET}"
    blank
    info "Put the .run file next to this script and run it again."
    blank
}

SELECTED=""
SELECTED_VER=""

# --------------------------------------------------------------------------
#  Where does the driver come from?
# --------------------------------------------------------------------------
SOURCE_PICK=""
source_menu() {
    local n=${#RUN_FILES[@]} def=1 choice
    (( n == 0 )) && def=2

    blank
    say "${C_BOLD}Where should the driver come from?${C_RESET}"
    blank
    local m1=" " m2=" "
    if (( def == 1 )); then m1="${C_NV}${S_ARROW}${C_RESET}"; else m2="${C_NV}${S_ARROW}${C_RESET}"; fi

    printf '  %s %s1)%s Install from a local .run file\n' "$m1" "$C_BOLD" "$C_RESET"
    if (( n == 0 )); then
        printf '       %sno .run file in this folder%s\n' "$C_DIM" "$C_RESET"
    elif (( n == 1 )); then
        printf '       %s%s%s\n' "$C_DIM" "$(basename "${RUN_FILES[0]}")" "$C_RESET"
    else
        printf '       %s%d packages found – newest: %s%s\n' "$C_DIM" "$n" "${RUN_VERS[0]}" "$C_RESET"
    fi
    printf '  %s %s2)%s Search online at NVIDIA and download\n' "$m2" "$C_BOLD" "$C_RESET"
    printf '       %sdrivers for %s%s\n' "$C_DIM" "${GPU_LIST[0]:-your GPU}" "$C_RESET"
    printf '    %s3)%s Quit\n' "$C_BOLD" "$C_RESET"
    blank

    if (( OPT_YES )); then
        info "Auto-selected option ${def}"
        SOURCE_PICK="$def"; return 0
    fi

    while true; do
        printf '  %s%s%s Your choice %s[1-3, default %d]%s ' \
            "$C_NV" "$S_ARROW" "$C_RESET" "$C_DIM" "$def" "$C_RESET"
        read_line choice
        choice="${choice:-$def}"
        case "$choice" in
            1|2|3) SOURCE_PICK="$choice"; return 0 ;;
            *) warn "Please enter 1, 2 or 3." ;;
        esac
    done
}

# Runs the source menu until a driver package is selected.
choose_driver() {
    local pick
    while true; do
        if (( OPT_ONLINE )); then
            pick=2
        elif (( OPT_LOCAL )); then
            pick=1
        else
            source_menu
            pick="$SOURCE_PICK"
        fi

        case "$pick" in
            1)
                if (( ${#RUN_FILES[@]} == 0 )); then
                    blank
                    warn "There is no NVIDIA*.run file in ${SCRIPT_DIR}."
                    (( OPT_LOCAL )) && { show_download_help; exit 1; }
                    hint "Choose option 2 to download one, or copy a file into this folder."
                    continue
                fi
                select_run_file
                return 0
                ;;
            2)
                if ! online_search; then
                    (( OPT_ONLINE )) && exit 1
                    blank
                    hint "Option 1 still works if you copy a .run file into this folder."
                    confirm "Back to the menu?" y || exit 1
                    continue
                fi
                online_select
                download_driver "$ONLINE_PICK"
                return 0
                ;;
            3)
                blank; ok "Cancelled."; blank; exit 0 ;;
        esac
    done
}

select_run_file() {
    local n="${#RUN_FILES[@]}"

    if (( n == 1 )); then
        SELECTED="${RUN_FILES[0]}"; SELECTED_VER="${RUN_VERS[0]}"
        blank
        ok "Found one driver package – continuing automatically."
        return 0
    fi

    blank
    say "${C_BOLD}${n} driver packages found${C_RESET} ${C_DIM}in ${SCRIPT_DIR}${C_RESET}"
    blank
    local i base fw=0
    for i in "${!RUN_FILES[@]}"; do
        base="$(basename "${RUN_FILES[$i]}")"
        (( ${#base} > fw )) && fw=${#base}
    done
    local marker note
    for i in "${!RUN_FILES[@]}"; do
        base="$(basename "${RUN_FILES[$i]}")"
        if (( i == 0 )); then marker="${C_NV}${S_ARROW}${C_RESET}"; else marker=" "; fi
        note=""
        [[ "$base" != *"$ARCH"* ]] && note="  ${C_YELLOW}not ${ARCH}${C_RESET}"
        printf '  %s %s%d)%s %s%-12s%s %s%-*s  %6s  %s%s%s\n' \
            "$marker" "$C_BOLD" "$((i+1))" "$C_RESET" \
            "$C_NV" "${RUN_VERS[$i]}" "$C_RESET" \
            "$C_DIM" "$fw" "$base" \
            "${RUN_SIZES[$i]}" "${RUN_DATES[$i]}" "$C_RESET" "$note"
    done
    blank
    say "${C_DIM}1) is the newest version – press Enter to take it.${C_RESET}"
    blank

    if (( OPT_YES )); then
        SELECTED="${RUN_FILES[0]}"; SELECTED_VER="${RUN_VERS[0]}"
        info "Auto-selected ${C_BOLD}${SELECTED_VER}${C_RESET}"
        return 0
    fi

    local choice
    while true; do
        printf '  %s%s%s Select driver %s[1-%d, default 1]%s ' \
            "$C_NV" "$S_ARROW" "$C_RESET" "$C_DIM" "$n" "$C_RESET"
        read_line choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            SELECTED="${RUN_FILES[$((choice-1))]}"
            SELECTED_VER="${RUN_VERS[$((choice-1))]}"
            return 0
        fi
        warn "Please enter a number between 1 and ${n}."
    done
}

show_plan() {
    blank
    box_top
    box_line "${C_BOLD}Installation plan${C_RESET}"
    box_sep
    box_kv "Package" "$(basename "$SELECTED")" "$C_NV"
    box_kv "Version" "$SELECTED_VER"
    [[ -n "$INSTALLED_DRIVER" ]] && box_kv "Replaces" "$INSTALLED_DRIVER"
    box_kv "Kernel" "$KERNEL"
    if (( OPT_DRYRUN )); then
        box_kv "Mode" "dry run" "$C_YELLOW"
    elif (( OPT_SILENT )); then
        box_kv "Mode" "unattended"
    else
        box_kv "Mode" "interactive"
    fi
    box_sep
    box_line "${C_DIM}1. verify the driver package${C_RESET}"
    box_line "${C_DIM}2. blacklist the nouveau driver${C_RESET}"
    box_line "${C_DIM}3. patch the GRUB kernel command line${C_RESET}"
    box_line "${C_DIM}4. install build dependencies${C_RESET}"
    box_line "${C_DIM}5. stop the graphical session${C_RESET}"
    box_line "${C_DIM}6. run the NVIDIA installer${C_RESET}"
    box_line "${C_DIM}7. verify and reboot${C_RESET}"
    box_bottom
    blank
}

# --------------------------------------------------------------------------
#  Installation steps
# --------------------------------------------------------------------------
step_verify_package() {
    step "Verifying the driver package"
    local size_mb
    size_mb=$(( $(stat -c '%s' "$SELECTED") / 1024 / 1024 ))
    if (( size_mb < 20 )); then
        die "'$(basename "$SELECTED")' is only ${size_mb} MB – that is not a complete driver package."
    fi
    ok "Size looks sane (${size_mb} MB)"

    chmod +x "$SELECTED" 2>/dev/null || true

    if (( OPT_NO_VERIFY )); then
        info "Integrity check skipped (--no-verify)"
    else
        if ! run "Checking archive integrity (this takes a moment)" bash "$SELECTED" --check; then
            show_log_tail
            die "The archive is corrupt. Download it again."
        fi
    fi
}

step_blacklist_nouveau() {
    step "Blacklisting the nouveau driver"

    if (( OPT_DRYRUN )); then
        info "Would write /etc/modprobe.d/blacklist-nouveau.conf"
    else
        cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
# Written by install-nvidia-driver.sh
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF
        ok "Wrote /etc/modprobe.d/blacklist-nouveau.conf"
    fi

    if lsmod 2>/dev/null | grep -q '^nouveau'; then
        warn "nouveau is currently loaded – it will be gone after the reboot."
    else
        ok "nouveau is not loaded"
    fi

    if command -v update-initramfs >/dev/null 2>&1; then
        run "Rebuilding the initramfs" update-initramfs -u || die "update-initramfs failed."
    elif command -v dracut >/dev/null 2>&1; then
        run "Rebuilding the initramfs (dracut)" dracut --force || die "dracut failed."
    else
        warn "No initramfs tool found – skipping."
    fi
}

step_patch_grub() {
    step "Patching the GRUB kernel command line"
    local grubfile=/etc/default/grub
    local params="nouveau.modeset=0 modprobe.blacklist=nouveau"

    if [[ ! -f "$grubfile" ]]; then
        warn "$grubfile does not exist – skipping (no GRUB on this system?)."
        return 0
    fi

    # Only look at the active (uncommented) line, not at old commented-out ones.
    local current missing=() p
    current="$(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX=' "$grubfile" | tail -1 || true)"
    for p in $params; do
        [[ "$current" == *"$p"* ]] || missing+=("$p")
    done

    if (( ${#missing[@]} == 0 )); then
        ok "GRUB already carries the nouveau parameters"
        return 0
    fi

    if (( OPT_DRYRUN )); then
        info "Would add to GRUB_CMDLINE_LINUX: ${missing[*]}"
    else
        cp -a "$grubfile" "${grubfile}.bak.$(date +%Y%m%d%H%M%S)"
        ok "Backed up ${grubfile}"
        if grep -q '^GRUB_CMDLINE_LINUX=' "$grubfile"; then
            sed -i "s|^GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 ${missing[*]}\"|" "$grubfile"
        else
            printf '\nGRUB_CMDLINE_LINUX="%s"\n' "${missing[*]}" >>"$grubfile"
        fi
        ok "Added: ${missing[*]}"
    fi

    if command -v update-grub >/dev/null 2>&1; then
        run "Regenerating the GRUB config" update-grub || die "update-grub failed."
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        run "Regenerating the GRUB config" grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig failed."
    else
        warn "Neither update-grub nor grub-mkconfig found – skipping."
    fi
}

step_dependencies() {
    step "Installing build dependencies"
    local pkgs=("linux-headers-${KERNEL}" build-essential make gcc acpid dkms libglvnd-dev pkg-config)

    if ! command -v apt-get >/dev/null 2>&1; then
        warn "apt-get not available – install the kernel headers yourself."
        return 0
    fi

    run "Updating the package index" apt-get update || warn "apt-get update reported problems – continuing."

    if ! run "Installing ${pkgs[0]} and build tools" \
              env DEBIAN_FRONTEND=noninteractive apt-get -y install "${pkgs[@]}"; then
        warn "Not every package could be installed – retrying without the exact headers."
        run "Installing generic build tools" \
            env DEBIAN_FRONTEND=noninteractive apt-get -y install build-essential make gcc acpid dkms \
            || die "Dependency installation failed."
    fi

    if (( ! OPT_DRYRUN )) && [[ ! -d "/lib/modules/${KERNEL}/build" ]]; then
        warn "No headers for the running kernel (${KERNEL})."
        hint "Your installed kernel is probably newer than the running one."
        confirm "Reboot now and start this script again afterwards?" n && run_tty "Rebooting" systemctl reboot
        die "Kernel headers for ${KERNEL} are missing – aborting."
    fi
    ok "Kernel headers for ${KERNEL} are in place"
}

DM_UNIT=""
step_stop_display_manager() {
    step "Stopping the graphical session"

    if (( OPT_KEEP_X )); then
        warn "Keeping the display manager alive (--keep-x) – the installer may refuse to run."
        return 0
    fi

    DM_UNIT="$(display_manager)"
    if [[ -z "$DM_UNIT" ]]; then
        ok "No active display manager found"
    else
        info "Active display manager: ${C_BOLD}${DM_UNIT}${C_RESET}"
    fi

    if ! on_real_vt; then
        blank
        warn "You are running inside a graphical terminal."
        hint "Stopping the display manager would kill this window and the installation with it."
        hint "Switch to a text console with Ctrl+Alt+F3, log in there and run:"
        hint "  sudo ${SCRIPT_PATH}"
        blank
        if ! confirm "Continue anyway (not recommended)?" n; then
            die "Aborted. Please restart the script from a text console."
        fi
    fi

    run "Switching to multi-user.target" systemctl isolate multi-user.target \
        || warn "Could not switch the target – continuing."
    sleep 2 || true
}

step_run_installer() {
    step "Running the NVIDIA installer"
    local args=()

    # Expert mode when the kernel enforces module signatures – the installer
    # then offers to generate and enroll a signing key.
    if [[ -r "/boot/config-${KERNEL}" ]] \
       && grep -q '^CONFIG_MODULE_SIG=y' "/boot/config-${KERNEL}" \
       && grep -q '# CONFIG_MODULE_SIG_FORCE is not set' "/boot/config-${KERNEL}"; then
        args+=(-e)
        info "Kernel module signing detected – starting the installer in expert mode."
    fi
    if [[ "$SECUREBOOT" == "enabled" ]]; then
        warn "Secure Boot is enabled."
        hint "Let the installer generate a key pair and enroll it via MOK, or"
        hint "disable Secure Boot in the UEFI setup – otherwise the module will not load."
    fi

    if (( OPT_SILENT )); then
        args+=(--silent --dkms)
        info "Unattended installation"
    else
        blank
        box_top
        box_line "${C_BOLD}Answers for the installer dialog${C_RESET}"
        box_sep
        box_line "Sign the kernel module ....... ${C_NV}Yes${C_RESET} / Generate a new key pair"
        box_line "Install 32-bit libraries ..... ${C_NV}Yes${C_RESET} (needed for Steam & Wine)"
        box_line "Register with DKMS ........... ${C_NV}Yes${C_RESET} (survives kernel updates)"
        box_line "Update your X configuration .. ${C_RED}No${C_RESET}"
        box_bottom
        blank
        confirm "Start the installer now?" y || die "Aborted by the user."
    fi

    blank
    if ! run_tty "NVIDIA installer" bash "$SELECTED" "${args[@]}"; then
        blank
        fail "The NVIDIA installer exited with an error."
        hint "Full log: /var/log/nvidia-installer.log"
        blank
        say "  ${C_BOLD}Common causes${C_RESET}"
        say "  ${C_DIM}• kernel headers do not match the running kernel → reboot, run again${C_RESET}"
        say "  ${C_DIM}• leftover packages → dpkg -l | grep -E 'nvidia|cuda', then apt-get purge${C_RESET}"
        say "  ${C_DIM}• Secure Boot → enroll the MOK key or disable Secure Boot${C_RESET}"
        blank
        exit 1
    fi
    ok "Driver installed"
}

step_verify_and_reboot() {
    step "Verification"

    if (( OPT_DRYRUN )); then
        info "Would run nvidia-smi and offer a reboot."
        return 0
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            ok "nvidia-smi works"
            blank
            nvidia-smi || true
        else
            info "nvidia-smi cannot talk to the driver yet – normal before the reboot."
        fi
    else
        warn "nvidia-smi was not installed."
    fi

    blank
    box_top
    box_line "${C_NV}${C_BOLD}Installation finished${C_RESET}"
    box_sep
    box_line "A reboot is required to load the new kernel module"
    box_line "and to bring the graphical session back up."
    box_bottom
    blank

    if (( OPT_NO_REBOOT )); then
        info "Reboot skipped (--no-reboot). Run 'sudo reboot' when you are ready."
        return 0
    fi
    if confirm "Reboot now?" y; then
        say "${C_DIM}Rebooting…${C_RESET}"
        systemctl reboot
    else
        info "Remember to reboot later: ${C_BOLD}sudo reboot${C_RESET}"
        [[ -n "$DM_UNIT" ]] && hint "Or bring the desktop back with: sudo systemctl isolate graphical.target"
    fi
}

# --------------------------------------------------------------------------
#  Main
# --------------------------------------------------------------------------
trap 'if [[ -t 1 ]]; then printf "\033[?25h"; fi' EXIT

main() {
    (( OPT_RESUMED )) || banner
    detect_gpus
    detect_installed_driver
    detect_secureboot
    (( OPT_RESUMED )) || show_system_card

    if [[ -n "$OPT_FILE" ]]; then
        [[ -f "$OPT_FILE" ]] || die "File not found: $OPT_FILE"
        SELECTED="$(readlink -f "$OPT_FILE")"
        SELECTED_VER="$(file_version "$SELECTED")"
        SELECTED_VER="${SELECTED_VER:-unknown}"
    else
        discover_run_files
        choose_driver
    fi

    if (( ! OPT_RESUMED )); then
        if (( ${#GPU_LIST[@]} == 0 )); then
            blank
            warn "No NVIDIA GPU was detected on the PCI bus."
            command -v lspci >/dev/null 2>&1 || hint "'pciutils' is missing, detection may be incomplete."
            confirm "Install the driver anyway?" n || die "Aborted – no NVIDIA hardware found."
        fi

        if [[ -n "$INSTALLED_DRIVER" && "$INSTALLED_DRIVER" == "$SELECTED_VER" ]]; then
            blank
            info "Driver ${C_BOLD}${SELECTED_VER}${C_RESET} is already loaded."
            confirm "Reinstall it?" n || { blank; ok "Nothing to do."; blank; exit 0; }
        fi

        show_plan
        (( OPT_DRYRUN )) && warn "DRY RUN – nothing will be changed."
        confirm "Start the installation?" y || { blank; ok "Aborted."; blank; exit 0; }

        # Everything below this point needs root.
        if (( EUID != 0 && ! OPT_DRYRUN )); then
            command -v sudo >/dev/null 2>&1 \
                || die "Root privileges are required – please run this script as root."
            blank
            info "Root privileges are required – asking sudo."
            local fwd=(--resumed --file "$SELECTED")
            (( OPT_YES ))       && fwd+=(--yes)
            (( OPT_SILENT ))    && fwd+=(--silent)
            (( OPT_KEEP_X ))    && fwd+=(--keep-x)
            (( OPT_NO_VERIFY )) && fwd+=(--no-verify)
            (( OPT_NO_REBOOT )) && fwd+=(--no-reboot)
            [[ "$OPT_COLOR" == "never" ]] && fwd+=(--no-color)
            exec sudo -- "$SCRIPT_PATH" "${fwd[@]}"
        fi
    else
        blank
        say "${C_NV}${C_BOLD}NVIDIA${C_RESET} ${SELECTED_VER} ${C_DIM}·${C_RESET} running as root"
    fi

    init_log
    [[ "$LOG_FILE" != /dev/null ]] && hint "Log: $LOG_FILE"

    step_verify_package
    step_blacklist_nouveau
    step_patch_grub
    step_dependencies
    step_stop_display_manager
    step_run_installer
    step_verify_and_reboot
    blank
}

main "$@"
