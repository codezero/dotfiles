# CLAUDE.md — dotfiles + provisioning

Personal dotfiles backup + full-machine provisioning for **Ubuntu 26.04 ("resolute", arm64)**.

## Layout
- `.zshrc`, `.p10k.zsh`, `.gitconfig` — the dotfiles (symlinked into `$HOME`).
- `install.sh` — lightweight bootstrap: **shell + dotfiles only**.
- `provision/` — **canonical** full-machine replication. `provision.sh` is the entrypoint;
  step scripts in `provision/steps/`, package lists in `provision/packages/`, shared
  helpers in `provision/lib.sh`. Details in `provision/README.md`.

## Conventions / gotchas
- Scripts are **not** marked executable — run them with `bash <script>`
  (`bash install.sh`, `sudo bash provision.sh`, `bash provision.sh --dry-run`).
- `provision.sh` is cloud-init-ready: runs as root, idempotent, failure-tolerant;
  per-user steps (brew, oh-my-zsh, dotfiles) drop to `$PROVISION_USER`.
  `--dry-run` previews with no changes and no sudo. `INSTALL_DESKTOP=1` adds the desktop set.
- All apt goes through `apt_get`/`apt_install` in `lib.sh` (noninteractive, needrestart,
  `DPkg::Lock::Timeout`). Step 10 filters boot/kernel/third-party/desktop out of `apt.list`;
  step 20 owns Docker/VSCodium/Bruno/Cursor (key → repo → install order).
- `bat` must come from **brew** (binary `bat`); apt's is `batcat` and breaks the alias.
- **Casks are kept** in the Brewfile — the `codex` cask supports Linux arm64.
- `.deb` downloads (Cursor/Bruno) use `mktemp`, not predictable `/tmp` paths.

## Open TODOs
- [ ] Remove superseded scripts: `setup-docker.sh`, `setup-vscodium.sh` (folded into `provision/steps/20-apt-third-party.sh`).
- [ ] `git init` + first commit (repo is not initialized yet).
- [ ] Smoke-test Cursor + Bruno install on a real arm64 box (URL parsing was hardened but not run live).
