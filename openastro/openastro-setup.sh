#!/bin/bash
# OpenAstro layer for Raspberry Pi (3B+, 4, 5 - one arm64 image fits all).
#
# This turns a stock Raspberry Pi OS Lite (arm64, Trixie) image into the
# OpenAstro OS: a WiFi access point (OpenAstro-XXXX / 12345678), baked-in
# credentials (astro/astro, no first-boot wizard), and the plumbing
# AlpacaBridge expects. The OS runs from the microSD card. On first boot the
# SSID gains a per-board suffix from the wlan0 MAC (e.g. OpenAstro-915D) so
# multiple boards don't collide.
#
# AlpacaBridge is preinstalled from the OpenAstro apt repository
# (apt.openastro.net) and stays current with apt upgrade.
#
# The AP is a NetworkManager keyfile connection (mode=ap, ipv4.method=shared)
# - 5 GHz ch36 by default (the 3B+/4/5 onboard Broadcom radios are all
# dual-band). Set AP_BAND=bg AP_CHANNEL=6 for a 2.4 GHz fallback if
# range/mount compatibility needs it. The AP autoconnects at boot so the
# board is always reachable via its own hotspot even when it can't be
# reached over the local network. Raspberry Pi OS (Bookworm onwards) already uses
# NetworkManager for all interfaces, so unlike the Orange Pi image there is
# no systemd-networkd split: ethernet stays on NM's default DHCP.
#
# Idempotent: safe to re-run. Runs as root, either in the image-build chroot
# (build/build-openastro-image.sh) or post-flash on a booted board.

set -euo pipefail

# --- Config (override via env) ---
AP_SSID="${AP_SSID:-OpenAstro}"
AP_PASSPHRASE="${AP_PASSPHRASE:-12345678}"
AP_IP="${AP_IP:-172.24.1.1}"                # pinned (not NM's 10.42.0.1 default) so docs can give a fixed bridge IP
AP_BAND="${AP_BAND:-a}"                     # 5 GHz; "bg" = 2.4 GHz fallback
AP_CHANNEL="${AP_CHANNEL:-36}"
AP_COUNTRY="${AP_COUNTRY:-US}"

log() { echo "[openastro] $*"; }
[ "$(id -u)" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }

# ============================================================
# Packages
# ============================================================
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# network-manager and dnsmasq-base are preinstalled on RPi OS, but
# be explicit so this script also converts a stripped-down base.
apt-get install -y -qq \
    network-manager dnsmasq-base iw wireless-regdb \
    >/dev/null

# ============================================================
# WiFi access point (NetworkManager)
# ============================================================
# The AP is an NM keyfile connection with mode=ap and ipv4.method=shared -
# NM's internal dnsmasq serves DHCP/DNS and sets up NAT to whatever uplink
# exists. AlpacaBridge's WiFi manager drives this same NM setup over D-Bus
# (polkit rule ships in the AlpacaBridge .deb).
log "Configuring WiFi access point..."

# autoconnect keeps the hotspot up from boot: the board is always reachable
# at ${AP_IP} via its own AP even when the user can't log in over their LAN.
AP_UUID=$(cat /proc/sys/kernel/random/uuid)
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection <<EOF
[connection]
id=OpenAstro-AP
uuid=${AP_UUID}
type=wifi
interface-name=wlan0
autoconnect=true
# Below default (0): saved client networks are tried first; the hotspot is
# the fallback when none of them connects.
autoconnect-priority=-10
# Retry forever: with the default (4 attempts) a slow first boot can
# permanently block the AP until reboot.
autoconnect-retries=0

[wifi]
mode=ap
ssid=${AP_SSID}
band=${AP_BAND}
channel=${AP_CHANNEL}

[wifi-security]
key-mgmt=wpa-psk
psk=${AP_PASSPHRASE}

[ipv4]
method=shared
addresses=${AP_IP}/24

[ipv6]
method=disabled
EOF
chmod 600 /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection

# Keyfile was just (re)written with the generic SSID - let the suffixer run
# again on next boot.
rm -f /var/lib/openastro/ssid-set

# Per-board SSID: suffix with the last 4 hex digits of the wlan0 MAC (unique
# and burned into the SoC/radio). Runs once on first boot, before NM, so
# multiple boards at a star party don't collide on the same SSID.
cat > /usr/local/sbin/openastro-ssid <<'EOF'
#!/bin/bash
set -euo pipefail
for _ in $(seq 1 60); do
    [ -r /sys/class/net/wlan0/address ] && break
    sleep 1
done
mac=$(tr -d ':' < /sys/class/net/wlan0/address)
suffix=$(echo "${mac: -4}" | tr 'a-f' 'A-F')
[ ${#suffix} -eq 4 ] || exit 0   # no/odd MAC: keep the generic SSID
sed -i "s/^ssid=\(.*\)/ssid=\1-${suffix}/" \
    /etc/NetworkManager/system-connections/OpenAstro-AP.nmconnection
EOF
chmod 755 /usr/local/sbin/openastro-ssid

cat > /etc/systemd/system/openastro-ssid.service <<'EOF'
[Unit]
Description=OpenAstro: per-board AP SSID from wlan0 MAC
Before=NetworkManager.service
ConditionPathExists=!/var/lib/openastro/ssid-set

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openastro-ssid
ExecStartPost=/bin/mkdir -p /var/lib/openastro
ExecStartPost=/bin/touch /var/lib/openastro/ssid-set

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/NetworkManager.service.d
cat > /etc/systemd/system/NetworkManager.service.d/openastro-ssid.conf <<'EOF'
[Unit]
After=openastro-ssid.service
Wants=openastro-ssid.service
EOF
systemctl enable openastro-ssid.service >/dev/null 2>&1

# Regdom for the 5 GHz AP. On Raspberry Pi OS WiFi is soft-blocked by rfkill
# until a country is set - set it every way that sticks in a chroot.
iw reg set "${AP_COUNTRY}" 2>/dev/null || true
raspi-config nonint do_wifi_country "${AP_COUNTRY}" >/dev/null 2>&1 || true
cat > /etc/modprobe.d/openastro-regdom.conf <<EOF
options cfg80211 ieee80211_regdom=${AP_COUNTRY}
EOF
# Clear any persisted rfkill soft-block so the AP can start on first boot.
rm -f /var/lib/systemd/rfkill/*wlan* 2>/dev/null || true

# WiFi behavior for an always-on hotspot: no powersave (an AP that naps
# drops clients serving a mount all night) and no scan MAC randomization
# (keeps the radio identity stable/predictable).
cat > /etc/NetworkManager/conf.d/20-openastro-wifi.conf <<'EOF'
[connection]
wifi.powersave=2

[device]
wifi.scan-rand-mac-address=no
EOF

systemctl enable NetworkManager >/dev/null 2>&1

log "WiFi AP configured (SSID: ${AP_SSID}, band ${AP_BAND} ch${AP_CHANNEL}, ${AP_IP})."

# ============================================================
# First-boot reliability
# ============================================================
# The image build strips SSH host keys (unique per device). Regenerate them
# before sshd starts - otherwise ssh.service fails on first boot
# ("Connection refused" until a reboot). RPi OS ships its own
# regenerate_ssh_host_keys firstboot unit; this one is equivalent, ordered,
# and idempotent, so it wins the race whichever runs first.
cat > /etc/systemd/system/openastro-sshkeys.service <<'EOF'
[Unit]
Description=OpenAstro: generate SSH host keys on first boot
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/openastro-after-keys.conf <<'EOF'
[Unit]
After=openastro-sshkeys.service
Wants=openastro-sshkeys.service
EOF
systemctl enable openastro-sshkeys.service >/dev/null 2>&1
# SSH is disabled by default on RPi OS Lite - enable it.
systemctl enable ssh >/dev/null 2>&1

# Persistent journal, so first-boot failures survive a power cycle and can
# actually be debugged.
install -d -m 2755 -g systemd-journal /var/log/journal

# ============================================================
# Astro-device permissions (present from first boot, so device
# access never depends on install order of AlpacaBridge)
# ============================================================
# ZWO EAF/EFW/CAA are USB HID devices; without this, /dev/hidraw* is
# root-only until AlpacaBridge's own udev rules land AND the device is
# replugged. Shipping the rule in the image removes that ordering trap.
cat > /etc/udev/rules.d/70-openastro-zwo-hid.rules <<'EOF'
# ZWO HID accessories (EAF focuser, EFW/EFWmini filter wheels, CAA rotator)
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="03c3", GROUP="users", MODE="0666"
KERNEL=="hiddev*", ATTRS{idVendor}=="03c3", GROUP="users", MODE="0666"
EOF

# ============================================================
# System identity (turnkey - no first-boot wizard)
# ============================================================
log "Setting system identity..."
OA_HOSTNAME="${OPENASTRO_HOSTNAME:-openastro}"
OA_USER="${OPENASTRO_USER:-astro}"
OA_PASS="${OPENASTRO_PASS:-astro}"
echo "$OA_HOSTNAME" > /etc/hostname
if grep -q '^127.0.1.1' /etc/hosts; then sed -i "s/^127.0.1.1.*/127.0.1.1\t$OA_HOSTNAME/" /etc/hosts
else echo -e "127.0.1.1\t$OA_HOSTNAME" >> /etc/hosts; fi
OA_GROUPS=""
for g in sudo dialout plugdev audio video netdev gpio i2c spi; do
    getent group "$g" >/dev/null && OA_GROUPS="${OA_GROUPS:+$OA_GROUPS,}$g"
done
id "$OA_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G "$OA_GROUPS" "$OA_USER"
echo "${OA_USER}:${OA_PASS}" | chpasswd
# Disable RPi OS's interactive first-boot user wizard (credentials are baked
# in); it otherwise blocks boot waiting for console input on Lite.
systemctl disable userconfig.service 2>/dev/null || true
rm -f /etc/ssh/sshd_config.d/rename_user.conf 2>/dev/null || true

# ============================================================
# AlpacaBridge (preinstalled - the whole point of the appliance;
# a dark site has no internet to apt install from)
# ============================================================
# Temporarily off by default: waiting on the next AlpacaBridge release
# (new WiFi module). Flip to yes once it ships.
INSTALL_ALPACABRIDGE="${INSTALL_ALPACABRIDGE:-no}"
if [ "$INSTALL_ALPACABRIDGE" = yes ]; then
log "Installing AlpacaBridge from apt.openastro.net..."
curl -fsSL https://apt.openastro.net/repo/openastro-archive-keyring.gpg \
    | gpg --dearmor --yes -o /usr/share/keyrings/openastro-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/openastro-archive-keyring.gpg] https://apt.openastro.net trixie main" \
    > /etc/apt/sources.list.d/openastro.list
apt-get update -qq
apt-get install -y -qq alpacabridge >/dev/null
fi

log "OpenAstro OS layer complete (WiFi AP + identity + AlpacaBridge)."
