#!/usr/bin/env bash
# ============================================================
# GODSPIDER VPS INSTALLER
# Installs LXD on Ubuntu/Debian and provides a simple VPS menu.
# ============================================================

set -Eeuo pipefail

# ---------- Colors ----------
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
MAG='\033[0;35m'
CYN='\033[0;36m'
WHT='\033[1;37m'
NC='\033[0m'

log()  { printf '%b[+]%b %s\n' "$GRN" "$NC" "$*"; }
info() { printf '%b[i]%b %s\n' "$CYN" "$NC" "$*"; }
warn() { printf '%b[!]%b %s\n' "$YEL" "$NC" "$*"; }
fail() { printf '%b[x]%b %s\n' "$RED" "$NC" "$*" >&2; }
die()  { fail "$*"; exit 1; }

on_error() {
    local code=$?
    fail "Installation stopped at line ${BASH_LINENO[0]} (exit code ${code})."
    exit "$code"
}
trap on_error ERR

banner() {
    clear 2>/dev/null || true
    printf '%b' "$MAG"
    cat <<'BANNER'
   ____           _ ____        _     _
  / ___|  ___  __| / ___| _ __ (_) __| | ___ _ __
  \___ \ / _ \/ _` \___ \| '_ \| |/ _` |/ _ \ '__|
   ___) |  __/ (_| |___) | |_) | | (_| |  __/ |
  |____/ \___|\__,_|____/| .__/|_|\__,_|\___|_|
                         |_|
BANNER
    printf '%b' "$NC"
    echo
    printf '%bGODSPIDER VPS MANAGER%b\n' "$WHT" "$NC"
    printf '%bUbuntu + Debian | LXD/LXC Container Hosting%b\n' "$CYN" "$NC"
    printf '%s\n\n' '------------------------------------------------------------'
}

need_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash install.sh"
}

detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot identify this Linux distribution."
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) log "Detected ${PRETTY_NAME:-$ID}." ;;
        *) die "Unsupported OS: ${PRETTY_NAME:-unknown}. Ubuntu and Debian are supported." ;;
    esac
    [[ "$(dpkg --print-architecture)" =~ ^(amd64|arm64|armhf)$ ]] ||
        warn "This CPU architecture may not be supported by every LXD image."
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    log "Updating package lists..."
    apt-get update
    log "Installing required packages..."
    apt-get install -y snapd curl ca-certificates jq uidmap
    systemctl enable --now snapd.socket
    if [[ "${ID}" == "debian" ]]; then
        ln -sfn /var/lib/snapd/snap /snap
    fi
    log "Waiting for snap service..."
    for _ in {1..30}; do
        if snap version >/dev/null 2>&1; then break; fi
        sleep 2
    done
    snap version >/dev/null 2>&1 || die "Snap is not responding. Reboot and run the installer again."
}

install_lxd() {
    if ! command -v lxd >/dev/null 2>&1; then
        log "Installing LXD from the Snap Store..."
        snap install lxd
    else
        info "LXD command already exists; skipping installation."
    fi

    systemctl enable --now snap.lxd.daemon.service 2>/dev/null || true
    log "Adding root to the lxd group..."
    getent group lxd >/dev/null || groupadd --system lxd
    usermod -aG lxd root || true

    if ! lxc info >/dev/null 2>&1; then
        log "Initializing LXD with its automatic configuration..."
        lxd init --auto
    else
        info "LXD is already initialized."
    fi

    lxc project switch default >/dev/null 2>&1 || true
    log "LXD installation and initialization finished."
}

require_lxd() {
    command -v lxc >/dev/null 2>&1 || die "LXD is not installed. Run the installer first."
    lxc info >/dev/null 2>&1 || die "LXD daemon is not ready. Try: systemctl restart snap.lxd.daemon"
}

valid_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]
}

create_vps() {
    require_lxd
    echo
    read -rp "VPS name (example: gs-vps01): " name
    valid_name "$name" || { warn "Use 1-63 letters, numbers, dots or hyphens; start with a letter/number."; return; }

    if lxc info "$name" >/dev/null 2>&1; then
        warn "An instance named '$name' already exists."
        return
    fi

    echo
    echo "Choose VPS operating system:"
    echo "  1) Ubuntu 24.04 LTS"
    echo "  2) Ubuntu 22.04 LTS"
    echo "  3) Debian 13"
    echo "  4) Debian 12"
    read -rp "Choice [1-4]: " os_choice
    case "$os_choice" in
        1) image="images:ubuntu/24.04" ;;
        2) image="images:ubuntu/22.04" ;;
        3) image="images:debian/13" ;;
        4) image="images:debian/12" ;;
        *) warn "Invalid operating system choice."; return ;;
    esac

    read -rp "CPU cores [2]: " cpu
    cpu="${cpu:-2}"
    [[ "$cpu" =~ ^[1-9][0-9]*$ ]] || { warn "CPU must be a positive whole number."; return; }

    read -rp "RAM in GiB [2]: " ram
    ram="${ram:-2}"
    [[ "$ram" =~ ^[1-9][0-9]*$ ]] || { warn "RAM must be a positive whole number."; return; }

    echo
    warn "Creating '$name' with ${cpu} CPU core(s) and ${ram} GiB RAM."
    read -rp "Continue? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; return; }

    log "Downloading image and creating VPS..."
    lxc launch "$image" "$name" \
        --config "limits.cpu=${cpu}" \
        --config "limits.memory=${ram}GiB"

    echo
    log "VPS '$name' was created."
    lxc list "$name"
    echo
    info "Open its console with: lxc exec ${name} -- bash"
    info "This container uses LXD's private network by default; it is not automatically exposed to the public internet."
}

list_vps() {
    require_lxd
    echo
    lxc list
}

start_vps() {
    require_lxd
    read -rp "VPS name to start: " name
    lxc start "$name"
    log "Start command sent for '$name'."
}

stop_vps() {
    require_lxd
    read -rp "VPS name to stop: " name
    lxc stop "$name"
    log "Stop command sent for '$name'."
}

delete_vps() {
    require_lxd
    read -rp "VPS name to delete: " name
    lxc info "$name" >/dev/null 2>&1 || { warn "VPS '$name' was not found."; return; }
    warn "This permanently deletes the container and its data."
    read -rp "Type DELETE to confirm: " confirm
    [[ "$confirm" == "DELETE" ]] || { info "Cancelled."; return; }
    lxc delete --force "$name"
    log "VPS '$name' deleted."
}

show_help() {
    echo
    printf '%bUseful commands%b\n' "$WHT" "$NC"
    echo "  lxc list                         List VPS containers"
    echo "  lxc exec NAME -- bash            Open a VPS shell"
    echo "  lxc start NAME                   Start a VPS"
    echo "  lxc stop NAME                    Stop a VPS"
    echo "  lxc delete --force NAME          Delete a VPS"
    echo "  lxc info                         Show LXD host information"
    echo
    info "Public SSH access and firewall rules are intentionally not configured automatically."
}

manager_menu() {
    while true; do
        echo
        printf '%bGODSPIDER VPS MANAGER%b\n' "$WHT" "$NC"
        echo "  1) Create a VPS"
        echo "  2) List VPS containers"
        echo "  3) Start a VPS"
        echo "  4) Stop a VPS"
        echo "  5) Delete a VPS"
        echo "  6) Show useful commands"
        echo "  0) Exit"
        echo
        read -rp "Select an option: " choice
        case "$choice" in
            1) create_vps ;;
            2) list_vps ;;
            3) start_vps ;;
            4) stop_vps ;;
            5) delete_vps ;;
            6) show_help ;;
            0) echo "GodSpider VPS Manager closed."; break ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

main() {
    banner
    need_root
    detect_os
    install_dependencies
    install_lxd
    echo
    log "GodSpider VPS setup is complete."
    info "You can reopen the manager by running: sudo bash install.sh"
    manager_menu
}

main "$@"
