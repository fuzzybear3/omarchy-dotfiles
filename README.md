# omarchy-dotfiles

Declarative config and package management for my Omarchy machine.
Everything managed lives in [`manifest.toml`](manifest.toml) — if it isn't
declared there, it isn't managed. No config state lives outside this repo.

## Layout

```
manifest.toml        source of truth: managed files, notes, package rules
bootstrap.py         the tool — one command, no arguments
packages.txt         GENERATED — packages I installed on top of Omarchy
home/                stow package; real files live here,
                     ~/.config/... are symlinks into it
```

## Usage

```sh
./bootstrap.py
```

That is the whole interface — fresh machine or daily use, same command,
safe to run at any time. Each run converges the machine to the repo:

1. **ssh** — generate the declared key if missing
2. **packages** — install anything in `packages.txt` that is missing (plus
   stow, which linking needs), then regenerate the file from what is
   actually installed, so hand-installed extras get recorded
3. **system** — add the user to the declared groups (`usermod -aG`;
   activates at next login) and enable the declared services
   (`systemctl enable --now`)
4. **config** — adopt any declared path that is still a real file in
   `$HOME` (local edits win and show up as a git diff), then link
   everything via `stow --no-folding -t ~ home`
5. **reload** — hyprland, only if something changed

Because live configs are symlinks into the repo, editing a config **is**
editing the repo — `git -C ~/lab/omarchy-dotfiles diff` shows uncommitted
tweaks, and Omarchy migrations that rewrite a config show up the same way
(they write through the symlink).

- To manage a new file: add a `[[config]]` entry to `manifest.toml`, run
  `./bootstrap.py`.
- To stop managing a file: delete its entry, `git rm` it from `home/`, and
  replace the `$HOME` symlink with a real copy.
- To drop a package: uninstall it **and** delete its `packages.txt` line —
  otherwise the next run reinstalls it.

## Notes

- Symlinks are made and removed by GNU Stow (`--no-folding`, so links are
  per-file and Omarchy updates can still drop new files into `~/.config`).
  `home/.stow-local-ignore` replaces stow's default ignore list, which
  would silently skip tracked files like `.gitignore`. Because stow links
  everything in `home/`, the run refuses while an undeclared file sits
  there.
- `~/.config/nvim/lua/plugins/theme.lua` is deliberately excluded — it is
  Omarchy's live theme symlink (machine state, repointed on theme change).
- Anything the run replaces is backed up under
  `~/.local/state/omarchy-dotfiles/backups/<timestamp>/`.
