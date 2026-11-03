# lightdrop

[![CI](https://github.com/yakubmurcek/lightdrop/actions/workflows/ci.yml/badge.svg)](https://github.com/yakubmurcek/lightdrop/actions/workflows/ci.yml)

AirDrop in the terminal, between your computers and your friends' computers, over Tailscale.
Files go straight from one computer to the other and land in Downloads. Mac, Linux and Windows.

## Use it

1. **Install Tailscale** and join the network (the invite link you got).
2. **Install lightdrop**: paste one line into a terminal (Mac: Terminal app; Windows: PowerShell).
   - Mac / Linux: `curl -fsSL https://github.com/yakubmurcek/lightdrop/releases/latest/download/install.sh | sh`
   - Windows: `irm https://github.com/yakubmurcek/lightdrop/releases/latest/download/install.ps1 | iex`

   From now on your computer receives files in the background, also after a restart.
3. **Send**:
   - **Mac:** drag a file or folder up to the notch and drop it there. It goes to the other
     person (with several of their computers online, drop it on the one you want).
   - **Anywhere:** open a **new** terminal, type `lightdrop `, drag a file or folder in, press
     Enter, pick the computer by its number.

```
lightdrop report.pdf              # pick an online computer, it lands in their Downloads
lightdrop -t macbook photos/      # -t names the computer and skips the picker
lightdrop uninstall               # stop receiving
```

Update: run the install line again. Phones are not supported.

## The Mac app (LightDrop)

`mac/` is a SwiftUI menu-bar app with no Dock icon. While a file is dragged near the notch,
a black island grows out of it (on a Mac without a notch, out of the top centre); dropping
there sends through the `lightdrop` command (`-t <ip> --json`), so transfer and discovery
stay in one place. "The other person" = online computers that are receiving and belong to
another tailnet user (`lightdrop peers`); one → the island is the target, several → one
pill each. It starts at login (Login Items) and quits from its menu-bar icon.

Receiving shows there too, without getting in the way: while a file comes in, the sender's
photo sits left of the notch and a progress ring right of it, inside the menu bar (nothing
to click, no sound). When it's in, a small card shows the file and who sent it for a few
seconds, then folds away; a whole send of several files gets one card. The menu-bar icon
lists the last files received (click one to show it in Finder). While the app runs, the
receiver skips its desktop notification, so a file never alerts twice.

Testing alone: `defaults write com.lightdrop.notch includeOwnDevices -bool YES` counts your
own computers as targets.

## How it works

- Every machine runs a receiver on its **Tailscale IP only**, port 8765. It accepts
  uploads and nothing else: no listing, no downloads, so nobody can read or guess
  what is in your Downloads. Only `GET /ping` answers (so senders can find receivers).
- What is arriving (name, sender, bytes so far) goes to a Unix socket only you can open
  (`~/Library/Caches/lightdrop-receiver.sock`, Linux `~/.cache/…`), never over Tailscale.
  `lightdrop events` prints it live; the Mac app reads it with `--json`.
- Files go straight into `~/Downloads`. A taken name becomes `name 2.ext`, `name 3.ext`…,
  decided by the receiver: nothing is ever overwritten, and the sender learns nothing
  about what exists there.
- A folder travels as one tar stream; the receiver keeps regular files and folders only
  and refuses any path that would leave the target folder.
- Transfers are direct device to device (inside one house, over the LAN), encrypted by
  WireGuard. Nothing is stored anywhere in between.
- Who may send is your tailnet policy's call: for example, let invited guests reach your
  devices on TCP port 8765 only.
- Taildrop can't do this: it only sends between one user's own devices.

Receivers: macOS LaunchAgent `com.lightdrop.receiver` (log `~/Library/Logs/lightdrop.log`),
Linux `systemctl --user` unit `lightdrop.service`, Windows scheduled task `lightdrop receiver`
(starts at boot, hidden) plus firewall rule `lightdrop` (TCP 8765, 100.64.0.0/10 only).
On macOS the receiver finds its Tailscale address from the network interfaces, because
the Tailscale app's CLI doesn't answer outside a terminal.

Install puts the binary in `~/.local/bin` (Windows: `%LOCALAPPDATA%\lightdrop`) and adds that
folder to the PATH (the login shell's startup file; Windows: the user PATH).

## Build, test and publish

```
bash build.sh                        # needs Go: vet, test, binaries for every platform into dist/
bash build-app.sh                    # Mac with Xcode: dist/LightDrop-app.zip
swift test --package-path mac        # the Mac app's tests
bash publish.sh                      # release from main, built on GitHub (needs gh)
```

CI (`.github/workflows/ci.yml`) runs on every PR and push to main: the Go tests on macOS,
Linux and Windows, gofmt, staticcheck, shellcheck, cross-builds, and the Mac app's tests
and universal build. `publish.sh` starts the Release workflow, which runs CI, builds
everything on a GitHub Mac and makes a release under a date tag (`v2026.11.03`, then
`v2026.11.03.2`…). The install lines download from the latest release.

The first install lines pointed at a gist; its `install.sh` and `install.ps1` now just run the
ones from the latest release, so those lines keep working. In a fork, change `REPO` in
`publish.sh` and the URLs in `install.sh`, `install.ps1` and this README.
