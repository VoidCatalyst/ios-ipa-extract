# ios-ipa-extract

A CLI tool to pull an installed app off a **jailbroken iOS device** over SSH
and package it as a `.ipa`. The transfer is split across parallel SSH
connections and verified with an MD5 checksum, so it stays fast and reliable
even for large apps and flaky links.

> **Note on the output:** the `.ipa` produced is a **raw copy of the app's
> container** — the binary inside is still App Store–encrypted (FairPlay) and
> signed for the original device. It is meant for **archiving and static
> analysis**, not installation — it will *not* sideload and run on a
> different iPhone as-is. To get an installable/decrypted build you need a
> runtime dumper such as [`frida-ios-dump`](https://github.com/AloneMonkey/frida-ios-dump)
> or TrollDecrypt, plus your own signing (AltStore/TrollStore/Xcode).

---

## How it works

1. Connects to the device over SSH (one shared "master" connection for
   control commands, separate connections per download worker).
2. Streams every installed app's `Info.plist` back and parses it locally
   with `python3` to build a searchable app list (name, bundle ID, version).
3. `tar`s the matched app's `.app` bundle on the device into `/tmp`.
4. Downloads that tar either as a **single resumable stream** (`-j 1`) or
   split into **N parallel byte-range chunks** pulled over N simultaneous
   SSH connections (`-j N`, default 4) — this lets the device's CPU
   encrypt multiple streams at once instead of being limited to one core.
5. Verifies the download against an MD5 checksum taken on the device.
6. Repackages the extracted bundle into the standard IPA layout
   (`Payload/App.app/...`) and zips it.

---

## Requirements

### On the computer you run it from (Kali, Linux, macOS, WSL)

| Tool | Needed for | Install |
|---|---|---|
| `bash` | the script itself | preinstalled |
| `ssh` | connecting to the device | `sudo apt install openssh-client` (Kali/Debian — usually preinstalled) |
| `zip` | packaging the final `.ipa` | `sudo apt install zip` |
| `python3` | parsing binary `Info.plist` files | `sudo apt install python3` (preinstalled on Kali) |
| `sshpass` | **only if** you authenticate with a password (`-p`) | `sudo apt install sshpass` |

Standard POSIX utilities (`tar`, `dd`, `awk`, `grep`, `mktemp`, `stat`,
`md5sum`, `truncate`, `wc`) are assumed to already be present — they ship
with every mainstream Linux distro and macOS.

Windows is not supported natively — use **WSL** (Windows Subsystem for Linux).

### On the iOS device

- A **jailbreak** (the device's filesystem must be writable and able to run
  OpenSSH — this tool does **not** work on a stock, non-jailbroken iPhone).
- **OpenSSH** installed and running on the device (port 22 reachable).
- Know the SSH credentials — jailbreak tools default to user `mobile`
  (or `root`), password `alpine`.

---

## Setup walkthrough (from a fresh jailbroken device)

This is the full path from "just jailbroken" to a working extraction,
matching a typical Kali Linux workflow:

### 1. Install OpenSSH on the device

From your jailbreak's package manager (Cydia, Sileo, Zebra, or Sileo-based
stores depending on your jailbreak — unc0ver, checkra1n, Dopamine, etc.),
install the **OpenSSH** package. This starts an SSH server on the device.

> ⚠️ Change the default `alpine` password immediately after your first login
> (`passwd` on-device, or `passwd root`) — a jailbroken device with SSH and a
> default password is a known, actively-exploited weakness on networks you
> don't fully trust.

### 2. Connect the device to Kali

Two options:

- **Wi-Fi** — put the iPhone and Kali machine on the same network (the
  phone's IP is under *Settings → Wi-Fi → (i) next to your network*).
- **USB (recommended — faster & doesn't depend on Wi-Fi)** — connect the
  iPhone to Kali with a USB cable, then tunnel SSH over the USB link with
  `usbmuxd` + `iproxy`:
  ```bash
  sudo apt install usbmuxd libimobiledevice-utils
  iproxy 2222 22        # forwards localhost:2222 -> device:22 over USB
  # then use -H 127.0.0.1 and let SSH connect through port 2222
  ```

### 3. Verify SSH connectivity

```bash
ssh mobile@<device-ip>
# or, over the USB tunnel:
ssh -p 2222 mobile@127.0.0.1
```

Accept the host key prompt and confirm you land on a device shell
(`iPhone:~ mobile$`). This is the connection the script will reuse.

### 4. Give the script execute permission

```bash
chmod +x extract-ipa.sh
```

### 5. Configure your device details (once)

```bash
cp extract-ipa.conf.example extract-ipa.conf
# edit HOST / SSH_USER / PASS / JOBS for your device
```

(Alternatively, put it at `~/.config/extract-ipa.conf`.)

**Recommended:** use an SSH key instead of a password so nothing is stored
in plain text and you get zero prompts:

```bash
ssh-copy-id mobile@<device-ip>     # then leave PASS empty in the config
```

### 6. Run it

```bash
./extract-ipa.sh -l                 # list every installed app
./extract-ipa.sh "App Name"         # extract by display name or bundle id
```

---

## Usage

```bash
./extract-ipa.sh -l                            # list every installed app
./extract-ipa.sh "Target App"                  # find + extract by name
./extract-ipa.sh -o ~/ipas "com.example.app"   # extract by bundle id, custom output dir
./extract-ipa.sh -j 8 "Target App"             # 8 parallel streams (faster on Wi-Fi)
IPA_SSH_PASS=alpine ./extract-ipa.sh -l        # password via env var instead of config
```

| Flag | Meaning | Default |
|---|---|---|
| `-H` | device IP / hostname | from config, or `$IPA_SSH_HOST` |
| `-u` | SSH user | `mobile` |
| `-p` | SSH password | from config / key auth, or `$IPA_SSH_PASS` |
| `-o` | output directory | current directory |
| `-j` | parallel download streams | `4` (`1` = single resumable stream) |
| `-l` | list installed apps and exit | – |
| `-h` | show help | – |

**Precedence:** built-in defaults → `extract-ipa.conf` → environment
variables (`IPA_SSH_HOST`, `IPA_SSH_USER`, `IPA_SSH_PASS`) → command-line
flags.

---

## Limitations

- **Jailbreak + SSH only.** There is no non-jailbreak path — iOS does not
  expose app containers over USB/AFC the way this tool needs without one.
- **Output is encrypted, not a sideloadable build.** The `.ipa` is a raw
  container copy (still FairPlay-encrypted, signed for the source device).
  Use a runtime dumper (`frida-ios-dump`, TrollDecrypt) if you need a
  decrypted, re-signable IPA.
- **One app per run.** No bulk/batch export of every installed app at once.
- **Host key checking is disabled** (`StrictHostKeyChecking=no`) by design,
  since the "server" is a single physical device you hold and pair
  yourself — not a fit for untrusted/shared networks without the USB tunnel.
- **No native Windows support** — use WSL.
- Relies on `/var/containers/Bundle/Application/` as the app root; this is
  standard on current jailbreaks but could shift on major iOS/jailbreak
  changes.
- Parallel mode (`-j > 1`) needs either an SSH key or a password (`-p` /
  `$IPA_SSH_PASS`) — without one, each extra connection will prompt
  interactively and the parallelism breaks.

---

## Tips & troubleshooting

- **Speed:** more streams help when the device's SSH encryption is the
  bottleneck. Try `-j 6`/`-j 8` on Wi-Fi; use `-j 1` for a single resumable
  stream on a flaky link. If it's still slow, the limit is Wi-Fi bandwidth —
  connect by USB and tunnel with `iproxy` instead.
- **`-j > 1` prompts for a password repeatedly:** you didn't provide `-p`
  / a config password and have no SSH key. Add a key (`ssh-copy-id`) or set
  `PASS`.
- **App not found:** run `-l` to see exact names, then match on a unique
  word or the bundle ID.
- **Checksum mismatch / stalled transfer:** just re-run — the single-stream
  download resumes from where it left off.
- **`error: cannot SSH to ...`:** confirm OpenSSH is actually running on the
  device (respring or reboot after installing it), and that the IP/port are
  reachable (`ping`, or `nc -zv <host> 22`).

---

## Legal & ethical use

Only extract apps you own, developed yourself, or have explicit written
authorization to analyze (e.g. as part of an engagement, bug bounty scope,
or your own app's QA). Extracting and redistributing third-party App
Store binaries you don't have rights to may violate the app's terms of
service, copyright law, and/or the Apple Developer Program License
Agreement. This tool is provided for legitimate security research,
mobile app pentesting, and personal backup/analysis of apps you are
authorized to test.

---

## License

MIT — see [LICENSE](LICENSE).
