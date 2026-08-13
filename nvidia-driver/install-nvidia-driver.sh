#!/usr/bin/env bash
#
#  NVIDIA driver installer for Debian-based systems.
#
#  PHASE 1  prepare  - interactive, runs inside your desktop session:
#                      pick/download the driver, check sudo, install every
#                      package that is needed, back everything up, register the
#                      post-reboot check. Nothing is changed on the system yet.
#  PHASE 2  install  - unattended, runs detached in a screen session:
#                      stops the desktop, installs the driver, reboots.
#                      Rolls everything back if a step fails.
#  PHASE 3  verify   - runs automatically after the reboot (systemd unit):
#                      checks that the driver really works, otherwise it undoes
#                      the installation and reboots into the old state.
#
#  Logs of every phase land in ./logs/ next to this script.
#
set -Eeuo pipefail

# sbin tools (update-grub, update-initramfs, ...) are not on a user's PATH
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SELF_VERSION="2.0.0"

# Where things live -----------------------------------------------------------
LOG_DIR="${SCRIPT_DIR}/logs"                       # logs next to the script
VAR_DIR="/var/lib/nvidia-driver-installer"         # state + backups (root only)
STATE_FILE="${VAR_DIR}/state"
BACKUP_DIR="${VAR_DIR}/backup"
SYSTEM_COPY="/usr/local/sbin/nvidia-driver-installer"
VERIFY_UNIT="nvidia-driver-verify.service"
VERIFY_UNIT_PATH="/etc/systemd/system/${VERIFY_UNIT}"
INSTALL_UNIT="nvidia-driver-install"               # transient systemd unit
SCREEN_NAME="nvidia-install"
REPORT_FILE="${LOG_DIR}/REPORT.txt"

# --------------------------------------------------------------------------
#  Options
# --------------------------------------------------------------------------
CMD=""             # prepare | install | verify | rollback | status | attach
OPT_YES=0
OPT_DRYRUN=0
OPT_FILE=""
OPT_LOCAL=0
OPT_ONLINE=0
OPT_NO_REBOOT=0
OPT_KEEP_DESKTOP=0
OPT_PREPARE_ONLY=0
OPT_COLOR="auto"

usage() {
    cat <<EOF
NVIDIA driver installer ${SELF_VERSION}

  ${SCRIPT_NAME} [command] [options]

Commands:
  (none)        Phase 1 (prepare) and then Phase 2 (install) automatically
  prepare       Only phase 1 - check and download everything, change nothing
  install       Only phase 2 - normally started automatically by phase 1
  verify        Post-reboot check - normally started by systemd
  rollback      Undo the installation (driver, GRUB, nouveau, desktop)
  status        What state is the installation in?
  attach        Watch the running installation (screen -r)

Options:
  -f, --file PATH   Use this .run file, skip search and menu
  -l, --local       Straight to the local .run files, no source menu
  -o, --online      Straight to the online driver search at NVIDIA
  -y, --yes         Do not ask anything, take the defaults
  -n, --dry-run     Show what would happen, change nothing
      --no-reboot   Install, but do not reboot at the end
      --keep-desktop  Do not stop the display manager (for testing only)
      --no-color    Plain output
  -h, --help        This help

Everything is logged to ${LOG_DIR}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        prepare|install|verify|rollback|status|attach)
            CMD="$1"; shift ;;
        -f|--file)       OPT_FILE="${2:-}"; shift 2 ;;
        -l|--local)      OPT_LOCAL=1; OPT_ONLINE=0; shift ;;
        -o|--online)     OPT_ONLINE=1; OPT_LOCAL=0; shift ;;
        -y|--yes)        OPT_YES=1; shift ;;
        -n|--dry-run)    OPT_DRYRUN=1; shift ;;
        --no-reboot)     OPT_NO_REBOOT=1; shift ;;
        --keep-desktop)  OPT_KEEP_DESKTOP=1; shift ;;
        --no-color)      OPT_COLOR="never"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ "$CMD" == "prepare" ]] && OPT_PREPARE_ONLY=1
[[ -z "$CMD" ]] && CMD="prepare"

# --------------------------------------------------------------------------
#  Colors, symbols, boxes
# --------------------------------------------------------------------------
IS_TTY=0
[[ -t 1 ]] && IS_TTY=1
TTY_OUT=""
{ : >/dev/tty; } 2>/dev/null && TTY_OUT="/dev/tty"

setup_colors() {
    local enable=0
    if [[ "$OPT_COLOR" == "auto" ]]; then
        (( IS_TTY )) && [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]] && enable=1
    fi
    if (( enable )); then
        local e=$'\033'
        C_RESET="${e}[0m"; C_BOLD="${e}[1m"; C_DIM="${e}[2m"
        C_RED="${e}[38;5;203m"; C_YELLOW="${e}[38;5;221m"
        C_BLUE="${e}[38;5;75m"; C_GREY="${e}[38;5;245m"
        if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
            C_NV="${e}[38;2;118;185;0m"
        else
            C_NV="${e}[38;5;112m"
        fi
        C_LINE="$C_GREY"
    else
        C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_YELLOW="" C_BLUE="" C_GREY="" C_NV="" C_LINE=""
    fi
}
setup_colors

# Only use fancy glyphs when the terminal really speaks UTF-8 - a text console
# in the C locale would otherwise print garbage.
UTF8=0
[[ "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" == *[Uu][Tt][Ff]* ]] && UTF8=1
S_OK="+"; S_ERR="x"; S_WARN="!"; S_INFO="i"; S_ARROW=">"
BX_TL="+"; BX_TR="+"; BX_BL="+"; BX_BR="+"; BX_H="-"; BX_V="|"; BX_ML="+"; BX_MR="+"
if (( UTF8 )); then
    S_OK="✔"; S_ERR="✖"; S_WARN="!"; S_INFO="i"; S_ARROW="›"
    BX_TL="╭"; BX_TR="╮"; BX_BL="╰"; BX_BR="╯"; BX_H="─"; BX_V="│"; BX_ML="├"; BX_MR="┤"
fi

TERM_COLS="$( { tput cols; } 2>/dev/null || echo 80 )"
[[ "$TERM_COLS" =~ ^[0-9]+$ ]] || TERM_COLS=80
(( TERM_COLS < 40 )) && TERM_COLS=40
(( TERM_COLS > 100 )) && TERM_COLS=100
BOX_W=$(( TERM_COLS < 76 ? TERM_COLS : 76 ))

strip_ansi() {
    local s="$1"
    while [[ "$s" =~ $'\033'\[[0-9\;]*m ]]; do s="${s/"${BASH_REMATCH[0]}"/}"; done
    printf '%s' "$s"
}
vlen() { local s; s="$(strip_ansi "$1")"; printf '%s' "${#s}"; }
repeat() { local ch="$1" n="$2" out=""; while (( n-- > 0 )); do out+="$ch"; done; printf '%s' "$out"; }
fit() {
    local s="$1" max="$2"
    (( max < 4 )) && max=4
    if (( ${#s} > max )); then printf '%s...' "${s:0:max-3}"; else printf '%s' "$s"; fi
}

box_top()    { printf '%s%s%s%s%s\n' "$C_LINE" "$BX_TL" "$(repeat "$BX_H" $((BOX_W-2)))" "$BX_TR" "$C_RESET"; }
box_bottom() { printf '%s%s%s%s%s\n' "$C_LINE" "$BX_BL" "$(repeat "$BX_H" $((BOX_W-2)))" "$BX_BR" "$C_RESET"; }
box_sep()    { printf '%s%s%s%s%s\n' "$C_LINE" "$BX_ML" "$(repeat "$BX_H" $((BOX_W-2)))" "$BX_MR" "$C_RESET"; }
box_line() {
    local text="${1:-}" pad
    pad=$(( BOX_W - 4 - $(vlen "$text") ))
    (( pad < 0 )) && pad=0
    printf '%s%s%s %s%s %s%s%s\n' "$C_LINE" "$BX_V" "$C_RESET" "$text" "$(repeat ' ' "$pad")" "$C_LINE" "$BX_V" "$C_RESET"
}
box_kv() {
    local key="$1" val="${2:-}" color="${3:-}" kw=20 maxv
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

HEAD_N=0
heading() {
    HEAD_N=$((HEAD_N+1))
    local title="[$HEAD_N] $1" pad
    pad=$(( TERM_COLS - 6 - ${#title} ))
    (( pad < 0 )) && pad=0
    blank
    printf '%s===%s %s%s%s %s%s%s\n' \
        "$C_NV" "$C_RESET" "$C_BOLD" "$title" "$C_RESET" "$C_LINE" "$(repeat = "$pad")" "$C_RESET"
}

banner() {
    local sub="$1"
    blank
    if (( TERM_COLS >= 46 && UTF8 )); then
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
        printf '   %s%sN V I D I A%s\n' "$C_NV" "$C_BOLD" "$C_RESET"
    fi
    printf '   %sDriver Installer%s %sv%s  %s%s\n' \
        "$C_BOLD" "$C_RESET" "$C_DIM" "$SELF_VERSION" "$sub" "$C_RESET"
    blank
}

# --------------------------------------------------------------------------
#  Prompts
# --------------------------------------------------------------------------
TTY_IN=""
{ : </dev/tty; } 2>/dev/null && TTY_IN="/dev/tty"

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
    (( OPT_YES )) && { info "$prompt ${C_DIM}(automatically yes)${C_RESET}"; return 0; }
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
#  Logging
# --------------------------------------------------------------------------
LOG_MAIN=""     # readable transcript of this phase
LOG_DETAIL=""   # every command with its full output
PHASE=""

start_log() {
    PHASE="$1"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [[ ! -w "$LOG_DIR" ]]; then
        LOG_DIR="${TMPDIR:-/tmp}/nvidia-driver-installer-logs"
        mkdir -p "$LOG_DIR"
    fi
    REPORT_FILE="${LOG_DIR}/REPORT.txt"
    LOG_MAIN="${LOG_DIR}/${PHASE}-${ts}.log"
    LOG_DETAIL="${LOG_DIR}/${PHASE}-${ts}-detail.log"
    : >"$LOG_MAIN"; : >"$LOG_DETAIL"
    # phase 2/3 run as root - keep the logs readable and owned by the user
    if (( EUID == 0 )) && [[ -n "${ST_USER:-}" && "$ST_USER" != "root" ]]; then
        chown "$ST_USER" "$LOG_MAIN" "$LOG_DETAIL" 2>/dev/null || true
        chown "$ST_USER" "$LOG_DIR" 2>/dev/null || true
    fi
    {
        printf '=== NVIDIA driver installer %s - phase: %s ===\n' "$SELF_VERSION" "$PHASE"
        printf 'date    : %s\n' "$(date -Is)"
        printf 'host    : %s\n' "$(uname -n)"
        printf 'kernel  : %s\n' "$(uname -r)"
        printf 'user    : %s (uid %s)\n' "${USER:-?}" "$EUID"
        printf 'tty     : %s\n' "$(tty 2>/dev/null || true)"
        printf 'command : %s\n\n' "$SCRIPT_PATH $CMD"
    } >>"$LOG_DETAIL"

    # Mirror the pretty output into the log, without the color codes.
    exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>"$LOG_MAIN")) 2>&1
}

log()  { [[ -n "$LOG_DETAIL" ]] && printf '%s\n' "$*" >>"$LOG_DETAIL" || true; }

# --------------------------------------------------------------------------
#  Error handling
# --------------------------------------------------------------------------
ERR_GUARD=0
on_error() {
    local rc=$? line="$1" cmd="$2"
    (( ERR_GUARD )) && return
    ERR_GUARD=1
    blank
    fail "Unexpected error in line ${line} (exit ${rc})"
    hint "$cmd"
    log "ERROR line ${line}: ${cmd} (exit ${rc})"
    if [[ "$PHASE" == "install" ]]; then
        warn "Undoing the installation..."
        do_rollback "installation failed in line ${line}: ${cmd}"
    fi
    [[ -n "$LOG_MAIN" ]] && { blank; say "Log: ${LOG_MAIN}"; }
    exit "$rc"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap 'if (( IS_TTY )); then printf "\033[?25h"; fi' EXIT

# --------------------------------------------------------------------------
#  Running commands
# --------------------------------------------------------------------------
SUDO=""
need_root() {
    if (( EUID == 0 )); then SUDO=""; return 0; fi
    command -v sudo >/dev/null 2>&1 || return 1
    SUDO="sudo"
    return 0
}

# run "Description" cmd...            (output -> detail log, spinner on screen)
run() {
    local desc="$1"; shift
    if (( OPT_DRYRUN )); then
        printf '  %s%s%s %s\n' "$C_BLUE" "$S_ARROW" "$C_RESET" "$desc"
        hint "$*"
        return 0
    fi
    log ""; log "\$ $*"

    if (( ! IS_TTY )) || [[ -z "$TTY_OUT" ]]; then
        if "$@" >>"$LOG_DETAIL" 2>&1; then ok "$desc"; return 0; fi
        fail "$desc"; return 1
    fi

    local frames='|/-\' i=0 rc=0
    "$@" >>"$LOG_DETAIL" 2>&1 &
    local pid=$!
    printf '\033[?25l' >"$TTY_OUT"
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s%s%s %s' "$C_NV" "${frames:i++%4:1}" "$C_RESET" "$desc" >"$TTY_OUT"
        sleep 0.1
    done
    printf '\033[?25h\r\033[K' >"$TTY_OUT"
    wait "$pid" || rc=$?
    if (( rc == 0 )); then ok "$desc"; else fail "$desc ${C_DIM}(exit $rc)${C_RESET}"; fi
    return $rc
}

# same, but with root rights
run_root() { local d="$1"; shift; if [[ -n "$SUDO" ]]; then run "$d" "$SUDO" "$@"; else run "$d" "$@"; fi; }

# quiet root command, no output line
sh_root() {
    (( OPT_DRYRUN )) && { log "DRY-RUN: $*"; return 0; }
    log "\$ $*"
    if [[ -n "$SUDO" ]]; then "$SUDO" "$@" >>"$LOG_DETAIL" 2>&1; else "$@" >>"$LOG_DETAIL" 2>&1; fi
}

# write a file as root
write_root() {
    local path="$1" content="$2"
    (( OPT_DRYRUN )) && { log "DRY-RUN write $path"; return 0; }
    if [[ -n "$SUDO" ]]; then printf '%s' "$content" | "$SUDO" tee "$path" >/dev/null
    else printf '%s' "$content" >"$path"; fi
}

show_log_tail() {
    [[ -s "${LOG_DETAIL:-}" ]] || return 0
    blank
    say "${C_DIM}last lines of $(basename "$LOG_DETAIL"):${C_RESET}"
    tail -n 15 "$LOG_DETAIL" | sed "s/^/    ${C_DIM}/;s/\$/${C_RESET}/"
}

# --------------------------------------------------------------------------
#  System inspection
# --------------------------------------------------------------------------
KERNEL="$(uname -r)"
ARCH="$(uname -m)"
GPU_LIST=(); GPU_IDS=(); DEV_IDS=()
INSTALLED_DRIVER=""
SECUREBOOT="unknown"
DM_UNIT=""
DESKTOPS=""
SESSION_TYPE=""
DEFAULT_TARGET=""

detect_gpus() {
    GPU_LIST=(); GPU_IDS=(); DEV_IDS=()
    if command -v lspci >/dev/null 2>&1; then
        local line name id
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            id="$(grep -oE '\[10de:[0-9a-fA-F]{4}\]' <<<"$line" | head -1 | tr -d '[]' || true)"
            name="$(sed -E 's/^[0-9a-f:.]+ [^:]+: //; s/ \[10de:[0-9a-f]{4}\]//; s/ \(rev [0-9a-f]+\)$//' <<<"$line" || true)"
            GPU_LIST+=("${name:-NVIDIA GPU}")
            GPU_IDS+=("${id:-10de:????}")
            [[ -n "$id" ]] && DEV_IDS+=("$(tr '[:lower:]' '[:upper:]' <<<"${id#10de:}")")
        done < <(lspci -nn 2>/dev/null | grep -Ei '(VGA compatible controller|3D controller|Display controller)' | grep -i 'nvidia' || true)
    fi
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

# Which NVIDIA driver is loaded right now?
detect_installed_driver() {
    INSTALLED_DRIVER=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        INSTALLED_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
    fi
    if [[ -z "$INSTALLED_DRIVER" && -r /proc/driver/nvidia/version ]]; then
        # "NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  595.91.07  Release Build ..."
        INSTALLED_DRIVER="$(head -1 /proc/driver/nvidia/version 2>/dev/null \
                            | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
    fi
    if [[ -z "$INSTALLED_DRIVER" ]] && command -v modinfo >/dev/null 2>&1; then
        INSTALLED_DRIVER="$(modinfo -F version nvidia 2>/dev/null | head -1 || true)"
    fi
    INSTALLED_DRIVER="$(tr -d '[:space:]' <<<"$INSTALLED_DRIVER" || true)"
}

detect_secureboot() {
    SECUREBOOT="unknown"
    if command -v mokutil >/dev/null 2>&1; then
        local s; s="$(mokutil --sb-state 2>/dev/null || true)"
        case "$s" in
            *enabled*)  SECUREBOOT="enabled" ;;
            *disabled*) SECUREBOOT="disabled" ;;
        esac
    fi
    if [[ "$SECUREBOOT" == "unknown" ]]; then
        if [[ ! -d /sys/firmware/efi ]]; then
            SECUREBOOT="disabled"
        else
            local f b
            f="$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -1 || true)"
            if [[ -n "$f" && -r "$f" ]]; then
                b="$(od -An -t u1 "$f" 2>/dev/null | awk '{print $5}' || true)"
                [[ "$b" == "1" ]] && SECUREBOOT="enabled" || SECUREBOOT="disabled"
            fi
        fi
    fi
}

detect_display_manager() {
    DM_UNIT=""
    local unit
    unit="$(systemctl show -p Id --value display-manager.service 2>/dev/null || true)"
    if [[ -n "$unit" && "$unit" != "display-manager.service" ]]; then DM_UNIT="$unit"; return; fi
    local c
    for c in gdm3 gdm lightdm sddm lxdm xdm nodm ly greetd; do
        if systemctl is-active --quiet "${c}.service" 2>/dev/null; then DM_UNIT="${c}.service"; return; fi
    done
}

detect_desktops() {
    DESKTOPS=""
    local found=() p
    for p in gnome-shell plasmashell xfwm4 cinnamon mate-session lxqt-session i3 sway hyprland kwin_wayland kwin_x11; do
        pgrep -x "$p" >/dev/null 2>&1 && found+=("$p")
    done
    DESKTOPS="${found[*]:-}"
    SESSION_TYPE="${XDG_SESSION_TYPE:-}"
    if [[ -z "$SESSION_TYPE" ]]; then
        [[ -n "${WAYLAND_DISPLAY:-}" ]] && SESSION_TYPE="wayland"
        [[ -z "$SESSION_TYPE" && -n "${DISPLAY:-}" ]] && SESSION_TYPE="x11"
    fi
    DEFAULT_TARGET="$(systemctl get-default 2>/dev/null || echo graphical.target)"
}

on_real_vt() { [[ "$(tty 2>/dev/null || true)" =~ ^/dev/tty[0-9]+$ ]]; }

# Deliberately without a pipe: "lsmod | grep -q" makes lsmod die of SIGPIPE,
# and with "set -o pipefail" the whole test would look like a failure.
module_loaded() { grep -q "^${1} " /proc/modules 2>/dev/null; }

detect_all() {
    detect_gpus
    detect_installed_driver
    detect_secureboot
    detect_display_manager
    detect_desktops
}

# --------------------------------------------------------------------------
#  State file - what phase 2 and phase 3 need to know
# --------------------------------------------------------------------------
ST_PHASE=""; ST_DRIVER_FILE=""; ST_DRIVER_VERSION=""; ST_KERNEL=""
ST_PREV_DRIVER=""; ST_DM_UNIT=""; ST_DEFAULT_TARGET=""; ST_GRUB_BACKUP=""
ST_NOUVEAU_CREATED=""; ST_LOG_DIR=""; ST_SCRIPT_DIR=""; ST_USER=""
ST_STARTED=""; ST_ROLLED_BACK=""; ST_PURGE_PKGS=""

save_state() {
    (( OPT_DRYRUN )) && { log "DRY-RUN: would save state"; return 0; }
    local content
    content="$(cat <<EOF
ST_PHASE=${ST_PHASE}
ST_DRIVER_FILE=${ST_DRIVER_FILE}
ST_DRIVER_VERSION=${ST_DRIVER_VERSION}
ST_KERNEL=${ST_KERNEL}
ST_PREV_DRIVER=${ST_PREV_DRIVER}
ST_DM_UNIT=${ST_DM_UNIT}
ST_DEFAULT_TARGET=${ST_DEFAULT_TARGET}
ST_GRUB_BACKUP=${ST_GRUB_BACKUP}
ST_NOUVEAU_CREATED=${ST_NOUVEAU_CREATED}
ST_LOG_DIR=${ST_LOG_DIR}
ST_SCRIPT_DIR=${ST_SCRIPT_DIR}
ST_USER=${ST_USER}
ST_STARTED=${ST_STARTED}
ST_ROLLED_BACK=${ST_ROLLED_BACK}
ST_PURGE_PKGS=${ST_PURGE_PKGS}
EOF
)"
    sh_root mkdir -p "$VAR_DIR"
    write_root "$STATE_FILE" "$content"$'\n'
}

# Parsed key by key on purpose - never sourced, the file is read as root.
load_state() {
    [[ -r "$STATE_FILE" ]] || return 1
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            ST_PHASE|ST_DRIVER_FILE|ST_DRIVER_VERSION|ST_KERNEL|ST_PREV_DRIVER|\
            ST_DM_UNIT|ST_DEFAULT_TARGET|ST_GRUB_BACKUP|ST_NOUVEAU_CREATED|\
            ST_LOG_DIR|ST_SCRIPT_DIR|ST_USER|ST_STARTED|ST_ROLLED_BACK|ST_PURGE_PKGS)
                printf -v "$k" '%s' "$v" ;;
        esac
    done <"$STATE_FILE"
    # the logs belong next to the original script, not next to the system copy
    if [[ -n "$ST_LOG_DIR" ]]; then
        LOG_DIR="$ST_LOG_DIR"
        REPORT_FILE="${LOG_DIR}/REPORT.txt"
    fi
    return 0
}

# --------------------------------------------------------------------------
#  NVIDIA download server
# --------------------------------------------------------------------------
NV_BASE="https://download.nvidia.com/XFree86/Linux-${ARCH}"

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

remote_size() {
    local url="$1" len=""
    if command -v curl >/dev/null 2>&1; then
        len="$(curl -fsIL --max-time 15 "$url" 2>/dev/null | grep -i '^content-length:' | tail -1 | tr -dc '0-9' || true)"
    elif command -v wget >/dev/null 2>&1; then
        len="$(wget --spider -S --timeout=15 "$url" 2>&1 | grep -i 'content-length:' | tail -1 | tr -dc '0-9' || true)"
    fi
    printf '%s' "$len"
}
human_size() {
    local b="$1"
    if command -v numfmt >/dev/null 2>&1; then numfmt --to=iec --suffix=B "$b"
    else awk -v b="$b" 'BEGIN{ printf "%.0f MB", b/1048576 }'; fi
}
latest_stable_version() { http_get "${NV_BASE}/latest.txt" 8 | head -1 | awk '{print $1}' || true; }

# --------------------------------------------------------------------------
#  Local driver packages
# --------------------------------------------------------------------------
RUN_FILES=(); RUN_VERS=(); RUN_SIZES=(); RUN_DATES=()

file_version() {
    local base; base="$(basename "$1")"
    grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' <<<"$base" | head -1 || true
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
        done | sort -t$'\t' -k1,1Vr -k2,2nr || true
    )
    for line in "${raw[@]}"; do
        IFS=$'\t' read -r ver _ path <<<"$line"
        RUN_FILES+=("$path")
        if [[ "$ver" == "0" ]]; then RUN_VERS+=("unknown"); else RUN_VERS+=("$ver"); fi
        RUN_SIZES+=("$(du -h --apparent-size "$path" 2>/dev/null | cut -f1 || true)")
        RUN_DATES+=("$(date -r "$path" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '-')")
    done
}

SELECTED=""; SELECTED_VER=""

select_run_file() {
    local n="${#RUN_FILES[@]}"
    if (( n == 1 )); then
        SELECTED="${RUN_FILES[0]}"; SELECTED_VER="${RUN_VERS[0]}"
        blank; ok "One driver package found - using it: ${C_BOLD}$(basename "$SELECTED")${C_RESET}"
        return 0
    fi
    blank
    say "${C_BOLD}${n} driver packages found${C_RESET}"
    blank
    local i base fw=0 marker note
    for i in "${!RUN_FILES[@]}"; do
        base="$(basename "${RUN_FILES[$i]}")"; (( ${#base} > fw )) && fw=${#base}
    done
    for i in "${!RUN_FILES[@]}"; do
        base="$(basename "${RUN_FILES[$i]}")"
        if (( i == 0 )); then marker="${C_NV}${S_ARROW}${C_RESET}"; else marker=" "; fi
        note=""
        [[ "$base" != *"$ARCH"* ]] && note="  ${C_YELLOW}not ${ARCH}${C_RESET}"
        printf '  %s %s%d)%s %s%-12s%s %s%-*s  %6s  %s%s%s\n' \
            "$marker" "$C_BOLD" "$((i+1))" "$C_RESET" "$C_NV" "${RUN_VERS[$i]}" "$C_RESET" \
            "$C_DIM" "$fw" "$base" "${RUN_SIZES[$i]}" "${RUN_DATES[$i]}" "$C_RESET" "$note"
    done
    blank
    say "${C_DIM}1) is the newest version - press Enter to take it.${C_RESET}"
    blank
    if (( OPT_YES )); then
        SELECTED="${RUN_FILES[0]}"; SELECTED_VER="${RUN_VERS[0]}"
        info "Automatically selected ${C_BOLD}${SELECTED_VER}${C_RESET}"; return 0
    fi
    local choice
    while true; do
        printf '  %s%s%s Select driver %s[1-%d, default 1]%s ' \
            "$C_NV" "$S_ARROW" "$C_RESET" "$C_DIM" "$n" "$C_RESET"
        read_line choice; choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            SELECTED="${RUN_FILES[$((choice-1))]}"; SELECTED_VER="${RUN_VERS[$((choice-1))]}"
            return 0
        fi
        warn "Please enter a number between 1 and ${n}."
    done
}

# --------------------------------------------------------------------------
#  Online driver search
# --------------------------------------------------------------------------
ONLINE_VERS=(); ONLINE_NAMES=(); ONLINE_STABLE=""; ONLINE_DEFAULT=0; ONLINE_PICK=""

version_supports_gpu() {
    local ver="$1" html id name
    html="$(http_get "${NV_BASE}/${ver}/README/supportedchips.html" 25)" || return 1
    [[ -n "$html" ]] || return 1
    for id in "${DEV_IDS[@]}"; do
        name="$(grep -A1 -i "id=\"devid${id}\"" <<<"$html" | sed -n 's:.*<td>\([^<]*\)</td>.*:\1:p' | head -1 || true)"
        [[ -n "$name" ]] && { printf '%s' "$name"; return 0; }
        if grep -qiE ">${id}</td>" <<<"$html"; then printf 'supported'; return 0; fi
    done
    return 1
}

fetch_version_index() {
    http_get "${NV_BASE}/" 20 \
        | grep -oE "href='[0-9]+\.[0-9]+(\.[0-9]+)?/'" \
        | tr -d "href='/" | grep -E '^[0-9]{3}\.' | sort -Vr || true
}

scan_versions() {
    local vers=("$@")
    local tmp v pids=() total=${#vers[@]} i chunk=6
    tmp="$(mktemp -d)"
    for (( i=0; i<total; i+=chunk )); do
        pids=()
        for v in "${vers[@]:i:chunk}"; do
            ( version_supports_gpu "$v" >"$tmp/$v" 2>/dev/null || rm -f "$tmp/$v" ) &
            pids+=($!)
        done
        if (( IS_TTY )) && [[ -n "$TTY_OUT" ]]; then
            local frames='|/-\' f=0
            while kill -0 "${pids[0]}" 2>/dev/null; do
                printf '\r  %s%s%s Checking GPU support %s(%d/%d)%s' \
                    "$C_NV" "${frames:f++%4:1}" "$C_RESET" "$C_DIM" "$i" "$total" "$C_RESET" >"$TTY_OUT"
                sleep 0.1
            done
        fi
        wait "${pids[@]}" 2>/dev/null || true
    done
    (( IS_TTY )) && [[ -n "$TTY_OUT" ]] && printf '\r\033[K' >"$TTY_OUT"
    for v in "${vers[@]}"; do
        if [[ -s "$tmp/$v" ]]; then ONLINE_VERS+=("$v"); ONLINE_NAMES+=("$(<"$tmp/$v")"); fi
    done
    rm -rf "$tmp"
    ok "Checked ${total} releases ${C_DIM}|${C_RESET} ${#ONLINE_VERS[@]} support your GPU"
}

pick_online_default() {
    local i stable_i=-1 nv=() nn=()
    for i in "${!ONLINE_VERS[@]}"; do
        if [[ "${ONLINE_VERS[$i]}" == "$ONLINE_STABLE" ]]; then
            nv+=("${ONLINE_VERS[$i]}"); nn+=("${ONLINE_NAMES[$i]}"); stable_i=$i; break
        fi
    done
    for i in "${!ONLINE_VERS[@]}"; do
        (( i == stable_i )) && continue
        nv+=("${ONLINE_VERS[$i]}"); nn+=("${ONLINE_NAMES[$i]}")
    done
    ONLINE_VERS=("${nv[@]}"); ONLINE_NAMES=("${nn[@]}"); ONLINE_DEFAULT=0
}

online_search() {
    ONLINE_VERS=(); ONLINE_NAMES=(); ONLINE_DEFAULT=0
    if ! have_downloader; then
        blank; fail "Neither curl nor wget is installed - no online search possible."
        hint "sudo apt-get install curl"; return 1
    fi
    blank; say "${C_BOLD}Searching for drivers on download.nvidia.com${C_RESET}"; blank

    ONLINE_STABLE="$(latest_stable_version)"
    if [[ -z "$ONLINE_STABLE" ]]; then
        fail "No connection to download.nvidia.com."
        hint "Check internet connection, proxy or DNS."
        hint "Test: curl -I ${NV_BASE}/latest.txt"
        return 1
    fi
    ok "Connected ${C_DIM}|${C_RESET} newest stable release: ${C_NV}${C_BOLD}${ONLINE_STABLE}${C_RESET}"

    local all=()
    mapfile -t all < <(fetch_version_index)
    if (( ${#all[@]} == 0 )); then
        fail "The driver index could not be read."; hint "${NV_BASE}/"; return 1
    fi
    ok "${#all[@]} driver releases available for ${ARCH}"

    if (( ${#DEV_IDS[@]} == 0 )); then
        warn "No GPU detected - showing the newest releases unfiltered."
        local v
        for v in "${all[@]:0:12}"; do ONLINE_VERS+=("$v"); ONLINE_NAMES+=("not checked"); done
        pick_online_default; return 0
    fi

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
        (( round == 1 )) && { blank; warn "None of the newest releases support your GPU - looking further back."; }
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

online_select() {
    local n=${#ONLINE_VERS[@]} def=$(( ONLINE_DEFAULT + 1 )) i marker tag
    blank; say "${C_BOLD}Drivers for ${GPU_LIST[0]:-your GPU}${C_RESET}"; blank
    for i in "${!ONLINE_VERS[@]}"; do
        if (( i == ONLINE_DEFAULT )); then marker="${C_NV}${S_ARROW}${C_RESET}"; else marker=" "; fi
        if [[ "${ONLINE_VERS[$i]}" == "$ONLINE_STABLE" ]]; then
            tag="${C_NV}stable${C_RESET}"
        elif [[ -n "$ONLINE_STABLE" ]] && \
             [[ "$(printf '%s\n%s\n' "${ONLINE_VERS[$i]}" "$ONLINE_STABLE" | sort -Vr | head -1)" == "${ONLINE_VERS[$i]}" ]]; then
            tag="${C_YELLOW}beta branch${C_RESET}"
        else
            tag="${C_DIM}older${C_RESET}"
        fi
        printf '  %s %s%2d)%s %s%-12s%s  %-14s %s%s%s\n' \
            "$marker" "$C_BOLD" "$((i+1))" "$C_RESET" "$C_NV" "${ONLINE_VERS[$i]}" "$C_RESET" \
            "$tag" "$C_DIM" "${ONLINE_NAMES[$i]}" "$C_RESET"
    done
    blank
    if [[ "${ONLINE_VERS[$ONLINE_DEFAULT]}" == "$ONLINE_STABLE" ]]; then
        say "${C_DIM}Entry ${def} is the newest stable release - press Enter to take it.${C_RESET}"
    else
        say "${C_DIM}Entry ${def} is the newest release - press Enter to take it.${C_RESET}"
    fi
    blank
    if (( OPT_YES )); then
        ONLINE_PICK="${ONLINE_VERS[$ONLINE_DEFAULT]}"
        info "Automatically selected ${C_BOLD}${ONLINE_PICK}${C_RESET}"; return 0
    fi
    local choice
    while true; do
        printf '  %s%s%s Select driver %s[1-%d, default %d]%s ' \
            "$C_NV" "$S_ARROW" "$C_RESET" "$C_DIM" "$n" "$def" "$C_RESET"
        read_line choice; choice="${choice:-$def}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            ONLINE_PICK="${ONLINE_VERS[$((choice-1))]}"; return 0
        fi
        warn "Please enter a number between 1 and ${n}."
    done
}

DL_PART=""
download_driver() {
    local ver="$1"
    local file="NVIDIA-Linux-${ARCH}-${ver}.run"
    local url="${NV_BASE}/${ver}/${file}" dest="${SCRIPT_DIR}/${file}"

    blank
    if [[ -f "$dest" ]]; then
        info "${file} is already in this folder."
        if confirm "Use the existing file?" y; then SELECTED="$dest"; SELECTED_VER="$ver"; return 0; fi
    fi
    if (( OPT_DRYRUN )); then
        info "Dry run - the driver would be downloaded now:"
        say "    ${C_DIM}from ${url}${C_RESET}"
        say "    ${C_DIM}to   ${dest}${C_RESET}"
        blank; ok "Nothing downloaded, nothing changed."; blank
        exit 0
    fi
    [[ -w "$SCRIPT_DIR" ]] || die "No write permission in ${SCRIPT_DIR}."

    local bytes size="unknown size"
    bytes="$(remote_size "$url")"
    [[ -n "$bytes" ]] && size="$(human_size "$bytes")"
    info "Download size: ${C_BOLD}${size}${C_RESET}"
    confirm "Download now?" y || die "Cancelled."

    blank; say "${C_BOLD}Downloading${C_RESET} ${C_DIM}${file}${C_RESET}"
    DL_PART="${dest}.part"
    trap 'rm -f "$DL_PART"; exit 130' INT TERM
    local rc=0
    if command -v curl >/dev/null 2>&1; then
        if (( IS_TTY )); then curl -fL --progress-bar -o "$DL_PART" "$url" || rc=$?
        else curl -fsSL -o "$DL_PART" "$url" || rc=$?; fi
    else
        if (( IS_TTY )); then wget -q --show-progress -O "$DL_PART" "$url" || rc=$?
        else wget -q -O "$DL_PART" "$url" || rc=$?; fi
    fi
    trap - INT TERM
    if (( rc != 0 )); then
        rm -f "$DL_PART"; blank
        fail "Download failed (exit ${rc})."; hint "$url"
        exit 1
    fi
    mv "$DL_PART" "$dest"; DL_PART=""
    chmod +x "$dest" 2>/dev/null || true
    blank; ok "Saved: ${C_BOLD}${file}${C_RESET} ($(du -h "$dest" | cut -f1))"
    SELECTED="$dest"; SELECTED_VER="$ver"
}

show_download_help() {
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
        for i in "${!GPU_LIST[@]}"; do ok "${GPU_LIST[$i]} ${C_DIM}[${GPU_IDS[$i]}]${C_RESET}"; done
    else
        warn "No NVIDIA GPU detected."
    fi
    blank
    say "${C_BOLD}Where to get the driver${C_RESET}"
    say "  ${C_DIM}Driver search ....... https://www.nvidia.com/en-us/drivers/${C_RESET}"
    say "  ${C_DIM}Unix archive ........ ${NV_BASE}/${C_RESET}"
    blank
    info "Put the .run file next to this script and start again."
    blank
}

SOURCE_PICK=""
source_menu() {
    local n=${#RUN_FILES[@]} def=1 choice
    (( n == 0 )) && def=2
    blank; say "${C_BOLD}Where should the driver come from?${C_RESET}"; blank
    local m1=" " m2=" "
    if (( def == 1 )); then m1="${C_NV}${S_ARROW}${C_RESET}"; else m2="${C_NV}${S_ARROW}${C_RESET}"; fi
    printf '  %s %s1)%s Install from a local .run file\n' "$m1" "$C_BOLD" "$C_RESET"
    if (( n == 0 )); then
        printf '       %sno .run file in this folder%s\n' "$C_DIM" "$C_RESET"
    elif (( n == 1 )); then
        printf '       %s%s%s\n' "$C_DIM" "$(basename "${RUN_FILES[0]}")" "$C_RESET"
    else
        printf '       %s%d packages found - newest: %s%s\n' "$C_DIM" "$n" "${RUN_VERS[0]}" "$C_RESET"
    fi
    printf '  %s %s2)%s Search online at NVIDIA and download\n' "$m2" "$C_BOLD" "$C_RESET"
    printf '       %sdrivers for %s%s\n' "$C_DIM" "${GPU_LIST[0]:-your GPU}" "$C_RESET"
    printf '    %s3)%s Quit\n' "$C_BOLD" "$C_RESET"
    blank
    if (( OPT_YES )); then info "Automatically selected option ${def}"; SOURCE_PICK="$def"; return 0; fi
    while true; do
        printf '  %s%s%s Your choice %s[1-3, default %d]%s ' \
            "$C_NV" "$S_ARROW" "$C_RESET" "$C_DIM" "$def" "$C_RESET"
        read_line choice; choice="${choice:-$def}"
        case "$choice" in 1|2|3) SOURCE_PICK="$choice"; return 0 ;; *) warn "Please enter 1, 2 or 3." ;; esac
    done
}

choose_driver() {
    local pick
    while true; do
        if (( OPT_ONLINE )); then pick=2
        elif (( OPT_LOCAL )); then pick=1
        else source_menu; pick="$SOURCE_PICK"; fi
        case "$pick" in
            1)  if (( ${#RUN_FILES[@]} == 0 )); then
                    blank; warn "There is no NVIDIA*.run file in ${SCRIPT_DIR}."
                    (( OPT_LOCAL )) && { show_download_help; exit 1; }
                    hint "Option 2 downloads one."
                    continue
                fi
                select_run_file; return 0 ;;
            2)  if ! online_search; then
                    (( OPT_ONLINE )) && exit 1
                    blank; confirm "Back to the menu?" y || exit 1
                    continue
                fi
                online_select; download_driver "$ONLINE_PICK"; return 0 ;;
            3)  blank; ok "Cancelled."; blank; exit 0 ;;
        esac
    done
}

# ==========================================================================
#  PHASE 1 - PREPARE
# ==========================================================================
CHECKS_FAIL=0
CHECKS_WARN=0
# These always return 0 - they are used in "cond && check_ok || check_bad".
check_ok()   { box_line "$(printf '%s%s%s %s' "$C_NV" "$S_OK" "$C_RESET" "$1")"; return 0; }
check_warn() { CHECKS_WARN=$((CHECKS_WARN+1)); box_line "$(printf '%s%s%s %s' "$C_YELLOW" "$S_WARN" "$C_RESET" "$1")"; return 0; }
check_bad()  { CHECKS_FAIL=$((CHECKS_FAIL+1)); box_line "$(printf '%s%s%s %s' "$C_RED" "$S_ERR" "$C_RESET" "$1")"; return 0; }

REQUIRED_PKGS=()
MISSING_PKGS=()

pkg_installed() {
    local st
    st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
    [[ "$st" == *"ok installed"* ]]
}

collect_required_packages() {
    REQUIRED_PKGS=(
        "linux-headers-${KERNEL}"
        build-essential make gcc
        dkms
        screen
        pciutils
        acpid
        libglvnd-dev
        pkg-config
    )
    MISSING_PKGS=()
    local p
    for p in "${REQUIRED_PKGS[@]}"; do
        pkg_installed "$p" || MISSING_PKGS+=("$p")
    done
}

free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}' || echo 0; }

# Debian's own NVIDIA packages get in the way of a .run installation.
DISTRO_PKGS=()
detect_distro_driver() {
    DISTRO_PKGS=()
    command -v dpkg-query >/dev/null 2>&1 || return 0

    # Only the packages that really ship the display driver. Container
    # tooling, CUDA and the generic EGL-Wayland library are none of our
    # business - removing those would break unrelated things.
    local patterns=(
        'nvidia-driver*' 'nvidia-kernel-*' 'nvidia-legacy-*' 'nvidia-alternative*'
        'nvidia-egl-common' 'nvidia-vdpau-driver' 'nvidia-vulkan-*'
        'nvidia-smi' 'nvidia-settings' 'nvidia-persistenced' 'nvidia-opencl-*'
        'nvidia-support' 'nvidia-modprobe'
        'libnvidia-glcore*' 'libnvidia-ml1*' 'libnvidia-eglcore*' 'libnvidia-glvkspirv*'
        'libnvidia-encode*' 'libnvidia-decode*' 'libnvidia-fbc1*' 'libnvidia-cfg1*'
        'libnvidia-rtcore*' 'libnvidia-allocator1*' 'libnvidia-gpucomp*' 'libnvidia-ptxjitcompiler*'
        'xserver-xorg-video-nvidia*' 'libgl1-nvidia*' 'libglx-nvidia*'
    )
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && DISTRO_PKGS+=("$p")
    done < <(dpkg-query -W -f='${Package} ${Status}\n' "${patterns[@]}" 2>/dev/null \
             | grep 'ok installed' | awk '{print $1}' \
             | grep -Ev 'container|docker|toolkit|cuda|nvidia-detect|egl-wayland' \
             | sort -u || true)
}

# Ask once, in phase 1, what should happen with those packages.
handle_distro_driver() {
    ST_PURGE_PKGS=""
    detect_distro_driver
    (( ${#DISTRO_PKGS[@]} == 0 )) && { ok "No distribution driver installed"; return 0; }

    warn "Debian's own NVIDIA driver is installed:"
    local p
    for p in "${DISTRO_PKGS[@]}"; do hint "$p"; done
    blank
    hint "It uses the same files as the .run driver. If both are installed,"
    hint "the installation usually breaks. Removing it is the safe way."
    blank
    if confirm "Remove these packages in phase 2?" y; then
        ST_PURGE_PKGS="${DISTRO_PKGS[*]}"
        ok "Will be removed in phase 2 (rollback puts them back)"
    else
        warn "Kept - the installation may fail, but rollback will restore your system."
    fi
}

phase1_prepare() {
    start_log "prepare"
    banner "phase 1: prepare"

    say "${C_DIM}Phase 1 checks and downloads everything. Nothing on your system"
    say "is changed yet. Phase 2 then installs unattended.${C_RESET}"

    detect_all

    # ---- system overview -------------------------------------------------
    heading "System"
    box_top
    box_line "${C_BOLD}What was found${C_RESET}"
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
    box_kv "Loaded driver" "${INSTALLED_DRIVER:-none}" "$( [[ -n "$INSTALLED_DRIVER" ]] && echo "$C_NV" || echo "$C_DIM" )"
    box_kv "Display manager" "${DM_UNIT:-none}"
    box_kv "Desktop" "${DESKTOPS:-none running}"
    box_kv "Session" "${SESSION_TYPE:-unknown}"
    box_kv "Default target" "${DEFAULT_TARGET:-?}"
    box_kv "Secure Boot" "$SECUREBOOT" "$( [[ "$SECUREBOOT" == "enabled" ]] && echo "$C_YELLOW" || echo "" )"
    box_bottom

    if (( ${#GPU_LIST[@]} == 0 )); then
        blank; warn "No NVIDIA GPU found on the PCI bus."
        confirm "Continue anyway?" n || die "Cancelled - no NVIDIA hardware."
    fi

    # ---- driver selection ------------------------------------------------
    heading "Driver"
    if [[ -n "$OPT_FILE" ]]; then
        [[ -f "$OPT_FILE" ]] || die "File not found: $OPT_FILE"
        SELECTED="$(readlink -f "$OPT_FILE")"
        SELECTED_VER="$(file_version "$SELECTED")"; SELECTED_VER="${SELECTED_VER:-unknown}"
        ok "Using ${C_BOLD}$(basename "$SELECTED")${C_RESET}"
    else
        discover_run_files
        choose_driver
    fi

    # ---- root rights -----------------------------------------------------
    heading "Root rights"
    if ! need_root; then
        die "Neither root nor sudo available - cannot install."
    fi
    if (( OPT_DRYRUN )); then
        info "Dry run - sudo is not asked for"
    elif [[ -n "$SUDO" ]]; then
        info "sudo password is needed once, now."
        if ! sudo -v; then die "sudo denied - no root rights."; fi
        ok "sudo rights confirmed"
        # keep the sudo timestamp alive for the rest of phase 1
        ( while true; do sleep 50; sudo -n true 2>/dev/null || exit; done ) &
        SUDO_KEEPALIVE=$!
        trap 'kill "${SUDO_KEEPALIVE:-}" 2>/dev/null || true; if (( IS_TTY )); then printf "\033[?25h"; fi' EXIT
    else
        ok "Running as root"
    fi

    # ---- packages --------------------------------------------------------
    heading "Packages"
    collect_required_packages
    if (( ${#MISSING_PKGS[@]} == 0 )); then
        ok "All required packages are installed"
    else
        info "Missing: ${C_BOLD}${MISSING_PKGS[*]}${C_RESET}"
        if ! run_root "Updating the package index" apt-get update; then
            warn "apt-get update reported problems - trying to install anyway."
        fi
        run_root "Installing ${#MISSING_PKGS[@]} packages" \
            env DEBIAN_FRONTEND=noninteractive apt-get -y install "${MISSING_PKGS[@]}" \
            || warn "Not all packages could be installed - see the check below."
        collect_required_packages
        if (( ${#MISSING_PKGS[@]} == 0 )); then
            ok "All required packages are installed now"
        else
            warn "Still missing: ${MISSING_PKGS[*]}"
        fi
    fi

    # ---- Debian's own driver --------------------------------------------
    heading "Distribution driver"
    handle_distro_driver

    # ---- verify the driver package --------------------------------------
    heading "Driver package"
    local size_mb=0
    if [[ -f "$SELECTED" ]]; then
        size_mb=$(( $(stat -c '%s' "$SELECTED") / 1024 / 1024 ))
        ok "$(basename "$SELECTED") - ${size_mb} MB"
    fi
    chmod +x "$SELECTED" 2>/dev/null || true
    local archive_ok=1
    if (( OPT_DRYRUN )); then
        info "Dry run - integrity check skipped"
    elif ! run "Checking archive integrity" bash "$SELECTED" --check; then
        archive_ok=0
        show_log_tail
    fi

    # ---- the big preflight ----------------------------------------------
    heading "Check list"
    CHECKS_FAIL=0; CHECKS_WARN=0
    box_top
    box_line "${C_BOLD}Everything that has to be right${C_RESET}"
    box_sep

    (( ${#GPU_LIST[@]} > 0 )) && check_ok "NVIDIA GPU detected" || check_bad "No NVIDIA GPU"
    [[ -n "$SUDO" || $EUID -eq 0 ]] && check_ok "Root rights available" || check_bad "No root rights"

    if [[ -f "$SELECTED" ]] && (( size_mb > 20 )); then
        check_ok "Driver package present ($(basename "$SELECTED"))"
    else
        check_bad "Driver package missing or too small"
    fi
    (( archive_ok )) && check_ok "Archive integrity verified" || check_bad "Archive is corrupt"

    if (( ${#MISSING_PKGS[@]} == 0 )); then
        check_ok "All packages installed (offline-ready)"
    else
        check_bad "Packages missing: ${MISSING_PKGS[*]}"
    fi

    if [[ -d "/lib/modules/${KERNEL}/build" ]]; then
        check_ok "Kernel headers for ${KERNEL}"
    else
        check_bad "No kernel headers for ${KERNEL} (reboot after a kernel update?)"
    fi

    command -v screen >/dev/null 2>&1 && check_ok "screen available (background installation)" \
                                      || check_bad "screen is missing"
    command -v systemctl >/dev/null 2>&1 && check_ok "systemd available" || check_bad "No systemd"
    command -v dkms >/dev/null 2>&1 && check_ok "DKMS available (survives kernel updates)" \
                                    || check_warn "DKMS missing - driver breaks on kernel updates"

    local mb_usr mb_boot
    mb_usr="$(free_mb /usr)"; mb_boot="$(free_mb /boot)"
    (( mb_usr > 1500 )) && check_ok "Disk space /usr: ${mb_usr} MB free" \
                        || check_bad "Too little space in /usr: ${mb_usr} MB"
    (( mb_boot > 100 )) && check_ok "Disk space /boot: ${mb_boot} MB free" \
                        || check_warn "Little space in /boot: ${mb_boot} MB"

    if [[ "$SECUREBOOT" == "enabled" ]]; then
        check_bad "Secure Boot is ON - unattended install impossible"
    else
        check_ok "Secure Boot off - module needs no signature"
    fi

    if [[ -n "$DM_UNIT" ]]; then check_ok "Display manager: ${DM_UNIT}"
    else check_warn "No display manager found - nothing needs stopping"; fi

    if [[ -n "$ST_PURGE_PKGS" ]]; then
        check_ok "Distribution driver is removed in phase 2 ($(wc -w <<<"$ST_PURGE_PKGS") packages)"
    elif (( ${#DISTRO_PKGS[@]} > 0 )); then
        check_warn "Distribution driver stays installed - conflicts likely"
    else
        check_ok "No conflicting distribution driver"
    fi

    if [[ -n "$INSTALLED_DRIVER" ]]; then
        if [[ "$INSTALLED_DRIVER" == "$SELECTED_VER" ]]; then
            check_warn "Version ${SELECTED_VER} is already loaded - reinstall"
        elif [[ "$(printf '%s\n%s\n' "$INSTALLED_DRIVER" "$SELECTED_VER" | sort -Vr | head -1)" == "$INSTALLED_DRIVER" ]]; then
            check_warn "Downgrade: ${INSTALLED_DRIVER} is loaded, ${SELECTED_VER} selected"
        else
            check_ok "Upgrade ${INSTALLED_DRIVER} -> ${SELECTED_VER}"
        fi
    else
        check_ok "No driver loaded yet - clean installation"
    fi

    box_sep
    if (( CHECKS_FAIL > 0 )); then
        box_line "${C_RED}${CHECKS_FAIL} problem(s) - installation not possible${C_RESET}"
    elif (( CHECKS_WARN > 0 )); then
        box_line "${C_YELLOW}Ready, with ${CHECKS_WARN} warning(s)${C_RESET}"
    else
        box_line "${C_NV}Everything ready${C_RESET}"
    fi
    box_bottom

    if (( CHECKS_FAIL > 0 )); then
        blank
        fail "Phase 2 will not start - fix the points above first."
        if [[ "$SECUREBOOT" == "enabled" ]]; then
            blank
            say "  ${C_BOLD}Secure Boot${C_RESET}"
            hint "An unattended installation cannot enroll a signing key."
            hint "Turn Secure Boot off in the UEFI setup, or install by hand"
            hint "with:  sudo bash $(basename "$SELECTED") -e"
        fi
        blank; say "Log: ${LOG_MAIN}"; blank
        exit 1
    fi

    # ---- backups + state -------------------------------------------------
    heading "Backups and state"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    sh_root mkdir -p "$VAR_DIR" "$BACKUP_DIR"
    ST_GRUB_BACKUP=""
    if [[ -f /etc/default/grub ]]; then
        ST_GRUB_BACKUP="${BACKUP_DIR}/grub.${ts}"
        sh_root cp -a /etc/default/grub "$ST_GRUB_BACKUP"
        ok "Backed up /etc/default/grub"
    fi
    if [[ -f /etc/modprobe.d/blacklist-nouveau.conf ]]; then
        ST_NOUVEAU_CREATED=0
        sh_root cp -a /etc/modprobe.d/blacklist-nouveau.conf "${BACKUP_DIR}/blacklist-nouveau.conf.${ts}"
        ok "Backed up the existing nouveau blacklist"
    else
        ST_NOUVEAU_CREATED=1
        ok "No nouveau blacklist yet - will be created (and removed on rollback)"
    fi

    ST_PHASE="prepared"
    ST_DRIVER_FILE="$SELECTED"
    ST_DRIVER_VERSION="$SELECTED_VER"
    ST_KERNEL="$KERNEL"
    ST_PREV_DRIVER="${INSTALLED_DRIVER:-none}"
    ST_DM_UNIT="$DM_UNIT"
    ST_DEFAULT_TARGET="$DEFAULT_TARGET"
    ST_LOG_DIR="$LOG_DIR"
    ST_SCRIPT_DIR="$SCRIPT_DIR"
    ST_USER="${SUDO_USER:-${USER:-root}}"
    ST_STARTED="$(date -Is)"
    ST_ROLLED_BACK=0
    save_state
    ok "State saved: ${STATE_FILE}"

    # a copy that survives even if this folder disappears
    sh_root install -m 0755 "$SCRIPT_PATH" "$SYSTEM_COPY" || true
    ok "System copy: ${SYSTEM_COPY}"

    install_verify_unit
    ok "Post-reboot check registered (${VERIFY_UNIT})"

    # ---- summary ---------------------------------------------------------
    heading "Ready for phase 2"
    box_top
    box_line "${C_BOLD}This is what phase 2 will do - without asking again${C_RESET}"
    box_sep
    box_line "1. stop the desktop (${DM_UNIT:-none})"
    [[ -n "$ST_PURGE_PKGS" ]] && box_line "2. remove Debian's NVIDIA packages"
    box_line "$( [[ -n "$ST_PURGE_PKGS" ]] && echo 3 || echo 2 ). blacklist nouveau, rebuild the initramfs"
    box_line "$( [[ -n "$ST_PURGE_PKGS" ]] && echo 4 || echo 3 ). patch the GRUB kernel command line"
    box_line "$( [[ -n "$ST_PURGE_PKGS" ]] && echo 5 || echo 4 ). install driver ${SELECTED_VER} silently"
    box_line "$( [[ -n "$ST_PURGE_PKGS" ]] && echo 6 || echo 5 ). reboot"
    box_line "$( [[ -n "$ST_PURGE_PKGS" ]] && echo 7 || echo 6 ). after the reboot: check that the driver works"
    box_line "   -> if not, everything is undone automatically"
    box_sep
    box_kv "Driver" "$(basename "$SELECTED")" "$C_NV"
    box_kv "Logs" "$LOG_DIR"
    box_kv "Runs in" "screen session '${SCREEN_NAME}'"
    box_bottom
    blank

    if (( OPT_DRYRUN )); then
        warn "Dry run - phase 2 is not started."
        blank; say "Log: ${LOG_MAIN}"; blank
        return 0
    fi
    if (( OPT_PREPARE_ONLY )); then
        ok "Preparation finished."
        blank
        say "  Start phase 2 with:  ${C_BOLD}sudo ${SCRIPT_PATH} install${C_RESET}"
        blank
        return 0
    fi

    blank
    warn "Your desktop will be closed. Save your work now."
    blank
    confirm "Start installation (phase 2)?" y || { blank; ok "Cancelled. Nothing changed."; blank; exit 0; }

    launch_phase2
}

# --------------------------------------------------------------------------
#  The post-reboot check as a systemd unit
# --------------------------------------------------------------------------
install_verify_unit() {
    local unit
    unit="$(cat <<EOF
[Unit]
Description=NVIDIA driver check after installation
After=multi-user.target local-fs.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=${SYSTEM_COPY} verify
StandardOutput=journal
StandardError=journal
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
)"
    write_root "$VERIFY_UNIT_PATH" "$unit"$'\n'
    sh_root systemctl daemon-reload
}

# --------------------------------------------------------------------------
#  Starting phase 2 detached
# --------------------------------------------------------------------------
launch_phase2() {
    blank
    local target="$SYSTEM_COPY"
    [[ -x "$target" ]] || target="$SCRIPT_PATH"

    local started=0
    if command -v systemd-run >/dev/null 2>&1 && command -v screen >/dev/null 2>&1; then
        if sh_root systemd-run --unit="$INSTALL_UNIT" \
                --description="NVIDIA driver installation" \
                --property=KillMode=process \
                --property=TimeoutStartSec=infinity \
                screen -DmS "$SCREEN_NAME" bash "$target" install; then
            started=1
            ok "Installation started (systemd unit ${INSTALL_UNIT}, screen '${SCREEN_NAME}')"
        fi
    fi
    if (( ! started )) && command -v screen >/dev/null 2>&1; then
        if sh_root setsid screen -dmS "$SCREEN_NAME" bash "$target" install; then
            started=1
            ok "Installation started (screen '${SCREEN_NAME}')"
        fi
    fi
    if (( ! started )); then
        if [[ -n "$SUDO" ]]; then
            $SUDO setsid nohup bash "$target" install >>"${LOG_DIR}/install-nohup.log" 2>&1 &
        else
            setsid nohup bash "$target" install >>"${LOG_DIR}/install-nohup.log" 2>&1 &
        fi
        started=1
        warn "screen is missing - installation started in the background"
    fi

    blank
    box_top
    box_line "${C_NV}${C_BOLD}Phase 2 is running${C_RESET}"
    box_sep
    box_line "Watch live   : ${C_BOLD}sudo screen -r ${SCREEN_NAME}${C_RESET}"
    box_line "               (leave again with Ctrl+A then D)"
    box_line "Read the log : ${C_BOLD}tail -f ${LOG_DIR}/install-*.log${C_RESET}"
    box_line "Status       : ${C_BOLD}${SCRIPT_NAME} status${C_RESET}"
    box_sep
    box_line "The desktop stops in a few seconds."
    box_line "The machine reboots on its own when the driver is installed."
    box_line "If anything fails, everything is undone automatically."
    box_bottom
    blank
    say "Log of this phase: ${LOG_MAIN}"
    blank
}

# ==========================================================================
#  PHASE 2 - INSTALL (unattended)
# ==========================================================================
phase2_install() {
    (( EUID == 0 )) || die "Phase 2 has to run as root: sudo ${SCRIPT_NAME} install"
    load_state || die "No preparation found - run '${SCRIPT_NAME} prepare' first."
    [[ "$ST_PHASE" == "prepared" || "$ST_PHASE" == "installing" ]] \
        || die "State is '${ST_PHASE}' - nothing to install. See '${SCRIPT_NAME} status'."
    [[ -f "$ST_DRIVER_FILE" ]] || die "Driver package is gone: ${ST_DRIVER_FILE}"

    LOG_DIR="${ST_LOG_DIR:-$LOG_DIR}"
    OPT_YES=1                       # no questions in phase 2, ever
    start_log "install"
    banner "phase 2: install"

    ST_PHASE="installing"; save_state

    say "${C_DIM}Unattended installation. Every step goes into"
    say "${LOG_DIR}${C_RESET}"
    blank
    box_top
    box_kv "Driver" "$(basename "$ST_DRIVER_FILE")" "$C_NV"
    box_kv "Version" "$ST_DRIVER_VERSION"
    box_kv "Kernel" "$ST_KERNEL"
    box_kv "Old driver" "${ST_PREV_DRIVER:-none}"
    box_kv "Display manager" "${ST_DM_UNIT:-none}"
    box_bottom

    # ---- 1. stop the desktop --------------------------------------------
    heading "Stopping the desktop"
    if (( OPT_KEEP_DESKTOP )); then
        warn "--keep-desktop: display manager stays up"
    elif [[ -n "$ST_DM_UNIT" ]]; then
        info "5 seconds until ${ST_DM_UNIT} is stopped..."
        sleep 5
        run "Stopping ${ST_DM_UNIT}" systemctl stop "$ST_DM_UNIT" || warn "Could not stop it"
        run "Switching to multi-user.target" systemctl isolate multi-user.target \
            || warn "isolate failed - continuing"
        sleep 2
    else
        ok "No display manager active"
    fi

    # ---- 1b. Debian's own driver ----------------------------------------
    if [[ -n "${ST_PURGE_PKGS:-}" ]]; then
        heading "Removing the distribution driver"
        # No download needed - purging works offline.
        local _purge=()
        read -r -a _purge <<<"$ST_PURGE_PKGS"
        if run "Removing ${#_purge[@]} packages" \
               env DEBIAN_FRONTEND=noninteractive apt-get -y purge "${_purge[@]}"; then
            run "Cleaning up dependencies" \
                env DEBIAN_FRONTEND=noninteractive apt-get -y autoremove || true
        else
            warn "Removal reported problems - continuing anyway"
        fi
    fi

    # ---- 2. nouveau ------------------------------------------------------
    heading "Disabling nouveau"
    write_root /etc/modprobe.d/blacklist-nouveau.conf "$(cat <<'EOF'
# Written by install-nvidia-driver.sh
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF
)"$'\n'
    if (( OPT_DRYRUN )); then
        info "Would write /etc/modprobe.d/blacklist-nouveau.conf"
    else
        ok "Wrote /etc/modprobe.d/blacklist-nouveau.conf"
    fi
    if module_loaded nouveau; then
        run "Unloading nouveau" modprobe -r nouveau || warn "nouveau is busy - the reboot will handle it"
    else
        ok "nouveau is not loaded"
    fi
    if command -v update-initramfs >/dev/null 2>&1; then
        run "Rebuilding the initramfs" update-initramfs -u || die "update-initramfs failed"
    fi

    # ---- 3. GRUB ---------------------------------------------------------
    heading "GRUB kernel command line"
    patch_grub

    # ---- 4. unload an old driver ----------------------------------------
    heading "Old driver"
    local m
    for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
        if module_loaded "$m"; then
            run "Unloading ${m}" modprobe -r "$m" || warn "${m} is busy - the installer will handle it"
        fi
    done
    ok "Old kernel modules handled"

    # ---- 5. the actual installation --------------------------------------
    heading "Installing the driver"
    local args=(--silent --dkms --no-questions --ui=none --no-x-check --no-nouveau-check)
    info "nvidia-installer ${args[*]}"
    if ! run "Installing driver ${ST_DRIVER_VERSION} (takes a few minutes)" \
             bash "$ST_DRIVER_FILE" "${args[@]}"; then
        blank
        fail "The NVIDIA installer failed."
        [[ -f /var/log/nvidia-installer.log ]] && \
            tail -n 25 /var/log/nvidia-installer.log >>"$LOG_DETAIL" 2>/dev/null || true
        show_log_tail
        do_rollback "nvidia-installer returned an error"
        write_report "FAILED" "The NVIDIA installer could not install the driver. Everything was undone."
        blank
        say "Log: ${LOG_MAIN}"
        say "Installer log: /var/log/nvidia-installer.log"
        blank
        bring_desktop_back
        exit 1
    fi

    # ---- 6. quick check --------------------------------------------------
    heading "First check"
    if command -v nvidia-smi >/dev/null 2>&1; then
        ok "nvidia-smi installed"
    else
        warn "nvidia-smi not found - the check after the reboot will tell"
    fi

    ST_PHASE="installed"; save_state
    sh_root systemctl enable "$VERIFY_UNIT" || warn "Could not enable the post-reboot check"
    ok "Post-reboot check armed"

    write_report "INSTALLED" "Driver ${ST_DRIVER_VERSION} installed. Rebooting now; the check runs automatically afterwards."

    heading "Reboot"
    if (( OPT_NO_REBOOT )); then
        warn "--no-reboot: please reboot yourself."
        return 0
    fi
    do_reboot 10
}

# Reboot after <n> seconds - unless this is a dry run.
do_reboot() {
    local secs="${1:-10}"
    if (( OPT_DRYRUN )); then
        info "Dry run - would reboot now"
        return 0
    fi
    info "Rebooting in ${secs} seconds..."
    sleep "$secs"
    systemctl reboot
}

patch_grub() {
    local grubfile=/etc/default/grub
    local params="nouveau.modeset=0 modprobe.blacklist=nouveau"
    if [[ ! -f "$grubfile" ]]; then warn "No ${grubfile} - skipping"; return 0; fi
    local current missing=() p
    current="$(grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX=' "$grubfile" | tail -1 || true)"
    for p in $params; do [[ "$current" == *"$p"* ]] || missing+=("$p"); done
    if (( ${#missing[@]} == 0 )); then
        ok "GRUB already has the nouveau parameters"
    elif (( OPT_DRYRUN )); then
        info "Would add to GRUB_CMDLINE_LINUX: ${missing[*]}"
    else
        if grep -q '^GRUB_CMDLINE_LINUX=' "$grubfile"; then
            sed -i "s|^GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 ${missing[*]}\"|" "$grubfile"
        else
            printf '\nGRUB_CMDLINE_LINUX="%s"\n' "${missing[*]}" >>"$grubfile"
        fi
        ok "Added: ${missing[*]}"
    fi
    if command -v update-grub >/dev/null 2>&1; then
        run "Regenerating the GRUB config" update-grub || die "update-grub failed"
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        run "Regenerating the GRUB config" grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig failed"
    fi
}

bring_desktop_back() {
    [[ -n "${ST_DM_UNIT:-}" ]] || return 0
    run "Starting the desktop again" systemctl isolate "${ST_DEFAULT_TARGET:-graphical.target}" \
        || run "Starting ${ST_DM_UNIT}" systemctl start "$ST_DM_UNIT" || true
}

# ==========================================================================
#  ROLLBACK
# ==========================================================================
do_rollback() {
    local reason="${1:-manual}"
    ERR_GUARD=1                      # no recursion through the ERR trap
    blank
    box_top
    box_line "${C_YELLOW}${C_BOLD}Undoing the changes${C_RESET}"
    box_sep
    box_line "Reason: $(fit "$reason" $((BOX_W-12)))"
    box_bottom
    blank

    # 1. uninstall the driver
    if command -v nvidia-installer >/dev/null 2>&1; then
        run "Removing the NVIDIA driver" nvidia-installer --uninstall --silent || \
            warn "nvidia-installer --uninstall reported problems"
    elif [[ -n "${ST_DRIVER_FILE:-}" && -f "${ST_DRIVER_FILE}" ]]; then
        run "Removing the NVIDIA driver" bash "$ST_DRIVER_FILE" --uninstall --silent || \
            warn "Uninstall reported problems"
    else
        info "No installed driver found to remove"
    fi

    # 2. GRUB back
    if [[ -n "${ST_GRUB_BACKUP:-}" && -f "${ST_GRUB_BACKUP}" ]]; then
        run "Restoring /etc/default/grub" cp -a "$ST_GRUB_BACKUP" /etc/default/grub || true
        if command -v update-grub >/dev/null 2>&1; then
            run "Regenerating the GRUB config" update-grub || true
        fi
    fi

    # 3. nouveau blacklist back
    if [[ "${ST_NOUVEAU_CREATED:-0}" == "1" && -f /etc/modprobe.d/blacklist-nouveau.conf ]]; then
        run "Removing the nouveau blacklist" rm -f /etc/modprobe.d/blacklist-nouveau.conf || true
        command -v update-initramfs >/dev/null 2>&1 && \
            run "Rebuilding the initramfs" update-initramfs -u || true
    else
        info "nouveau blacklist existed before - left untouched"
    fi

    # 4. Debian's packages back
    if [[ -n "${ST_PURGE_PKGS:-}" ]]; then
        local _restore=()
        read -r -a _restore <<<"$ST_PURGE_PKGS"
        if run "Reinstalling ${#_restore[@]} distribution packages" \
               env DEBIAN_FRONTEND=noninteractive apt-get -y install "${_restore[@]}"; then
            ok "Distribution driver is back"
        else
            warn "Could not reinstall the distribution driver (no internet?)"
            hint "Do it by hand once you are online:"
            hint "  sudo apt-get install ${ST_PURGE_PKGS}"
        fi
    fi

    # 5. desktop back on
    if [[ -n "${ST_DM_UNIT:-}" ]]; then
        run "Enabling ${ST_DM_UNIT}" systemctl enable "$ST_DM_UNIT" || true
    fi
    if [[ -n "${ST_DEFAULT_TARGET:-}" ]]; then
        run "Default target: ${ST_DEFAULT_TARGET}" systemctl set-default "$ST_DEFAULT_TARGET" || true
    fi

    # 6. no more post-reboot check
    if systemctl is-enabled --quiet "$VERIFY_UNIT" 2>/dev/null; then
        run "Disabling the post-reboot check" systemctl disable "$VERIFY_UNIT" || true
    fi

    ST_PHASE="rolled-back"; ST_ROLLED_BACK=1; save_state
    blank
    ok "Everything undone."
    ERR_GUARD=0
}

cmd_rollback() {
    (( EUID == 0 )) || die "Rollback needs root: sudo ${SCRIPT_NAME} rollback"
    load_state || warn "No state file - undoing what can be found."
    start_log "rollback"
    banner "rollback"
    do_rollback "started by hand"
    write_report "ROLLED-BACK" "The installation was undone by hand."
    blank
    say "Log: ${LOG_MAIN}"
    blank
    if confirm "Reboot now?" y; then do_reboot 5; fi
}

# ==========================================================================
#  PHASE 3 - VERIFY (after the reboot)
# ==========================================================================
phase3_verify() {
    (( EUID == 0 )) || die "The check needs root."
    load_state || exit 0
    [[ "$ST_PHASE" == "installed" ]] || exit 0

    LOG_DIR="${ST_LOG_DIR:-$LOG_DIR}"
    OPT_YES=1
    start_log "verify"
    banner "phase 3: check after the reboot"

    # give the desktop time to come up
    local waited=0
    while (( waited < 60 )); do
        if [[ -n "${ST_DM_UNIT:-}" ]] && systemctl is-active --quiet "$ST_DM_UNIT"; then break; fi
        systemctl is-active --quiet graphical.target && break
        sleep 5; waited=$(( waited + 5 ))
    done
    info "Waited ${waited}s for the session"

    detect_installed_driver

    local problems=()
    heading "Checks"
    box_top
    box_line "${C_BOLD}Does the driver work?${C_RESET}"
    box_sep

    if module_loaded nvidia; then
        check_ok "Kernel module 'nvidia' is loaded"
    else
        check_bad "Kernel module 'nvidia' is NOT loaded"; problems+=("module not loaded")
    fi

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        check_ok "nvidia-smi works: $(nvidia-smi -L 2>/dev/null | head -1 | cut -c1-40)"
    else
        check_bad "nvidia-smi does not work"; problems+=("nvidia-smi fails")
    fi

    if [[ -n "$INSTALLED_DRIVER" ]]; then
        if [[ "$INSTALLED_DRIVER" == "$ST_DRIVER_VERSION" ]]; then
            check_ok "Version ${INSTALLED_DRIVER} as expected"
        else
            check_warn "Version ${INSTALLED_DRIVER}, expected ${ST_DRIVER_VERSION}"
        fi
    else
        check_bad "No driver version readable"; problems+=("no version")
    fi

    if [[ -n "${ST_DM_UNIT:-}" ]]; then
        if systemctl is-active --quiet "$ST_DM_UNIT"; then
            check_ok "Display manager ${ST_DM_UNIT} is running"
        else
            check_bad "Display manager ${ST_DM_UNIT} is NOT running"; problems+=("desktop dead")
        fi
    fi

    if systemctl is-failed --quiet 'graphical.target' 2>/dev/null; then
        check_bad "graphical.target failed"; problems+=("graphical.target failed")
    else
        check_ok "System reached its normal target"
    fi
    box_bottom

    if (( ${#problems[@]} == 0 )); then
        heading "Result"
        ok "The driver works."
        ST_PHASE="verified"; save_state
        run "Removing the post-reboot check" systemctl disable "$VERIFY_UNIT" || true
        write_report "OK" "Driver ${ST_DRIVER_VERSION} is installed and works. Nothing else to do."
        blank; say "Log: ${LOG_MAIN}"; blank
        exit 0
    fi

    heading "Result"
    fail "Problems found: ${problems[*]}"
    blank
    warn "The installation is being undone so you get a working system back."
    do_rollback "check after the reboot failed: ${problems[*]}"
    write_report "FAILED-ROLLED-BACK" \
        "The driver did not work after the reboot (${problems[*]}). Everything was undone. Details: ${LOG_MAIN}"
    run "Disabling the post-reboot check" systemctl disable "$VERIFY_UNIT" || true
    blank
    do_reboot 15
}

# ==========================================================================
#  Report + status
# ==========================================================================
write_report() {
    local result="$1" text="$2"
    (( OPT_DRYRUN )) && return 0
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    {
        printf '=====================================================\n'
        printf ' NVIDIA driver installation - %s\n' "$result"
        printf '=====================================================\n'
        printf 'Time        : %s\n' "$(date -Is)"
        printf 'Driver      : %s\n' "${ST_DRIVER_VERSION:-?}"
        printf 'Package     : %s\n' "${ST_DRIVER_FILE:-?}"
        printf 'Kernel      : %s\n' "${ST_KERNEL:-?}"
        printf 'Old driver  : %s\n' "${ST_PREV_DRIVER:-?}"
        printf '\n%s\n\n' "$text"
        printf 'Logs        : %s\n' "$LOG_DIR"
        printf 'State       : %s\n' "$STATE_FILE"
        printf 'Undo by hand: %s rollback\n' "$SYSTEM_COPY"
    } >"$REPORT_FILE" 2>/dev/null || true
    chmod 0644 "$REPORT_FILE" 2>/dev/null || true
}

cmd_status() {
    banner "status"
    if ! load_state; then
        info "No installation prepared or run yet."
        blank; say "  Start with: ${C_BOLD}${SCRIPT_NAME}${C_RESET}"; blank
        return 0
    fi
    detect_installed_driver
    box_top
    box_line "${C_BOLD}Installation state${C_RESET}"
    box_sep
    local color="$C_NV"
    case "$ST_PHASE" in
        prepared)    color="$C_BLUE" ;;
        installing)  color="$C_YELLOW" ;;
        installed)   color="$C_YELLOW" ;;
        verified)    color="$C_NV" ;;
        rolled-back) color="$C_RED" ;;
    esac
    box_kv "Phase" "$ST_PHASE" "$color"
    box_kv "Driver" "${ST_DRIVER_VERSION:-?}"
    box_kv "Package" "$(basename "${ST_DRIVER_FILE:-?}")"
    box_kv "Started" "${ST_STARTED:-?}"
    box_kv "Loaded now" "${INSTALLED_DRIVER:-none}"
    box_kv "Logs" "${ST_LOG_DIR:-$LOG_DIR}"
    box_bottom
    blank
    case "$ST_PHASE" in
        prepared)   info "Phase 2 has not run yet: ${C_BOLD}sudo ${SCRIPT_NAME} install${C_RESET}" ;;
        installing) info "Installation is running: ${C_BOLD}sudo screen -r ${SCREEN_NAME}${C_RESET}" ;;
        installed)  info "Installed - the check runs after the reboot." ;;
        verified)   ok   "Everything done, the driver works." ;;
        rolled-back) warn "The installation was undone. See ${REPORT_FILE}" ;;
    esac
    if [[ -f "$REPORT_FILE" ]]; then
        blank; say "${C_DIM}Report: ${REPORT_FILE}${C_RESET}"
    fi
    blank
}

cmd_attach() {
    command -v screen >/dev/null 2>&1 || die "screen is not installed."
    if [[ -n "$SUDO" ]] || (( EUID == 0 )); then :; else need_root || true; fi
    exec ${SUDO:+sudo} screen -r "$SCREEN_NAME"
}

# ==========================================================================
#  Main
# ==========================================================================
main() {
    case "$CMD" in
        prepare)  need_root || true; phase1_prepare ;;
        install)  phase2_install ;;
        verify)   phase3_verify ;;
        rollback) cmd_rollback ;;
        status)   need_root || true; cmd_status ;;
        attach)   cmd_attach ;;
        *)        usage; exit 2 ;;
    esac
}

main "$@"
