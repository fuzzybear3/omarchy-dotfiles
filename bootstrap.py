#!/usr/bin/env python3
"""omarchy-dotfiles — converge this machine to the repo. One command, no args.

Everything managed is declared in manifest.toml; nothing else is touched.
Every run does the same five things:

  1. ssh       generate the declared key if missing
  2. packages  install missing tracked packages (plus stow, which linking
               needs), then regenerate packages.txt from what is installed
  3. system    add the user to declared groups (usermod -aG; takes effect
               at next login) and enable declared services (systemctl)
  4. config    adopt any declared path that is a real file in $HOME (local
               edits win; the change shows up in git diff), then link
               everything with `stow --no-folding -t ~ home`
  5. reload    hyprland, only if step 4 changed something

Every step detects when its work is already done and no-ops, so running
this at any time is safe. Anything replaced is first backed up under
~/.local/state/omarchy-dotfiles/backups/<timestamp>/.

To stop managing a file: delete its [[config]] entry, git rm it from home/,
and replace the $HOME symlink with a real copy.
To drop a package: uninstall it AND delete its packages.txt line —
otherwise the next run reinstalls it.
"""

from __future__ import annotations

import filecmp
import grp
import os
import pwd
import shutil
import subprocess
import sys
import tomllib
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent
HOME = Path.home()
MANIFEST = REPO / "manifest.toml"
PACKAGES_TXT = REPO / "packages.txt"
STATE = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "omarchy-dotfiles"

SKIP_NAMES = {".git", "__pycache__"}

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------

_TTY = sys.stdout.isatty()


def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _TTY else text


def ok(t: str) -> str:      return _c("32", t)
def warn(t: str) -> str:    return _c("33", t)
def bad(t: str) -> str:     return _c("31", t)
def dim(t: str) -> str:     return _c("2", t)
def bold(t: str) -> str:    return _c("1", t)


def die(msg: str) -> None:
    print(bad(f"error: {msg}"), file=sys.stderr)
    raise SystemExit(1)


# ---------------------------------------------------------------------------
# manifest
# ---------------------------------------------------------------------------

def load_manifest() -> dict:
    if not MANIFEST.exists():
        die(f"{MANIFEST} not found")
    with MANIFEST.open("rb") as fh:
        return tomllib.load(fh)


def package_dir(man: dict) -> Path:
    return REPO / man.get("meta", {}).get("package", "home")


def declared(man: dict) -> list[str]:
    entries = man.get("config", [])
    if not entries:
        die("manifest declares no [[config]] entries")
    return [e["path"] for e in entries]


# ---------------------------------------------------------------------------
# path expansion
# ---------------------------------------------------------------------------

def _walk(root: Path) -> list[Path]:
    out = []
    for p in root.rglob("*"):
        if any(part in SKIP_NAMES for part in p.relative_to(root).parts):
            continue
        if p.is_file() or p.is_symlink():
            out.append(p)
    return out


def expand(pkg: Path, rel: str) -> list[str]:
    """Every concrete file under a declared path, as seen in the repo OR $HOME."""
    found: set[str] = set()

    r = pkg / rel
    if r.is_symlink() or r.is_file():
        found.add(rel)
    elif r.is_dir():
        found.update(str(p.relative_to(pkg)) for p in _walk(r))

    h = HOME / rel
    if h.is_symlink() or h.is_file():
        found.add(rel)
    elif h.is_dir():
        found.update(str(p.relative_to(HOME)) for p in _walk(h))

    return sorted(found)


def excluded(man: dict) -> set[str]:
    return set(man.get("meta", {}).get("exclude", []))


def all_files(man: dict) -> list[str]:
    pkg = package_dir(man)
    ex = excluded(man)
    out: list[str] = []
    for rel in declared(man):
        out.extend(f for f in expand(pkg, rel) if f not in ex)
    return sorted(dict.fromkeys(out))


# ---------------------------------------------------------------------------
# backups
# ---------------------------------------------------------------------------

_backup_dir: Path | None = None


def backup_dir() -> Path:
    global _backup_dir
    if _backup_dir is None:
        _backup_dir = STATE / "backups" / datetime.now().strftime("%Y%m%d-%H%M%S")
        _backup_dir.mkdir(parents=True, exist_ok=True)
    return _backup_dir


def backup(path: Path, rel: str) -> Path:
    dest = backup_dir() / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)
    return dest


# ---------------------------------------------------------------------------
# 1. ssh
# ---------------------------------------------------------------------------

def step_ssh(man: dict) -> None:
    cfg = man.get("ssh")
    if not cfg:
        print(f"  {dim('no [ssh] section in manifest — skipped')}")
        return

    key = Path(cfg["key"]).expanduser()
    pub = key.with_suffix(".pub")

    if key.exists():
        fp = subprocess.run(["ssh-keygen", "-lf", str(pub if pub.exists() else key)],
                            capture_output=True, text=True).stdout.strip()
        print(f"  {ok('exists'.rjust(10))}  {key}  {dim(fp)}")
        # self-heal permissions, quietly
        fixed = []
        if key.parent.stat().st_mode & 0o777 != 0o700:
            key.parent.chmod(0o700); fixed.append(str(key.parent))
        if key.stat().st_mode & 0o777 != 0o600:
            key.chmod(0o600); fixed.append(str(key))
        if fixed:
            print(f"  {warn('fixed perms'.rjust(10))}  {', '.join(fixed)}")
        return

    key.parent.mkdir(parents=True, exist_ok=True)
    key.parent.chmod(0o700)
    cmd = ["ssh-keygen",
           "-t", cfg.get("type", "ed25519"),
           "-a", str(cfg.get("rounds", 100)),
           "-C", cfg.get("comment", ""),
           "-f", str(key), "-N", ""]
    if subprocess.run(cmd, capture_output=True, text=True).returncode != 0:
        die(f"ssh-keygen failed: {' '.join(cmd)}")
    fp = subprocess.run(["ssh-keygen", "-lf", str(pub)],
                        capture_output=True, text=True).stdout.strip()
    print(f"  {ok('generated'.rjust(10))}  {key}  {dim(fp)}")
    print(f"  {warn('action'.rjust(10))}  add the public key to GitHub/servers:")
    print(f"              {pub.read_text().strip()}")


# ---------------------------------------------------------------------------
# 2. packages
# ---------------------------------------------------------------------------

def _pacman(*a: str) -> list[str]:
    r = subprocess.run(["pacman", *a], capture_output=True, text=True)
    return [ln for ln in r.stdout.splitlines() if ln.strip()]


def pkg_installed(name: str) -> bool:
    return subprocess.run(["pacman", "-Qq", name],
                          capture_output=True, text=True).returncode == 0


def current_extras(man: dict) -> list[str]:
    """Explicitly-installed packages minus everything Omarchy itself declares."""
    cfg = man.get("packages", {})
    distro: set[str] = set()
    for path in cfg.get("distro_manifests", []):
        p = Path(path)
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            line = line.split("#", 1)[0]
            distro.update(line.split())

    ignore = set(cfg.get("ignore", []))
    suffixes = tuple(cfg.get("ignore_suffixes", []))

    explicit = set(_pacman("-Qqe"))
    mine = explicit - distro - ignore
    if suffixes:
        mine = {p for p in mine if not p.endswith(suffixes)}
    return sorted(mine)


def read_packages() -> tuple[list[str], list[str]]:
    """packages.txt split into its two sections: (official repos, AUR)."""
    repo_pkgs: list[str] = []
    aur_pkgs: list[str] = []
    in_aur = False
    if not PACKAGES_TXT.exists():
        return repo_pkgs, aur_pkgs
    for line in PACKAGES_TXT.read_text().splitlines():
        if line.lstrip().startswith("#") and "AUR" in line:
            in_aur = True
        name = line.split("#", 1)[0].strip()
        if name:
            (aur_pkgs if in_aur else repo_pkgs).append(name)
    return repo_pkgs, aur_pkgs


def step_packages(man: dict) -> None:
    tracked_repo, tracked_aur = read_packages()
    before = set(tracked_repo) | set(tracked_aur)
    # stow is this tool's own dependency (linking shells out to it), and
    # packages.txt — generated from installed state — can't bootstrap it.
    if "stow" not in tracked_repo:
        tracked_repo = ["stow", *tracked_repo]

    missing_repo = [p for p in tracked_repo if not pkg_installed(p)]
    missing_aur = [p for p in tracked_aur if not pkg_installed(p)]

    cmds = []
    if missing_repo:
        cmds.append(["sudo", "pacman", "-S", "--needed", *missing_repo])
    if missing_aur:
        cmds.append(["yay", "-S", "--needed", *missing_aur])
    for c in cmds:
        print(f"  {bold('$')} {' '.join(c)}")
        if subprocess.run(c).returncode != 0:
            die(f"command failed: {' '.join(c)}")

    # Record reality back into packages.txt: hand-installed extras get added.
    # A package leaves the list by being uninstalled AND deleted from it.
    mine = current_extras(man)
    foreign = set(_pacman("-Qqm"))
    repo_pkgs = [p for p in mine if p not in foreign]
    aur_pkgs = [p for p in mine if p in foreign]

    lines = [
        "# GENERATED by ./bootstrap.py — packages explicitly installed on top of",
        "# what Omarchy ships. Each run installs what is listed but missing, then",
        "# records what is installed but unlisted. To drop a package: uninstall",
        "# it and delete its line here.",
        "",
        "# --- official repos (pacman) ---",
        *repo_pkgs,
        "",
        "# --- AUR (yay) ---",
        *aur_pkgs,
        "",
    ]
    new = "\n".join(lines)
    old = PACKAGES_TXT.read_text() if PACKAGES_TXT.exists() else ""
    if new == old:
        print(f"  {ok('in sync')}  packages.txt  {dim(f'{len(repo_pkgs)} repo + {len(aur_pkgs)} AUR')}")
        return
    PACKAGES_TXT.write_text(new)
    print(f"  {ok('recorded')}  packages.txt  {dim(f'{len(repo_pkgs)} repo + {len(aur_pkgs)} AUR')}")
    for p in sorted(set(mine) - before):
        print(f"    {dim('+')} {p}")
    for p in sorted(before - set(mine)):
        print(f"    {dim('-')} {p}")


# ---------------------------------------------------------------------------
# 3. system — group memberships and enabled services
# ---------------------------------------------------------------------------

def step_system(man: dict) -> None:
    cfg = man.get("system", {})
    groups = cfg.get("groups", [])
    services = cfg.get("services", [])
    if not groups and not services:
        print(f"  {dim('no [system] groups or services declared — skipped')}")
        return

    me = pwd.getpwuid(os.getuid())
    session_gids = set(os.getgroups())
    to_add = []
    for g in groups:
        try:
            info = grp.getgrnam(g)
        except KeyError:
            die(f"group does not exist: {g}")
        if me.pw_name not in info.gr_mem and info.gr_gid != me.pw_gid:
            to_add.append(g)
        elif info.gr_gid in session_gids:
            print(f"  {ok('member')}  {g}")
        else:
            print(f"  {warn('pending')}  {g}  {dim('(log out and back in to activate)')}")

    if to_add:
        c = ["sudo", "usermod", "-aG", ",".join(to_add), me.pw_name]
        print(f"  {bold('$')} {' '.join(c)}")
        if subprocess.run(c).returncode != 0:
            die(f"command failed: {' '.join(c)}")
        for g in to_add:
            print(f"  {ok('added')}  {g}  {dim('(log out and back in to activate)')}")

    for svc in services:
        enabled = subprocess.run(["systemctl", "is-enabled", svc],
                                 capture_output=True, text=True).stdout.strip()
        active = subprocess.run(["systemctl", "is-active", svc],
                                capture_output=True, text=True).stdout.strip()
        if enabled == "enabled" and active == "active":
            print(f"  {ok('running')}  {svc}")
            continue
        c = ["sudo", "systemctl", "enable", "--now", svc]
        print(f"  {bold('$')} {' '.join(c)}")
        if subprocess.run(c).returncode != 0:
            die(f"command failed: {' '.join(c)}")
        print(f"  {ok('enabled')}  {svc}")


# ---------------------------------------------------------------------------
# 4. config — adopt real files, then link everything via GNU Stow
# ---------------------------------------------------------------------------

def stow_bin() -> str:
    s = shutil.which("stow")
    if not s:
        die("GNU Stow is not installed and the packages step did not install it")
    return s


def run_stow(man: dict, *extra: str) -> None:
    pkg = package_dir(man)
    cmd = [stow_bin(), "--no-folding", *extra,
           "-d", str(pkg.parent), "-t", str(HOME), pkg.name]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"stow failed: {' '.join(cmd)}\n{r.stderr.strip()}")


def check_strays(man: dict) -> None:
    """Stow links everything in the package dir, so the manifest and the dir
    must agree — refuse to converge while an undeclared file sits in home/."""
    pkg = package_dir(man)
    managed = set(all_files(man))
    strays = sorted(str(p.relative_to(pkg)) for p in _walk(pkg)
                    if str(p.relative_to(pkg)) not in managed
                    and str(p.relative_to(pkg)) != ".stow-local-ignore")
    if strays:
        die(f"in {pkg.name}/ but not declared in manifest.toml "
            "(stow would link them — declare or remove):\n  " + "\n  ".join(strays))


def _stow_owned(r: Path, h: Path) -> bool:
    """A relative symlink resolving to the repo file — what stow creates and
    recognizes. Absolute links (from older bootstraps) conflict."""
    try:
        return h.resolve() == r.resolve() and not os.path.isabs(os.readlink(h))
    except OSError:
        return False


def step_config(man: dict) -> int:
    check_strays(man)
    pkg = package_dir(man)

    adopted = 0
    for rel in all_files(man):
        r, h = pkg / rel, HOME / rel
        if h.is_symlink() or not h.exists():
            continue
        if r.exists() and not filecmp.cmp(r, h, shallow=False):
            b = backup(r, f"repo/{rel}")
            print(f"  {warn('conflict')}  {rel}  {dim(f'repo copy backed up to {b}')}")
        r.parent.mkdir(parents=True, exist_ok=True)
        backup(h, f"home/{rel}")
        shutil.move(str(h), str(r))
        print(f"  {ok('adopted')}  {rel}")
        adopted += 1

    fresh: list[str] = []      # no target in $HOME yet
    relink: list[str] = []     # symlink stow won't own: absolute, foreign, dangling
    already = 0
    for rel in all_files(man):
        r, h = pkg / rel, HOME / rel
        if not (r.is_file() or r.is_symlink()):
            continue
        if h.is_symlink():
            if _stow_owned(r, h):
                already += 1
            else:
                relink.append(rel)
        else:
            fresh.append(rel)

    for rel in relink:
        (HOME / rel).unlink()
    if fresh or relink:
        run_stow(man)
    for rel in relink:
        print(f"  {ok('relinked')}  {rel}")
    for rel in fresh:
        print(f"  {ok('linked')}  {rel}")

    changed = adopted + len(fresh) + len(relink)
    if changed == 0:
        print(f"  {ok('nothing to do')}  all {already} files adopted and linked")
    else:
        print(f"  adopted {bold(str(adopted))}, linked {bold(str(len(fresh)))}, "
              f"relinked {bold(str(len(relink)))}, already linked {bold(str(already))}")
        if adopted:
            print(dim(f"  originals backed up under {backup_dir()}"))
    return changed


# ---------------------------------------------------------------------------
# 5. reload
# ---------------------------------------------------------------------------

def step_reload(changed: int) -> None:
    if not changed:
        print(dim("  nothing changed — skipped"))
        return
    if shutil.which("hyprctl") and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        subprocess.run(["hyprctl", "reload"], capture_output=True)
        errs = subprocess.run(["hyprctl", "configerrors"],
                              capture_output=True, text=True).stdout.strip()
        print(f"  {ok('hyprland reloaded')}" if not errs or "no errors" in errs.lower()
              else f"  {bad('hyprland config errors')}\n{errs}")
    else:
        print(dim("  hyprland not running — skipped"))


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    if len(sys.argv) > 1:
        die("bootstrap.py takes no arguments — every run converges everything "
            "(ssh key, packages, system groups/services, config links, reload)")
    man = load_manifest()

    print(bold("1/5  ssh key"))
    step_ssh(man)
    print()
    print(bold("2/5  packages"))
    step_packages(man)
    print()
    print(bold("3/5  system"))
    step_system(man)
    print()
    print(bold("4/5  config"))
    changed = step_config(man)
    print()
    print(bold("5/5  reload"))
    step_reload(changed)
    print()
    print(ok("  converged."))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
