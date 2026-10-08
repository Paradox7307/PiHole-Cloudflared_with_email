#!/usr/bin/env bash
#
# Pi-hole + dnscrypt-proxy (DNS-over-HTTPS) + email through Gmail (msmtp).
#
#   * Installs dnscrypt-proxy from the distribution's repositories and makes it
#     listen on 127.0.0.1:5053, forwarding queries to Cloudflare over HTTPS.
#   * Optionally makes it Pi-hole's only upstream DNS server (Pi-hole v6).
#   * Configures msmtp so root (cron jobs, scripts, `sudo msmtp`) can send
#     email through Gmail, and sends a test email.
#
# Usage: sudo bash install_dnscrypt_with_email.sh
# Safe to run again; see README.md for details.

set -Eeuo pipefail

LISTEN_ADDR="127.0.0.1"
LISTEN_PORT="5053"
DNSCRYPT_CONF="/etc/dnscrypt-proxy/dnscrypt-proxy.toml"
DNSCRYPT_SOCKET_DROPIN="/etc/systemd/system/dnscrypt-proxy.socket.d/listen.conf"
PIHOLE_TOML="/etc/pihole/pihole.toml"
MSMTP_CONF="/etc/msmtprc"
MSMTP_ALIASES="/etc/msmtp-aliases"
OLD_CLOUDFLARED_UNIT="/etc/systemd/system/cloudflared.service"

# Answers collected by gather_input.
REMOVE_CLOUDFLARED=no
PIHOLE_MODE=none
PIHOLE_PREVIOUS_UPSTREAMS=""
WRITE_MSMTP_CONF=yes
SOURCE_EMAIL=""
SMTP_PASSWORD=""
TARGET_EMAIL=""

on_error() { printf 'Error: command failed on line %s: %s\n' "$1" "${2%%$'\n'*}" >&2; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

info() { printf '\n==> %s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

no_input() { die "No input. Run this script from an interactive terminal."; }

# ask_yes_no QUESTION DEFAULT(y|n): returns 0 for yes, 1 for no.
ask_yes_no() {
    local question=$1 default=$2 hint reply
    if [[ $default == y ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    while true; do
        read -r -p "$question $hint " reply || no_input
        case "${reply:-$default}" in
            [Yy] | [Yy][Ee][Ss]) return 0 ;;
            [Nn] | [Nn][Oo]) return 1 ;;
            *) echo "Please answer y or n." >&2 ;;
        esac
    done
}

# prompt_email VAR PROMPT: reads a valid email address into the variable VAR.
prompt_email() {
    local value
    while true; do
        read -r -p "$2" value || no_input
        if [[ $value =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            printf -v "$1" '%s' "$value"
            return 0
        fi
        echo "Invalid email address, please try again." >&2
    done
}

# prompt_app_password VAR: reads a Gmail App Password into VAR without echoing it.
prompt_app_password() {
    local value
    while true; do
        read -r -s -p "Gmail App Password (not your normal Gmail password): " value || no_input
        echo >&2
        value=${value//[[:space:]]/} # Google shows it as four groups of four letters
        if [[ $value =~ ^[A-Za-z0-9]{16}$ ]]; then
            printf -v "$1" '%s' "$value"
            return 0
        fi
        echo "A Gmail App Password is 16 letters long. Please try again." >&2
    done
}

preflight() {
    [[ $EUID -eq 0 ]] || die "Run this script as root: sudo bash $0"
    command -v apt-get >/dev/null || die "apt-get not found. This script supports Raspberry Pi OS, Debian and Ubuntu."
    [[ -d /run/systemd/system ]] || die "systemd is not running. This script needs systemd."
}

# Ask every question up front so the rest of the run needs no attention.
gather_input() {
    if [[ -f $OLD_CLOUDFLARED_UNIT ]] && grep -q 'proxy-dns' "$OLD_CLOUDFLARED_UNIT"; then
        echo "Found the cloudflared DNS proxy set up by the old version of this script."
        echo "Cloudflare has removed that feature, and it holds port $LISTEN_PORT, which dnscrypt-proxy needs."
        if ask_yes_no "Remove it (service, /etc/default/cloudflared, /usr/local/bin/cloudflared, 'cloudflared' user)?" y; then
            REMOVE_CLOUDFLARED=yes
        else
            die "cloudflared would block port $LISTEN_PORT. Re-run and answer yes to remove it."
        fi
    fi

    # auto: point Pi-hole v6 at dnscrypt-proxy; manual: print the steps; none: no Pi-hole.
    if [[ -f $PIHOLE_TOML ]] && command -v pihole-FTL >/dev/null; then
        PIHOLE_MODE=manual
        local current
        current=$(pihole-FTL --config dns.upstreams 2>/dev/null) || current="(unknown)"
        echo "Pi-hole currently forwards queries to: $current"
        if ask_yes_no "Make dnscrypt-proxy (${LISTEN_ADDR}#${LISTEN_PORT}) Pi-hole's only upstream DNS server?" y; then
            PIHOLE_MODE=auto
            PIHOLE_PREVIOUS_UPSTREAMS=$current
        fi
    elif command -v pihole >/dev/null; then
        PIHOLE_MODE=manual
    fi

    if [[ -e $MSMTP_CONF ]] && ! ask_yes_no "$MSMTP_CONF already exists. Replace it?" n; then
        WRITE_MSMTP_CONF=no
    fi
    if [[ $WRITE_MSMTP_CONF == yes ]]; then
        echo "Sending through Gmail needs 2-Step Verification and an App Password:"
        echo "  https://myaccount.google.com/apppasswords"
        prompt_email SOURCE_EMAIL "Gmail address to send from: "
        prompt_app_password SMTP_PASSWORD
    fi
    prompt_email TARGET_EMAIL "Address that should receive email (test email, root and cron mail): "
}

remove_old_cloudflared() {
    info "Removing the old cloudflared DNS proxy"
    systemctl disable --now cloudflared.service || true
    rm -f "$OLD_CLOUDFLARED_UNIT" /etc/default/cloudflared /usr/local/bin/cloudflared
    systemctl daemon-reload
    systemctl reset-failed cloudflared.service 2>/dev/null || true
    if getent passwd cloudflared >/dev/null; then
        userdel cloudflared || warn "Could not remove the 'cloudflared' user."
    fi
}

# The Debian/Ubuntu package starts dnscrypt-proxy through a systemd socket on
# 127.0.2.1:53. Move that socket to 127.0.0.1:5053 *before* installing, so it
# never starts on port 53 next to Pi-hole. Also mask the package's resolvconf
# helper, which would point this machine's own DNS at dnscrypt-proxy and
# bypass Pi-hole.
prepare_dnscrypt_units() {
    info "Preparing dnscrypt-proxy to listen on ${LISTEN_ADDR}:${LISTEN_PORT}"
    mkdir -p "$(dirname "$DNSCRYPT_SOCKET_DROPIN")"
    cat >"$DNSCRYPT_SOCKET_DROPIN" <<EOF
# Written by install_dnscrypt_with_email.sh
[Socket]
ListenStream=
ListenDatagram=
ListenStream=${LISTEN_ADDR}:${LISTEN_PORT}
ListenDatagram=${LISTEN_ADDR}:${LISTEN_PORT}
EOF
    systemctl stop dnscrypt-proxy-resolvconf.service 2>/dev/null || true
    systemctl mask dnscrypt-proxy-resolvconf.service
    systemctl daemon-reload
}

install_packages() {
    local packages=(dnscrypt-proxy msmtp ca-certificates) sendmail_owner=""
    if [[ -e /usr/sbin/sendmail ]]; then
        sendmail_owner=$(dpkg-query -S /usr/sbin/sendmail 2>/dev/null | cut -d: -f1) || sendmail_owner=""
    fi
    if [[ ! -e /usr/sbin/sendmail || $sendmail_owner == msmtp-mta ]]; then
        packages+=(msmtp-mta) # makes msmtp the system's sendmail, so cron mail works
    else
        warn "Keeping the existing mail system (${sendmail_owner:-unknown}); msmtp-mta will not be installed."
    fi
    if ! command -v dig >/dev/null; then
        packages+=(bind9-dnsutils)
    fi

    info "Installing ${packages[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

configure_dnscrypt() {
    info "Configuring dnscrypt-proxy"
    if [[ -f $DNSCRYPT_CONF && ! -f $DNSCRYPT_CONF.bak ]]; then
        cp -p "$DNSCRYPT_CONF" "$DNSCRYPT_CONF.bak"
    fi
    cat >"$DNSCRYPT_CONF" <<'EOF'
# Written by install_dnscrypt_with_email.sh. The file it replaced, if any, is
# saved next to it as dnscrypt-proxy.toml.bak.

# systemd owns the listening socket (127.0.0.1:5053), see
# /etc/systemd/system/dnscrypt-proxy.socket.d/listen.conf
listen_addresses = []

# Only use the two Cloudflare DNS-over-HTTPS servers defined below.
server_names = ['cloudflare-1.1.1.1', 'cloudflare-1.0.0.1']

# Wait for the network by probing Cloudflare instead of the default Quad9.
netprobe_address = '1.1.1.1:53'
netprobe_timeout = 60

# https://cloudflare-dns.com/dns-query, reached directly by IP address so no
# bootstrap DNS lookup is needed. Decode stamps at https://dnscrypt.info/stamps
[static]
  [static.'cloudflare-1.1.1.1']
  stamp = 'sdns://AgcAAAAAAAAABzEuMS4xLjEAEmNsb3VkZmxhcmUtZG5zLmNvbQovZG5zLXF1ZXJ5'

  [static.'cloudflare-1.0.0.1']
  stamp = 'sdns://AgcAAAAAAAAABzEuMC4wLjEAEmNsb3VkZmxhcmUtZG5zLmNvbQovZG5zLXF1ZXJ5'
EOF
    dnscrypt-proxy -config "$DNSCRYPT_CONF" -check

    systemctl daemon-reload
    systemctl enable dnscrypt-proxy.socket dnscrypt-proxy.service
    # The socket can only move to its new address while the service is stopped.
    systemctl stop dnscrypt-proxy.service
    if ! systemctl restart dnscrypt-proxy.socket; then
        ss -lntup "sport = :${LISTEN_PORT}" >&2 || true
        die "Could not listen on ${LISTEN_ADDR}:${LISTEN_PORT}. Is another program using that port (see above)?"
    fi
    systemctl start dnscrypt-proxy.service
}

# wait_for_dns PORT: succeeds once the DNS server on LISTEN_ADDR#PORT resolves a name.
wait_for_dns() {
    local port=$1 answer attempt
    for attempt in {1..15}; do
        answer=$(dig +short +time=3 +tries=1 -p "$port" @"$LISTEN_ADDR" cloudflare.com A 2>/dev/null) || true
        if [[ $answer =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            echo "OK: cloudflare.com resolved to ${answer%%$'\n'*} via ${LISTEN_ADDR}#${port} (attempt $attempt)"
            return 0
        fi
        sleep 2
    done
    return 1
}

verify_dnscrypt() {
    info "Checking that dnscrypt-proxy answers on ${LISTEN_ADDR}#${LISTEN_PORT}"
    if ! wait_for_dns "$LISTEN_PORT"; then
        journalctl -u dnscrypt-proxy.service -n 30 --no-pager >&2 || true
        if [[ $REMOVE_CLOUDFLARED == yes ]]; then
            warn "Pi-hole may still forward to ${LISTEN_ADDR}#${LISTEN_PORT}. Until this is fixed, pick another"
            warn "upstream server in the Pi-hole web interface (Settings > DNS) to keep DNS working."
        fi
        die "dnscrypt-proxy is not answering (log above). Pi-hole and email have not been changed."
    fi
}

pihole_manual_steps() {
    echo "To send Pi-hole's queries through dnscrypt-proxy, open the Pi-hole web interface,"
    echo "go to Settings > DNS, untick every upstream server, add the custom upstream"
    echo "${LISTEN_ADDR}#${LISTEN_PORT} and save."
}

configure_pihole() {
    info "Making dnscrypt-proxy Pi-hole's only upstream DNS server"
    if ! pihole-FTL --config dns.upstreams "[\"${LISTEN_ADDR}#${LISTEN_PORT}\"]"; then
        warn "Could not change Pi-hole's upstream servers; the summary below shows how to do it by hand."
        PIHOLE_MODE=manual
        return 0
    fi
    systemctl restart pihole-FTL.service || warn "Could not restart Pi-hole. Run: sudo systemctl restart pihole-FTL"
    if ! wait_for_dns 53; then
        warn "Pi-hole is not answering on ${LISTEN_ADDR}#53 yet. Check: sudo systemctl status pihole-FTL"
    fi
    echo "Previous upstream servers: $PIHOLE_PREVIOUS_UPSTREAMS"
    echo "To go back, set them in the web interface (Settings > DNS) or with:"
    echo "  sudo pihole-FTL --config dns.upstreams '<previous list>'"
}

configure_msmtp() {
    info "Writing $MSMTP_CONF (readable by root only) and $MSMTP_ALIASES"
    # Create the file with its final permissions before the password goes in.
    install -m 600 -o root -g root /dev/null "$MSMTP_CONF"
    cat >"$MSMTP_CONF" <<EOF
# Written by install_dnscrypt_with_email.sh
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
syslog         LOG_MAIL
# Mail for local users (root, cron jobs, ...) goes to the address in this file.
aliases        $MSMTP_ALIASES

account        gmail
host           smtp.gmail.com
port           587
from           $SOURCE_EMAIL
user           $SOURCE_EMAIL
password       $SMTP_PASSWORD

account default : gmail
EOF
    install -m 644 -o root -g root /dev/null "$MSMTP_ALIASES"
    printf 'default: %s\n' "$TARGET_EMAIL" >"$MSMTP_ALIASES"
}

send_test_email() {
    info "Sending a test email to $TARGET_EMAIL"
    local host
    host=$(hostname)
    if printf 'To: %s\nSubject: Test email from %s\n\nmsmtp on %s can send email.\n' \
        "$TARGET_EMAIL" "$host" "$host" | msmtp -- "$TARGET_EMAIL"; then
        echo "Sent. Check the inbox (and spam folder) of $TARGET_EMAIL."
    else
        warn "The test email could not be sent. Check the App Password, then see: sudo journalctl -t msmtp"
    fi
}

print_summary() {
    info "Done"
    echo "dnscrypt-proxy listens on ${LISTEN_ADDR}#${LISTEN_PORT} and forwards to Cloudflare over HTTPS."
    echo "  Test it:  dig @${LISTEN_ADDR} -p ${LISTEN_PORT} cloudflare.com"
    echo "  Logs:     sudo journalctl -u dnscrypt-proxy"
    case $PIHOLE_MODE in
        auto) echo "Pi-hole uses dnscrypt-proxy as its only upstream DNS server." ;;
        manual) pihole_manual_steps ;;
        none) echo "Pi-hole was not found. Point your DNS server at ${LISTEN_ADDR}#${LISTEN_PORT} once it is installed." ;;
    esac
    echo "Email settings are in $MSMTP_CONF."
    printf '  Send one: %s\n' "printf 'Subject: Hello\n\nIt works.\n' | sudo msmtp you@example.com"
    echo "  Logs:     sudo journalctl -t msmtp"
}

main() {
    preflight
    gather_input
    prepare_dnscrypt_units
    # Install while the old cloudflared still serves DNS: Pi-hole (and so apt)
    # may depend on it. Its removal frees port 5053 just before dnscrypt-proxy
    # binds it, so DNS is only down for a moment.
    install_packages
    if [[ $REMOVE_CLOUDFLARED == yes ]]; then remove_old_cloudflared; fi
    configure_dnscrypt
    verify_dnscrypt
    if [[ $PIHOLE_MODE == auto ]]; then configure_pihole; fi
    if [[ $WRITE_MSMTP_CONF == yes ]]; then configure_msmtp; fi
    send_test_email
    print_summary
}

main "$@"
