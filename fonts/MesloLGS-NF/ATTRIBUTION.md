# MesloLGS NF (vendored)

These four TTFs are the Nerd Font that this repo's prompt + terminal config
depend on:

- `.p10k.zsh` runs `POWERLEVEL9K_MODE=nerdfont-v3` (prompt glyphs).
- `.config/alacritty/alacritty.toml` pins `[font].family = "MesloLGS NF"`.

A fresh Ubuntu does **not** ship this font, and there is no apt/brew package for
it on Linux/arm64 — so rather than fetching it over the network at provision time
(unauthenticated, and broken offline), the bytes are **vendored here** and copied
into place by `install.sh` (→ `~/.local/share/fonts`) and
`provision/steps/36-alacritty.sh` (→ `/usr/local/share/fonts`, system-wide).

## Origin & license

`MesloLGS NF` is a patched build of **Meslo LG** (by André Berg) with Nerd Font
glyphs added, distributed for use with Powerlevel10k:

- Upstream font files: https://github.com/romkatv/powerlevel10k-media
- Powerlevel10k font docs: https://github.com/romkatv/powerlevel10k#fonts
- Meslo LG source: https://github.com/andreberg/Meslo-Font

Meslo LG is licensed under the **Apache License 2.0**, so redistribution is
permitted with attribution. **TODO before making this repo public:** drop the
upstream `LICENSE` (Apache-2.0 text) next to these files for full compliance.

## Provenance (sha256)

```
d97946186e97f8d7c0139e8983abf40a1d2d086924f2c5dbf1c29bd8f2c6e57d  MesloLGS NF Regular.ttf
b6c0199cf7c7483c8343ea020658925e6de0aeb318b89908152fcb4d19226003  MesloLGS NF Bold.ttf
6f357bcbe2597704e157a915625928bca38364a89c22a4ac36e7a116dcd392ef  MesloLGS NF Italic.ttf
56b4131adecec052c4b324efb818dd326d586dbc316fc68f98f1cae2eb8d1220  MesloLGS NF Bold Italic.ttf
```
