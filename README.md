# Pi-hole + dnscrypt-proxy (DNS-over-HTTPS) + email

One script for a Pi-hole box (typically a Raspberry Pi) that:

- installs **dnscrypt-proxy** and has it listen on `127.0.0.1#5053`, sending
  every query to Cloudflare (`1.1.1.1` / `1.0.0.1`) over DNS-over-HTTPS;
- makes it **Pi-hole's only upstream DNS server** (Pi-hole v6, if you agree);
- sets up **msmtp** so the machine can send email through Gmail, routes mail for
  local users (root, cron jobs) to your address, and sends a test email.

```
devices ──DNS──▶ Pi-hole :53 ──▶ dnscrypt-proxy 127.0.0.1:5053 ──HTTPS──▶ Cloudflare
```

## Why not cloudflared any more?

Earlier versions of this repo used `cloudflared proxy-dns`. Cloudflare
[removed that command](https://developers.cloudflare.com/changelog/2025-11-11-cloudflared-proxy-dns/)
from cloudflared starting with release 2026.2.0, so a fresh install no longer
works. dnscrypt-proxy does the same job, is packaged by Debian, Ubuntu and
Raspberry Pi OS, and gets updates through `apt`.

## Requirements

- Raspberry Pi OS, Debian or Ubuntu, with systemd
- Pi-hole installed directly on the machine (not in Docker). The script can
  switch Pi-hole v6 over for you; for v5 it prints the manual steps.
- A Gmail account with
  [2-Step Verification](https://myaccount.google.com/signinoptions/twosv) turned
  on and an [App Password](https://myaccount.google.com/apppasswords) for it

## Install

Download the script, read it, then run it as root:

```bash
curl -fsSLO https://raw.githubusercontent.com/Paradox7307/PiHole-Cloudflared_with_email/main/install_dnscrypt_with_email.sh
less install_dnscrypt_with_email.sh
sudo bash install_dnscrypt_with_email.sh
```

All questions come first. After that the script runs on its own:

1. If the old cloudflared DNS proxy from this repo is installed: remove it?
   (Needed, because it holds port 5053.)
2. If Pi-hole v6 is installed: make dnscrypt-proxy its only upstream? The
   current upstreams are shown so you can switch back later.
3. If `/etc/msmtprc` already exists: replace it?
4. Gmail address and App Password (typed without echo; spaces are ignored).
5. The address that should receive the test email and all mail for local users.

The script checks that dnscrypt-proxy answers before it touches Pi-hole, and
checks that Pi-hole still answers afterwards. It is safe to run again.

## What it changes

| Path | Purpose |
| --- | --- |
| `/etc/dnscrypt-proxy/dnscrypt-proxy.toml` | Cloudflare DoH servers. The file it replaced is saved as `dnscrypt-proxy.toml.bak`. |
| `/etc/systemd/system/dnscrypt-proxy.socket.d/listen.conf` | Moves the package's socket from `127.0.2.1:53` to `127.0.0.1:5053` |
| `dnscrypt-proxy-resolvconf.service` (masked) | Stops the package from pointing this machine's own `/etc/resolv.conf` past Pi-hole |
| Pi-hole `dns.upstreams` | Set to `["127.0.0.1#5053"]` (only if you said yes) |
| `/etc/msmtprc` (mode 600, root) | Gmail SMTP settings, including the App Password |
| `/etc/msmtp-aliases` | Sends mail for local users (root, cron, …) to your address |

Packages: `dnscrypt-proxy`, `msmtp`, `ca-certificates`, `msmtp-mta` (skipped if
another mail system such as Postfix provides `sendmail`), and `bind9-dnsutils`
if `dig` is missing.

## Check that it works

```bash
dig @127.0.0.1 -p 5053 cloudflare.com   # dnscrypt-proxy directly
dig @127.0.0.1 cloudflare.com           # through Pi-hole
systemctl status dnscrypt-proxy.socket dnscrypt-proxy.service
sudo journalctl -u dnscrypt-proxy
```

`https://1.1.1.1/help` in a browser on your network should show
"Using DNS over HTTPS (DoH): Yes".

## Sending email

The password file is readable by root only, so send as root:

```bash
printf 'Subject: Hello\n\nIt works.\n' | sudo msmtp you@example.com
```

With `msmtp-mta` installed, msmtp is also the system's `sendmail`. Cron output
and anything else addressed to a local user (for example `root`) goes to the
address you entered. Delivery logs: `sudo journalctl -t msmtp`.

## Upgrading from the cloudflared version

Run the new script. It finds the `cloudflared proxy-dns` service that the old
script created and, if you agree, removes the service, `/etc/default/cloudflared`,
`/usr/local/bin/cloudflared` and the `cloudflared` user. Only a unit that runs
`proxy-dns` is touched, so a Cloudflare Tunnel setup is left alone.
cloudflared keeps serving DNS while packages install and is removed just
before dnscrypt-proxy takes over port 5053, so DNS is only down for a moment.

The old script wrote `/home/pihole/.msmtprc` and `/var/log/msmtp.log`. The new
setup uses `/etc/msmtprc` and the system journal instead. Delete the old files
once the test email arrives.

## Pi-hole v5 or manual setup

In the Pi-hole web interface, go to **Settings → DNS**, untick every upstream
server, add `127.0.0.1#5053` as a custom upstream and save.

## Using a different DNS-over-HTTPS provider

Edit the `[static]` section of `/etc/dnscrypt-proxy/dnscrypt-proxy.toml` (and
`server_names` to match). You can build a stamp for any DoH server at
<https://dnscrypt.info/stamps>. Then run `sudo systemctl restart dnscrypt-proxy`.

When `apt` upgrades dnscrypt-proxy, it may ask about this changed config file.
Keep your current version.

## Uninstall

Point Pi-hole at another upstream server first, or DNS stops working. Then:

```bash
sudo systemctl disable --now dnscrypt-proxy.service dnscrypt-proxy.socket
sudo apt-get purge dnscrypt-proxy msmtp msmtp-mta
sudo rm -r /etc/systemd/system/dnscrypt-proxy.socket.d
sudo systemctl unmask dnscrypt-proxy-resolvconf.service
sudo rm -f /etc/msmtprc /etc/msmtp-aliases
sudo systemctl daemon-reload
```

## Troubleshooting

- **The test email fails with "Username and Password not accepted".** Use an
  App Password, not your Gmail password. 2-Step Verification must be on.
- **dnscrypt-proxy doesn't answer.** Check `sudo journalctl -u dnscrypt-proxy -n 50`.
  If port 5053 is taken, `sudo ss -lntup 'sport = :5053'` shows which program
  has it.
- **Pi-hole stopped resolving after the switch.** Put the previous upstreams
  back in **Settings → DNS**. The script printed them.
