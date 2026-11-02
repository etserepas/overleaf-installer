# Overleaf self-hosted installer

Install **Overleaf Community Edition** on your own server with **one command**. The result is ready
for real documents: full TeX Live, XeLaTeX/LuaLaTeX with Greek and other non-Latin scripts,
Microsoft core fonts, and an nginx reverse proxy.

```bash
curl -fsSL https://raw.githubusercontent.com/etserepas/overleaf-installer/main/install.sh | sudo bash
```

## What it does

| Step | Details |
|---|---|
| Preflight checks | Ubuntu/Debian, x86_64, RAM, free disk space, the machine's IP address |
| Dependencies | Docker, Docker Compose v2 and git, from the distribution's packages |
| Overleaf | The official [overleaf/toolkit](https://github.com/overleaf/toolkit), which runs Overleaf, MongoDB and Redis in Docker |
| MongoDB on new kernels | MongoDB 8 refuses to start on Linux kernel ≥ 6.19 ([SERVER-121912](https://jira.mongodb.org/browse/SERVER-121912)). On those kernels the script adds the `GLIBC_TUNABLES=glibc.pthread.rseq=1` workaround |
| Full TeX Live | Installs `scheme-full` (~8 GB), rebuilds the formats, and registers TeX Live's fonts so XeLaTeX/LuaLaTeX can find them |
| Microsoft core fonts | Times New Roman, Arial, Courier New, etc. These are optional and installed only after you accept their EULA |
| Persistent image | Saves the result as `sharelatex/sharelatex:<version>-with-texlive-full`, so a restart keeps it |
| nginx | Reuses an existing nginx, including custom builds without `sites-enabled`/`conf.d`, or installs the distribution's nginx. Overleaf can use port 80 or a port of its own, with redirects such as `/latex` from the existing site. It validates the new config and rolls back if nginx rejects it |
| Self-test | Compiles a test document with XeLaTeX, Greek, `mathspec`, `fncychap`, `biblatex` and `multirow` |

The script is **idempotent**. When you re-run it, it detects what is already in place and skips those steps.

## Requirements

- Ubuntu 22.04+ or Debian 12+, on **x86_64**. Overleaf publishes no official images for ARM or Raspberry Pi
- At least 4 GB RAM, with 8 GB or more recommended
- About 25 GB of free disk space with full TeX Live
- `sudo` access and an internet connection

## Installation

```bash
git clone https://github.com/etserepas/overleaf-installer.git
cd overleaf-installer
sudo ./install.sh
```

or directly:

```bash
curl -fsSL https://raw.githubusercontent.com/etserepas/overleaf-installer/main/install.sh | sudo bash
```

Installing TeX Live usually takes 30–60 minutes. Over SSH, run the script inside `tmux` or `screen`
so a dropped connection doesn't interrupt it.

When the script finishes:

1. Open `http://<server-ip>/launchpad` and create the first admin account.
2. Add other users under **Admin → Manage Users** (`/admin/register`). There is no public sign-up:
   only the admin can create accounts.
3. In each project, pick the compiler under **Menu → Settings → Compiler**. For example, choose
   XeLaTeX for `fontspec`, `mathspec` or system fonts.

## Options

| Option | Description |
|---|---|
| `--site-url URL` | Public URL of the site (default: `http://<this machine's IP>`) |
| `--app-name NAME` | Name shown in the Overleaf UI (default: `LaTeX Editor`) |
| `--admin-email EMAIL` | Contact email shown on the register page |
| `--dir PATH` | Where the Overleaf toolkit is installed (default: `/opt/overleaf-toolkit`) |
| `--listen-port PORT` | Public port of Overleaf (default: `80`, or the port in `--site-url`). Use another port, e.g. `8081`, to keep an existing site on port 80 |
| `--redirect-paths LIST` | Comma-separated paths of the existing port-80 site that redirect to Overleaf, e.g. `/latex,/overleaf`. Needs a `--listen-port` other than 80 |
| `--port PORT` | Internal port Overleaf listens on behind nginx (default: `8080`) |
| `--no-nginx` | Don't use nginx; Overleaf listens directly on the public port |
| `--no-texlive-full` | Keep the image's minimal TeX Live |
| `--accept-mscorefonts-eula` | Install the Microsoft core fonts without asking. This accepts their [EULA](https://corefonts.sourceforge.net/eula.htm) |
| `--no-mscorefonts` | Don't install the Microsoft core fonts |
| `-y`, `--yes` | Don't ask for confirmation |

Fully unattended example:

```bash
sudo ./install.sh --yes --accept-mscorefonts-eula --site-url http://192.168.1.50 --app-name "LaTeX Editor"
```

With `curl | sudo bash`, pass the options after `-s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/etserepas/overleaf-installer/main/install.sh | sudo bash -s -- --yes --accept-mscorefonts-eula
```

## nginx

| Situation | What the script does |
|---|---|
| No nginx installed | Installs the distribution's `nginx` package and adds a site for Overleaf |
| nginx with `sites-enabled/` (Debian/Ubuntu layout) | Writes `sites-available/overleaf` and enables it |
| nginx that includes `conf.d/*.conf` | Writes `conf.d/overleaf.conf` |
| Custom nginx build (e.g. `/usr/local/nginx`) | Writes `overleaf.conf` next to `nginx.conf`, adds an `include` inside the `http {}` block and keeps a backup of `nginx.conf` |
| A proxy to Overleaf's port that you set up by hand | Leaves it untouched |
| `--no-nginx` | Skips nginx; Overleaf listens directly on the public port |

Each change is checked with `nginx -t` before nginx reloads. If the check fails, the script restores
the previous files and stops. Files it edits are copied to `overleaf-backups/` next to `nginx.conf`
first. The generated site proxies WebSockets, which the real-time editor needs, and allows uploads
up to 50 MB. Existing sites stay as they are: the Overleaf site answers only for the host name in
`--site-url`. When you re-run the script, it rewrites its own files, e.g. to move Overleaf to a new
port.

### Keeping an existing site on port 80

Overleaf can't run under a path such as `http://10.10.20.70/latex`: its pages use absolute paths
(`/login`, `/project`, `/socket.io`, ...), so it needs the root of a host and port. To keep the site
that already answers on port 80, give Overleaf a port of its own, and optionally make paths of the
existing site redirect to it:

```bash
sudo ./install.sh --listen-port 8081 --redirect-paths /latex,/overleaf
```

| URL | Result |
|---|---|
| `http://10.10.20.70/` | Your existing site, unchanged |
| `http://10.10.20.70:8081/` | Overleaf |
| `http://10.10.20.70/latex`, `http://10.10.20.70/overleaf` | Redirect to `http://10.10.20.70:8081/` |

The redirects live in `overleaf-redirects.conf` next to `nginx.conf`. The script includes that file
in the server that answers on port 80, preferring the `default_server`. Re-running the script with
other paths replaces them. With a domain or local DNS, a subdomain such as `latex.example.com`, set
with `--site-url`, avoids the port in the address.

## Managing the installation

```bash
cd /opt/overleaf-toolkit
bin/up -d      # start
bin/stop       # stop
bin/logs       # logs
bin/doctor     # diagnostics
```

Projects and users are stored in `/opt/overleaf-toolkit/data`. **Back up this directory.**

### Upgrading Overleaf

A new Overleaf release comes with the minimal TeX Live again. To upgrade:

```bash
cd /opt/overleaf-toolkit
bin/upgrade                        # official upgrade: new toolkit and Overleaf version
cd - && sudo ./install.sh --yes    # reinstalls TeX Live and fonts on the new version
```

Read the [toolkit CHANGELOG](https://github.com/overleaf/toolkit/blob/master/CHANGELOG.md) first:
some upgrades also require a newer MongoDB.

### HTTPS

To expose the site to the internet, put it behind HTTPS, for example with Let's Encrypt
(`certbot --nginx`) or Cloudflare. Then re-run the script with `--site-url https://...`. With an
`https://` URL the script turns secure cookies on. With `http://` it keeps them off; otherwise the
browser would drop the session cookie and show "Session error".

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Session error. Please check you have cookies enabled` | `OVERLEAF_SECURE_COOKIE` is set on an `http://` site. Overleaf enables secure cookies whenever the variable exists, whatever its value. The script removes it for `http://` URLs. |
| The `mongo` container keeps restarting | The kernel is 6.19 or newer: `docker logs mongo` says "Linux kernel versions 6.19 and newer". The script adds the workaround in `config/docker-compose.override.yml`. |
| `File 'xxx.sty' not found` | Full TeX Live is missing. Re-run the script without `--no-texlive-full`. |
| `The font "Times New Roman" cannot be found` | Re-run the script with `--accept-mscorefonts-eula`. |
| Files of an uploaded zip project can't be found | When the zip has a single top-level folder, Overleaf drops it on upload. Fix the paths in the source, e.g. `Thesis template/figures/` → `figures/`. |
| The site can't be reached from other machines | If `ufw` is active, allow the port, e.g. `sudo ufw allow 80/tcp` (or `8081/tcp` with `--listen-port 8081`). |
| `/latex` opens the existing site, not Overleaf | The redirects need `--listen-port` other than 80. Check that `overleaf-redirects.conf` is included in the server on port 80: `sudo nginx -T \| grep overleaf-redirects`. |

## Licenses

- This installer is released under the [MIT License](LICENSE).
- [Overleaf](https://github.com/overleaf/overleaf) is licensed under AGPL-3.0, and "Overleaf" is a
  trademark of Overleaf. This repository contains no Overleaf code: the script downloads the official
  images and toolkit.
- The Microsoft core fonts are not included here. The `ttf-mscorefonts-installer` package downloads
  them only after you accept their [EULA](https://corefonts.sourceforge.net/eula.htm).
