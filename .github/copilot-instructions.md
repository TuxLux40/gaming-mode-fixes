# Copilot Instructions

## Commands

This repository does not define a build, test, or lint toolchain. The main executable workflows are the maintenance scripts:

```bash
sudo bash apply-fixes.sh
sudo bash revert-fixes.sh
bash fix-gamethememusic-settings.sh
```

For a quick per-file syntax check while editing shell scripts, run:

```bash
bash -n apply-fixes.sh
bash -n revert-fixes.sh
bash -n fix-gamethememusic-settings.sh
```

There is no single-test runner; validation is script-by-script.

## High-level architecture

This is an operations repository for patching files in an already-installed Decky Loader environment on the host system. It is not the source code for Decky Loader, Sunshine, or the affected plugins.

- `patches/decky-sunshine-native-service.patch` is the source of truth for the Decky Sunshine fix. It modifies the installed `sunshine.py` in the `decky-sunshine` plugin so the plugin:
  - treats a native `systemctl --user` Sunshine service as "running", not just the Flatpak app
  - falls back to `/sys/class/drm/*/status` when `drm_info` is unavailable
- `apply-fixes.sh` is the wrapper that applies that patch to the installed plugin tree, creates `sunshine.py.bak` once, and restarts `plugin_loader.service`
- `revert-fixes.sh` restores the installed `sunshine.py` from the `.bak` created by `apply-fixes.sh`, then restarts `plugin_loader.service`
- `fix-gamethememusic-settings.sh` is a separate one-off repair for `SDH-GameThemeMusic` settings. It rewrites `config.json` only when the file is in the broken nested `{"settings": {...}}` shape

## Key conventions

- Treat the patch file as the canonical implementation of the Decky Sunshine fix. If behavior changes, update `patches/decky-sunshine-native-service.patch` and the wrapper scripts/docs that describe how it is applied.
- Keep the two fixes separate. `apply-fixes.sh` and `revert-fixes.sh` are only for `decky-sunshine`; Game Theme Music repair stays isolated in `fix-gamethememusic-settings.sh`.
- The absolute paths in the scripts are intentional and currently tailored to this machine layout under `/home/oliver/homebrew/...`. If you generalize them, update all affected scripts and the README together.
- Preserve the safety rails in the apply/revert flow: root checks for plugin patching, explicit target existence checks, a dry-run before applying the patch, `.bak` backup handling, and service restart after patch/revert.
- README.md contains important operational context, including the current root causes, the expected post-patch behavior in gaming mode, and the note that the Game Theme Music config fix has already been applied on this machine.
