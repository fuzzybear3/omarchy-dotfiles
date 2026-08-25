#!/usr/bin/env python3
"""omarchy-dotfiles — declarative config and package management for Omarchy.

Everything this repo manages is declared in manifest.toml. This tool moves
declared files into the repo, symlinks them back into $HOME, and keeps a
generated list of the packages you installed on top of the distro.

Layout is GNU Stow compatible: `stow -t ~ home` does the same thing as
`bootstrap.py link`. Linking is per-file (stow's --no-folding behaviour)
because Omarchy adds new files to ~/.config on update, and a folded
directory symlink would swallow them.

Usage:
    ./bootstrap.py status              show drift between repo, manifest, $HOME
    ./bootstrap.py adopt               pull declared files into the repo, symlink back
    ./bootstrap.py link                symlink repo files into $HOME
    ./bootstrap.py unlink              remove symlinks, restore real files
    ./bootstrap.py packages sync       regenerate packages.txt from this machine
    ./bootstrap.py packages install    install anything in packages.txt that is missing
    ./bootstrap.py bootstrap           fresh machine: link + install packages + reload
"""

from __future__ import annotations

import argparse
import filecmp
import os
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


def notes(man: dict) -> dict[str, str]:
    return {e["path"]: e.get("note", "") for e in man.get("config", [])}


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
# status
# ---------------------------------------------------------------------------

LINKED, UNLINKED, UNADOPTED, COPY, DRIFT, FOREIGN, ABSENT = (
    "linked", "unlinked", "unadopted", "copy", "drift", "foreign", "absent")

STATUS_STYLE = {
    LINKED:    (ok,   "linked"),
    UNLINKED:  (warn, "not linked"),
    UNADOPTED: (warn, "not in repo"),
    COPY:      (warn, "copy, not linked"),
    DRIFT:     (bad,  "DRIFT"),
    FOREIGN:   (bad,  "foreign symlink"),
    ABSENT:    (dim,  "absent"),
}


def classify(pkg: Path, rel: str) -> str:
    r, h = pkg / rel, HOME / rel
    r_exists = r.is_file() or r.is_symlink()

    if h.is_symlink():
        try:
            return LINKED if h.resolve() == r.resolve() else FOREIGN
        except OSError:
            return FOREIGN
    if not h.exists():
        return UNLINKED if r_exists else ABSENT
    if not r_exists:
        return UNADOPTED
    return COPY if filecmp.cmp(r, h, shallow=False) else DRIFT


def cmd_status(man: dict, args) -> int:
    pkg = package_dir(man)
    note = notes(man)
    counts: dict[str, int] = {}
    print(bold(f"config  {dim('(repo: ' + str(REPO) + ')')}"))
    ex = excluded(man)
    for rel in declared(man):
        files = [f for f in expand(pkg, rel) if f not in ex]
        if not files:
            print(f"  {STATUS_STYLE[ABSENT][0]('absent'.rjust(16))}  {rel}  {dim(note.get(rel,''))}")
            counts[ABSENT] = counts.get(ABSENT, 0) + 1
            continue
        if len(files) == 1 and files[0] == rel:
            st = classify(pkg, rel)
            counts[st] = counts.get(st, 0) + 1
            style, label = STATUS_STYLE[st]
            print(f"  {style(label.rjust(16))}  {rel}  {dim(note.get(rel,''))}")
        else:
            sub = [classify(pkg, f) for f in files]
            worst = next((s for s in (DRIFT, FOREIGN, UNADOPTED, COPY, UNLINKED) if s in sub), LINKED)
            for s in sub:
                counts[s] = counts.get(s, 0) + 1
            style, label = STATUS_STYLE[worst]
            print(f"  {style(label.rjust(16))}  {rel}/  {dim(f'{len(files)} files')}  {dim(note.get(rel,''))}")
            if args.verbose:
                for f, s in zip(files, sub):
                    st, lb = STATUS_STYLE[s]
                    print(f"      {st(lb.rjust(16))}  {f}")

    print()
    summary = "  ".join(f"{STATUS_STYLE[k][0](STATUS_STYLE[k][1])}: {v}" for k, v in sorted(counts.items()))
    print(f"  {summary}")

    print()
    print(bold("ssh"))
    ssh_cfg = man.get("ssh")
    if ssh_cfg:
        k = Path(ssh_cfg["key"]).expanduser()
        if k.exists():
            print(f"  {ok('exists'.rjust(16))}  {k}")
        else:
            print(f"  {warn('missing'.rjust(16))}  {k}  {dim('(run: ssh)')}")
    else:
        print(f"  {dim('not declared'.rjust(16))}")

    print()
    print(bold("packages"))
    if PACKAGES_TXT.exists():
        declared_pkgs = read_packages()
        missing = [p for p in declared_pkgs if not pkg_installed(p)]
        drifted = current_extras(man)
        untracked = sorted(set(drifted) - set(declared_pkgs))
        stale = sorted(set(declared_pkgs) - set(drifted))
        print(f"  {ok('tracked'.rjust(16))}  {len(declared_pkgs)} in packages.txt")
        if missing:
            print(f"  {warn('not installed'.rjust(16))}  {', '.join(missing)}")
        if untracked:
            print(f"  {warn('untracked'.rjust(16))}  {', '.join(untracked)}  {dim('(run: packages sync)')}")
        if stale:
            print(f"  {warn('removed'.rjust(16))}  {', '.join(stale)}  {dim('(run: packages sync)')}")
        if not (missing or untracked or stale):
            print(f"  {ok('in sync'.rjust(16))}  nothing to do")
    else:
        print(f"  {warn('missing'.rjust(16))}  packages.txt  {dim('(run: packages sync)')}")

    bad_states = {DRIFT, FOREIGN, UNADOPTED}
    return 1 if any(counts.get(s) for s in bad_states) else 0


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
# adopt / link / unlink
# ---------------------------------------------------------------------------

def cmd_adopt(man: dict, args) -> int:
    pkg = package_dir(man)
    moved = linked = skipped = 0

    for rel in all_files(man):
        r, h = pkg / rel, HOME / rel

        if h.is_symlink():
            skipped += 1
            continue
        if not h.exists():
            skipped += 1
            continue

        if r.exists() and not filecmp.cmp(r, h, shallow=False):
            b = backup(r, f"repo/{rel}")
            print(f"  {warn('conflict')}  {rel}  {dim(f'repo copy backed up to {b}')}")

        if args.dry_run:
            print(f"  {dim('would adopt')}  {rel}")
            continue

        r.parent.mkdir(parents=True, exist_ok=True)
        backup(h, f"home/{rel}")
        shutil.move(str(h), str(r))
        h.symlink_to(r)
        print(f"  {ok('adopted')}  {rel}")
        moved += 1
        linked += 1

    print()
    if args.dry_run:
        print(dim("  dry run — nothing changed"))
    elif moved == 0:
        print(f"  {ok('nothing to do')}  all {skipped} files already adopted")
    else:
        print(f"  adopted {bold(str(moved))}, already handled {bold(str(skipped))}")
        print(dim(f"  originals backed up under {backup_dir()}"))
    return 0


def cmd_link(man: dict, args) -> int:
    pkg = package_dir(man)
    made = already = replaced = 0

    for rel in all_files(man):
        r, h = pkg / rel, HOME / rel
        if not (r.is_file() or r.is_symlink()):
            continue

        if h.is_symlink():
            try:
                if h.resolve() == r.resolve():
                    already += 1
                    continue
            except OSError:
                pass
            if args.dry_run:
                print(f"  {dim('would relink')}  {rel}")
                continue
            h.unlink()
        elif h.exists():
            if args.dry_run:
                print(f"  {dim('would replace')}  {rel}  {dim('(real file, will be backed up)')}")
                continue
            backup(h, f"home/{rel}")
            h.unlink()
            replaced += 1

        if args.dry_run:
            print(f"  {dim('would link')}  {rel}")
            continue

        h.parent.mkdir(parents=True, exist_ok=True)
        h.symlink_to(r)
        print(f"  {ok('linked')}  {rel}")
        made += 1

    print()
    if args.dry_run:
        print(dim("  dry run — nothing changed"))
    elif made == replaced == 0:
        print(f"  {ok('nothing to do')}  all {already} files already linked")
    else:
        print(f"  linked {bold(str(made))}, already linked {bold(str(already))}, replaced {bold(str(replaced))}")
        if replaced:
            print(dim(f"  replaced files backed up under {backup_dir()}"))
    return 0


def cmd_unlink(man: dict, args) -> int:
    pkg = package_dir(man)
    n = 0
    for rel in all_files(man):
        r, h = pkg / rel, HOME / rel
        if not h.is_symlink():
            continue
        try:
            if h.resolve() != r.resolve():
                continue
        except OSError:
            continue
        if args.dry_run:
            print(f"  {dim('would restore')}  {rel}")
            continue
        h.unlink()
        shutil.copy2(r, h)
        print(f"  {ok('restored')}  {rel}  {dim('(real file)')}")
        n += 1
    print()
    print(dim("  dry run — nothing changed") if args.dry_run else f"  restored {bold(str(n))}")
    return 0


# ---------------------------------------------------------------------------
# packages
# ---------------------------------------------------------------------------

def _pacman(*a: str) -> list[str]:
    r = subprocess.run(["pacman", *a], capture_output=True, text=True)
    return [ln for ln in r.stdout.splitlines() if ln.strip()]


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


def pkg_installed(name: str) -> bool:
    return subprocess.run(["pacman", "-Qq", name],
                          capture_output=True, text=True).returncode == 0


def read_packages() -> list[str]:
    if not PACKAGES_TXT.exists():
        return []
    out = []
    for line in PACKAGES_TXT.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out


def cmd_packages_sync(man: dict, args) -> int:
    mine = current_extras(man)
    foreign = set(_pacman("-Qqm"))
    repo_pkgs = [p for p in mine if p not in foreign]
    aur_pkgs = [p for p in mine if p in foreign]

    lines = [
        "# GENERATED by ./bootstrap.py packages sync — do not edit by hand.",
        "#",
        "# Packages explicitly installed on top of what Omarchy itself ships.",
        "# Regenerate after installing or removing anything you want tracked.",
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

    if args.dry_run:
        print(new)
        return 0

    PACKAGES_TXT.write_text(new)
    verb = "unchanged" if new == old else "updated"
    print(f"  {ok(verb)}  packages.txt  {dim(f'{len(repo_pkgs)} repo + {len(aur_pkgs)} AUR')}")
    for p in repo_pkgs:
        print(f"    {dim('repo')}  {p}")
    for p in aur_pkgs:
        print(f"    {dim('aur ')}  {p}")
    return 0


def cmd_packages_install(man: dict, args) -> int:
    declared_pkgs = read_packages()
    if not declared_pkgs:
        die("packages.txt is empty or missing — run: ./bootstrap.py packages sync")

    missing = [p for p in declared_pkgs if not pkg_installed(p)]
    if not missing:
        print(f"  {ok('nothing to do')}  all {len(declared_pkgs)} tracked packages installed")
        return 0

    foreign = set(_pacman("-Qqm"))
    aur = [p for p in missing if p in foreign]
    repo_pkgs = [p for p in missing if p not in foreign]

    cmds = []
    if repo_pkgs:
        cmds.append(["sudo", "pacman", "-S", "--needed", *repo_pkgs])
    if aur or (not repo_pkgs and missing):
        rest = aur or missing
        cmds.append(["yay", "-S", "--needed", *rest])

    for c in cmds:
        print(f"  {bold('$')} {' '.join(c)}")
        if args.dry_run:
            continue
        if subprocess.run(c).returncode != 0:
            die(f"command failed: {' '.join(c)}")
    return 0


# ---------------------------------------------------------------------------
# ssh
# ---------------------------------------------------------------------------

def cmd_ssh(man: dict, args) -> int:
    cfg = man.get("ssh")
    if not cfg:
        print(f"  {dim('no [ssh] section in manifest — skipped')}")
        return 0

    key = Path(cfg["key"]).expanduser()
    pub = key.with_suffix(".pub")

    if key.exists():
        fp = subprocess.run(["ssh-keygen", "-lf", str(pub if pub.exists() else key)],
                            capture_output=True, text=True).stdout.strip()
        print(f"  {ok('exists'.rjust(16))}  {key}  {dim(fp)}")
        # self-heal permissions, quietly
        fixed = []
        if key.parent.stat().st_mode & 0o777 != 0o700:
            key.parent.chmod(0o700); fixed.append(str(key.parent))
        if key.stat().st_mode & 0o777 != 0o600:
            key.chmod(0o600); fixed.append(str(key))
        if fixed:
            print(f"  {warn('fixed perms'.rjust(16))}  {', '.join(fixed)}")
        return 0

    if args.dry_run:
        print(f"  {dim('would generate')}  {cfg.get('type', 'ed25519')} key at {key}")
        return 0

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
    print(f"  {ok('generated'.rjust(16))}  {key}  {dim(fp)}")
    print(f"  {warn('action needed'.rjust(16))}  add the public key to GitHub/servers:")
    print(f"                    {pub.read_text().strip()}")
    return 0


# ---------------------------------------------------------------------------
# bootstrap
# ---------------------------------------------------------------------------

def cmd_bootstrap(man: dict, args) -> int:
    print(bold("1/4  ssh key"))
    cmd_ssh(man, args)
    print()
    print(bold("2/4  linking config"))
    cmd_link(man, args)
    print()
    print(bold("3/4  installing packages"))
    cmd_packages_install(man, args)
    print()
    print(bold("4/4  reloading"))
    if args.dry_run:
        print(dim("  would reload hyprland"))
        return 0
    if shutil.which("hyprctl") and os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        subprocess.run(["hyprctl", "reload"], capture_output=True)
        errs = subprocess.run(["hyprctl", "configerrors"], capture_output=True, text=True).stdout.strip()
        print(f"  {ok('hyprland reloaded')}" if not errs or "no errors" in errs.lower()
              else f"  {bad('hyprland config errors')}\n{errs}")
    else:
        print(dim("  hyprland not running — skipped"))
    print()
    print(ok("  done. `./bootstrap.py status` to verify."))
    return 0


# ---------------------------------------------------------------------------
# cli
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(
        prog="bootstrap.py",
        description="Declarative config and package management for Omarchy.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("-n", "--dry-run", action="store_true", help="show what would happen, change nothing")
    p.add_argument("-v", "--verbose", action="store_true", help="expand directories file by file")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="show drift between repo, manifest and $HOME")
    sub.add_parser("adopt", help="pull declared files into the repo and symlink them back")
    sub.add_parser("link", help="symlink repo files into $HOME")
    sub.add_parser("unlink", help="remove symlinks, restore real files")
    sub.add_parser("ssh", help="generate the declared SSH key if missing (no-op otherwise)")
    sub.add_parser("bootstrap", help="fresh machine: ssh key + link + packages + reload")

    pk = sub.add_parser("packages", help="manage the tracked package list")
    pksub = pk.add_subparsers(dest="subcmd", required=True)
    pksub.add_parser("sync", help="regenerate packages.txt from this machine")
    pksub.add_parser("install", help="install tracked packages that are missing")

    args = p.parse_args()
    man = load_manifest()

    if args.cmd == "packages":
        return {"sync": cmd_packages_sync, "install": cmd_packages_install}[args.subcmd](man, args)
    return {
        "status": cmd_status,
        "ssh": cmd_ssh,
        "adopt": cmd_adopt,
        "link": cmd_link,
        "unlink": cmd_unlink,
        "bootstrap": cmd_bootstrap,
    }[args.cmd](man, args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
