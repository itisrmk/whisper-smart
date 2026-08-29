# AUR packaging

Two packages, sharing an identical build:

| Package | Source | Use it when |
|---|---|---|
| `whisper-smart-git` | tip of `main` | Now — needs no release infrastructure |
| `whisper-smart` | `vX.Y.Z` source tarball | Once a release is tagged |

`whisper-smart-git` is the one that has actually been built and tested with
`makepkg`. The stable package differs only in `source` and `pkgver`; it uses
the source tarball GitHub generates for a `vX.Y.Z` tag, which the release
workflow creates for every release.

Until either is published, the supported install is the source one:

```bash
git clone https://github.com/itisrmk/whisper-smart
cd whisper-smart/linux && bash packaging/install.sh
```

## Why `options=('!lto')`

makepkg turns on link-time optimisation for C by default. The `ring` crate
(pulled in by the rustls stack behind `ureq`) ships hand-written assembly, and
under makepkg's LTO flags those objects reach the linker without their symbols:

```
ld.lld: error: undefined symbol: ring_core_0_17_14__x25519_sc_reduce
```

Disabling makepkg's LTO fixes it. Rust-level LTO is untouched — the release
profile in `linux/Cargo.toml` still sets `lto = "thin"`.

## Publishing

> **Blocked as of 2026-08-29.** AUR account registration is temporarily paused
> ("New account registration is temporarily closed", HTTP 503) while the Arch
> team deals with a wave of automated signups. It is not specific to us. Watch
> `aur-general` or the Arch news feed; the packaging below is ready to push the
> moment registration reopens.

Needs an [AUR account](https://aur.archlinux.org/register) with an SSH public
key registered under *My Account → SSH Public Key*.

```bash
# 1. One-time: create a key and add the public half to your AUR account
ssh-keygen -t ed25519 -f ~/.ssh/aur -C "aur@$(hostname)"
cat ~/.ssh/aur.pub          # paste into aur.archlinux.org

cat >> ~/.ssh/config <<'SSH'
Host aur.archlinux.org
  IdentityFile ~/.ssh/aur
  User aur
SSH

# 2. Clone the (empty) AUR repo for the package name
git clone ssh://aur@aur.archlinux.org/whisper-smart-git.git /tmp/aur-whisper-smart-git
cd /tmp/aur-whisper-smart-git

# 3. Copy the packaging in. Only PKGBUILD and .SRCINFO belong in an AUR repo.
cp /path/to/whisper-smart/linux/packaging/aur/whisper-smart-git/{PKGBUILD,.SRCINFO} .

# 4. Verify before pushing: this must succeed and .SRCINFO must be current
makepkg --printsrcinfo > .SRCINFO
makepkg -f            # builds and runs the test suite

# 5. Publish
git add PKGBUILD .SRCINFO
git commit -m "Initial import: whisper-smart-git"
git push origin master     # AUR uses `master`, not `main`
```

After that, `yay -S whisper-smart-git` works for everyone.

## Updating

The `-git` package tracks `main` on its own — `pkgver()` derives the version
from the commit count, so users get new commits by rebuilding. You only need to
push again when the packaging itself changes (a new dependency, a new installed
file). Always regenerate `.SRCINFO` in the same commit; the AUR rejects a push
whose `.SRCINFO` disagrees with its `PKGBUILD`.
