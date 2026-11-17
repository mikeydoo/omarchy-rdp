#!/bin/bash
# Install (or bring up to date) the RDP remote session on Omarchy: a second, headless
# Hyprland session reached over RDP on port 3389, separate from the desk session.
# Normally run from the plugin's panel (Set up / Repair / Uninstall), which opens it in a
# terminal; it works the same from a shell. See README.md for how it works.
#
#   ./install.sh                  install, or update after changes / Omarchy updates
#   ./install.sh --lan <CIDR>     allow RDP from this network (default: this machine's LAN)
#   ./install.sh --uninstall      remove everything this script added (asks first;
#                                 --yes to skip asking)
#
# Runs as you; uses sudo only for packages, lingering and the firewall. Nothing stock is
# edited: no files in /usr/share/omarchy, ~/.config/hypr, ~/.config/omarchy or
# /etc/sddm.conf.d are changed. Safe to re-run.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
HEADLESS=$HOME/.local/share/hyprland-headless
RDP_LIB=$HEADLESS/lib
BACKUP_DIR=$HOME/.local/state/omarchy-rdp/backup-$(date +%Y%m%d-%H%M%S)
HYPR_RDP_MIN=0.1.8 # first release that sizes its screen to the client with Lua config
UFW_COMMENT=omarchy-rdp
OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}

# --- output ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  c_blue=$'\e[34m' c_green=$'\e[32m' c_yellow=$'\e[33m' c_red=$'\e[31m' c_dim=$'\e[2m' c_off=$'\e[0m'
else
  c_blue='' c_green='' c_yellow='' c_red='' c_dim='' c_off=''
fi
section() { printf '\n%s==> %s%s\n' "$c_blue" "$1" "$c_off"; }
info() { printf '    %s\n' "$1"; }
ok() { printf '  %s✓%s %s\n' "$c_green" "$c_off" "$1"; }
skip() { printf '  %s· %s%s\n' "$c_dim" "$1" "$c_off"; }
WARNINGS=()
warn() {
  printf '  %s!%s %s\n' "$c_yellow" "$c_off" "$1"
  WARNINGS+=("$1")
}
die() {
  printf '%sError:%s %s\n' "$c_red" "$c_off" "$1" >&2
  exit 1
}

# --- arguments -------------------------------------------------------------------------
LAN=''
MODE=install
ASSUME_YES=0
while (($#)); do
  case $1 in
    --lan)
      [[ ${2:-} ]] || die "--lan needs a network, e.g. --lan 192.168.0.0/24"
      LAN=$2
      shift 2
      ;;
    --lan=*)
      LAN=${1#--lan=}
      shift
      ;;
    --uninstall)
      MODE=uninstall
      shift
      ;;
    --yes | -y)
      ASSUME_YES=1
      shift
      ;;
    -h | --help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# Every service in files/, in start order.
UNITS=()
for u in hyprland-remote.service hypr-rdp-remote.service hypr-rdp-shared.service rdp-gate.service; do
  [[ -f $KIT/files/config/systemd/user/$u ]] && UNITS+=("$u")
done

# This machine's LAN, as a network (e.g. 192.168.0.0/24), from the default route.
detect_lan() {
  local dev addr
  dev=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  [[ -n $dev ]] || return 1
  addr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4; exit}')
  [[ -n $addr ]] || return 1
  python3 -I -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$addr"
}

ufw_active() { sudo ufw status 2>/dev/null | grep -q '^Status: active'; }

# Numbers of the UFW rules this script added (by comment), highest first.
ufw_rule_numbers() {
  # lines look like "[ 5] 3389/tcp   ALLOW IN   192.168.0.0/24   # omarchy-rdp"
  sudo ufw status numbered 2>/dev/null |
    sed -n "/# $UFW_COMMENT\$/s/^\[ *\([0-9][0-9]*\)\].*/\1/p" | sort -rn
}

# ===========================================================================================
# Uninstall
# ===========================================================================================
if [[ $MODE == uninstall ]]; then
  ((EUID != 0)) || die "run as your user, not root"
  cat <<EOF
This removes the RDP remote session:
  - stops and removes the services: ${UNITS[*]}
  - removes $HEADLESS (launcher, patched libaquamarine)
  - removes ~/.config/hypr-rdp (config.toml is backed up first)
  - removes the UFW rule(s) for port 3389
It leaves the hypr-rdp package and lingering alone (commands to remove them are printed).
EOF
  answer=y
  ((ASSUME_YES)) || read -r -p "Remove it? [y/N] " answer
  [[ $answer == [yY]* ]] || {
    echo "Nothing removed."
    exit 0
  }

  section "Services"
  for u in "${UNITS[@]}"; do
    systemctl --user disable --now "$u" 2>/dev/null && ok "stopped and disabled $u" || skip "$u was not enabled"
    rm -f "$HOME/.config/systemd/user/$u"
  done
  systemctl --user daemon-reload

  section "Files"
  if [[ -f $HOME/.config/hypr-rdp/config.toml ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$HOME/.config/hypr-rdp/config.toml" "$BACKUP_DIR/"
    info "config.toml backed up to $BACKUP_DIR/"
  fi
  rm -rf "$HEADLESS" "$HOME/.config/hypr-rdp"
  ok "removed $HEADLESS and ~/.config/hypr-rdp"
  rm -rf "${XDG_RUNTIME_DIR:-/run/user/$UID}/rdp-sessions"

  section "Firewall"
  if ufw_active; then
    nums=$(ufw_rule_numbers)
    if [[ -n $nums ]]; then
      for n in $nums; do sudo ufw --force delete "$n" >/dev/null; done
      ok "removed the UFW rule(s) for port 3389"
    else
      skip "no UFW rule for port 3389 found"
    fi
  else
    skip "UFW is not active"
  fi

  cat <<EOF

Removed. Left in place (remove by hand if nothing else needs them):
  sudo loginctl disable-linger "$USER"
  sudo pacman -R hypr-rdp
EOF
  exit 0
fi

# ===========================================================================================
# Install / update
# ===========================================================================================

# --- 2.1 checks before doing anything ------------------------------------------------------
section "Checks"
((EUID != 0)) || die "run as your user, not root (it uses sudo where needed)"
command -v omarchy >/dev/null && [[ -d $OMARCHY_PATH/default/hypr ]] ||
  die "Omarchy not found (no 'omarchy' command or $OMARCHY_PATH/default/hypr)"
RENDER_NODE=$(ls /dev/dri/renderD* 2>/dev/null | head -1 || true)
[[ -n $RENDER_NODE ]] ||
  die "no GPU render node (/dev/dri/renderD*). In a VM, use a VirGL / virtio-gl display."
# The remote session's Hyprland config (hyprland-remote.lua) loads Omarchy's defaults with
# their autostart stubbed out; that relies on omarchy.lua loading it as a module.
grep -q 'require("default.hypr.autostart")' "$OMARCHY_PATH/default/hypr/omarchy.lua" ||
  die "Omarchy's default/hypr/omarchy.lua no longer requires default.hypr.autostart; the remote session's Hyprland config needs updating first"
ok "Omarchy $(omarchy version 2>/dev/null || echo '?'), render node $RENDER_NODE"

# --- 2.2 packages --------------------------------------------------------------------------
section "Packages"
build_tools=(cmake hyprwayland-scanner)
missing=()
for p in "${build_tools[@]}"; do pacman -Qq "$p" &>/dev/null || missing+=("$p"); done
if ((${#missing[@]})); then
  info "installing: ${missing[*]}"
  omarchy pkg add "${missing[@]}" || die "couldn't install ${missing[*]}"
  ok "installed ${missing[*]}"
else
  skip "build tools already installed"
fi

rdp_ver=$(pacman -Q hypr-rdp 2>/dev/null | awk '{print $2}' || true)
if [[ -z $rdp_ver ]]; then
  info "installing hypr-rdp from the AUR (Rust build, takes a few minutes)"
  omarchy pkg aur add hypr-rdp || die "couldn't install hypr-rdp"
  ok "hypr-rdp $(pacman -Q hypr-rdp | awk '{print $2}') installed"
elif (($(vercmp "$rdp_ver" "$HYPR_RDP_MIN") < 0)); then
  # omarchy pkg aur add only installs missing packages, it never upgrades
  info "upgrading hypr-rdp $rdp_ver (need $HYPR_RDP_MIN+) from the AUR"
  yay -S --needed --noconfirm hypr-rdp || die "couldn't upgrade hypr-rdp"
  ok "hypr-rdp $(pacman -Q hypr-rdp | awk '{print $2}') installed"
else
  skip "hypr-rdp $rdp_ver already installed"
fi
rdp_ver=$(pacman -Q hypr-rdp | awk '{print $2}')
(($(vercmp "$rdp_ver" "$HYPR_RDP_MIN") >= 0)) ||
  die "hypr-rdp $rdp_ver is older than $HYPR_RDP_MIN (the AUR may not have caught up)"

# --- 2.3 + 2.4 files ---------------------------------------------------------------------------
# install_file SRC DEST MODE: install SRC with @HOME@ filled in, unless DEST already matches.
# A different DEST is backed up first. Returns 1 when nothing changed.
install_file() {
  local src=$1 dest=$2 mode=$3 tmp rel
  tmp=$(mktemp)
  sed "s|@HOME@|$HOME|g" "$src" >"$tmp"
  if [[ -f $dest ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    [[ $(stat -c %a "$dest") == "$mode" ]] || chmod "$mode" "$dest"
    return 1
  fi
  if [[ -e $dest || -L $dest ]]; then
    rel=${dest#"$HOME"/}
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -a "$dest" "$BACKUP_DIR/$rel"
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$tmp" "$dest"
  chmod "$mode" "$dest"
}

section "Files"
files_changed=0
units_changed=0

# Mirror files/: files/config/** -> ~/.config/**, files/local/** -> ~/.local/**
# (the launcher, the patched-libaquamarine builder and its patch go to
# ~/.local/share/hyprland-headless, so the remote session can rebuild the lib after
# updates without this repo)
while IFS= read -r -d '' src; do
  rel=${src#"$KIT"/files/}
  dest=$HOME/.$rel
  if [[ $rel == config/hypr-rdp/config.toml || $rel == config/hypr-rdp/config-shared.toml ]]; then
    # yours to edit (fps, codec, ...): only installed when missing
    [[ -f $dest ]] && continue
    mode=600
  elif [[ -x $src ]]; then
    mode=755
  else
    mode=644
  fi
  if install_file "$src" "$dest" "$mode"; then
    files_changed=1
    info "updated ~/.$rel"
    [[ $rel == config/systemd/user/* ]] && units_changed=1
  fi
done < <(find "$KIT/files" -type f -print0 | sort -z)

((units_changed)) && systemctl --user daemon-reload
if ((files_changed)); then
  ok "files installed"
  [[ -d $BACKUP_DIR ]] && info "replaced files backed up to $BACKUP_DIR"
else
  skip "files up to date"
fi

# --- 2.3 patched libaquamarine -----------------------------------------------------------------
section "Patched libaquamarine"
# Built here so the first start is quick; afterwards hyprland-remote.service (ExecStartPre)
# and the plugin keep it in step with aquamarine updates.
aq_ver=$(pacman -Q aquamarine | awk '{print $2}' | sed 's/-.*//')
if [[ $(cat "$RDP_LIB/AQUAMARINE_VERSION" 2>/dev/null) == "$aq_ver" ]]; then
  skip "patched libaquamarine $aq_ver already built"
else
  # A failed build for this version stops the service from retrying; re-running this
  # script (e.g. after porting the patch) is the way to try again.
  rm -f "$HEADLESS/REBUILD_FAILED"
  info "building patched libaquamarine $aq_ver (a minute or two)"
  if "$HEADLESS/rebuild-if-stale.sh"; then
    ok "patched libaquamarine $aq_ver built"
  else
    warn "patched libaquamarine didn't build: the remote session can't start until it does (see README.md)"
  fi
fi

# --- 2.6 lingering -------------------------------------------------------------------------
section "Lingering"
if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) == yes ]]; then
  skip "lingering already on"
else
  sudo loginctl enable-linger "$USER"
  ok "lingering on: the remote session starts at boot and survives logging out at the desk"
fi

# --- 2.7 firewall ----------------------------------------------------------------------------
section "Firewall"
if ! ufw_active; then
  skip "UFW is not active: nothing to open"
else
  if [[ -z $LAN ]]; then
    LAN=$(detect_lan) || die "couldn't work out this machine's LAN: pass --lan <CIDR>"
  fi
  python3 -I -c 'import ipaddress, sys; ipaddress.ip_network(sys.argv[1])' "$LAN" 2>/dev/null ||
    die "--lan $LAN is not a network (e.g. 192.168.0.0/24)"
  if sudo ufw status | grep -E "^3389/tcp +ALLOW( IN)? +$LAN( |$)" -q; then
    skip "RDP (3389/tcp) already allowed from $LAN"
  else
    old=$(ufw_rule_numbers)
    if [[ -n $old ]]; then
      for n in $old; do sudo ufw --force delete "$n" >/dev/null; done
      info "removed the previous omarchy-rdp rule(s)"
    fi
    sudo ufw allow from "$LAN" to any port 3389 proto tcp comment "$UFW_COMMENT" >/dev/null
    ok "RDP (3389/tcp) allowed from $LAN"
  fi
fi

# --- 2.8 warn-only checks --------------------------------------------------------------------
section "Checks"
[[ -f /etc/pam.d/hypr-rdp ]] && skip "PAM config for password login present" ||
  warn "/etc/pam.d/hypr-rdp is missing (shipped by the hypr-rdp package): RDP password login won't work"
if grep -qs '^User=' /etc/sddm.conf.d/*.conf; then
  info "SDDM logs the desk in automatically. That's fine: only unlocking the desk cuts RDP,"
  info "so a reboot only drops an RDP client that's connected while it boots."
fi

# --- 2.9 enable and start --------------------------------------------------------------------
section "Services"
# Which mode: ~/.config/hypr-rdp/mode says "shared" (RDP shows the desk session) or is
# missing (a separate headless session). Switched with: omarchy-rdp-ctl mode shared|headless
if [[ $(cat "$HOME/.config/hypr-rdp/mode" 2>/dev/null) == shared ]]; then
  MODE_UNITS=(hypr-rdp-shared.service rdp-gate.service)
  OFF_UNITS=(hyprland-remote.service hypr-rdp-remote.service)
  info "mode: shared (RDP shows the desk session)"
else
  MODE_UNITS=(hyprland-remote.service hypr-rdp-remote.service rdp-gate.service)
  OFF_UNITS=(hypr-rdp-shared.service)
  info "mode: headless (a separate remote session)"
fi
for u in "${OFF_UNITS[@]}"; do
  [[ -f $HOME/.config/systemd/user/$u ]] || continue
  if systemctl --user is-enabled --quiet "$u" 2>/dev/null; then
    systemctl --user disable --now --quiet "$u" && ok "disabled $u (not used in this mode)"
  fi
done
for u in "${MODE_UNITS[@]}"; do
  if ! systemctl --user is-enabled --quiet "$u" 2>/dev/null; then
    systemctl --user enable --quiet "$u"
    ok "enabled $u"
  fi
done
if [[ ${MODE_UNITS[0]} == hyprland-remote.service && $(cat "$RDP_LIB/AQUAMARINE_VERSION" 2>/dev/null) != "$aq_ver" ]]; then
  warn "not starting the remote session: patched libaquamarine is missing"
elif systemctl --user is-active --quiet "${MODE_UNITS[0]}" &&
  systemctl --user is-active --quiet rdp-gate.service; then
  skip "already running: ${MODE_UNITS[*]}"
  if ((files_changed)); then
    # not restarted here: you may be running this over RDP
    info "restart them to use the new files (in headless mode this closes the remote session):"
    info "  systemctl --user restart ${MODE_UNITS[*]}"
  fi
else
  systemctl --user start "${MODE_UNITS[@]}"
  ok "started ${MODE_UNITS[*]}"
fi

# --- 2.10 summary ----------------------------------------------------------------------------
ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
section "Done"
if ((${#WARNINGS[@]})); then
  printf '  %s%d warning(s):%s\n' "$c_yellow" "${#WARNINGS[@]}" "$c_off"
  for w in "${WARNINGS[@]}"; do printf '    - %s\n' "$w"; done
fi
cat <<EOF
  Connect to ${ip:-$(uname -n)}:3389 and log in with your Linux user and password, e.g.
    xfreerdp3 /v:${ip:-$(uname -n)} /u:$USER /sec:tls /cert:ignore /dynamic-resolution
  Logs: journalctl --user -u rdp-gate -u hypr-rdp-remote -u hyprland-remote
EOF
