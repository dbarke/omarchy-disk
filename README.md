# omarchy-disk

Filesystem usage in the [Omarchy](https://omarchy.org/) bar, every mount
metered in the panel, and a fill-rate projection when something is actively
eating the disk.

## Why

A percentage tells you where you are. It does not tell you that something
started writing four minutes ago and will fill the disk before dinner.

This widget keeps usage samples in memory, fits them, and says so:

```
Filling · 2.4G/h · full in 3h 12m
```

The line stays silent until the fit actually means something, so it is not a
number that flickers at you all day. Samples are in memory only — a projection
that survived a reboot would be describing a different machine.

## Install

```bash
omarchy plugin add https://github.com/dbarke/omarchy-disk.git --enable
```

Or clone it into place yourself:

```bash
git clone https://github.com/dbarke/omarchy-disk.git \
  ~/.config/omarchy/plugins/dbarke.disk
omarchy plugin enable dbarke.disk --section right
```

## Use

| Action | Result |
|---|---|
| Click | Open the panel — every filesystem, metered |
| `r` | Refresh now |
| `↑` `↓` | Scroll the list |

At or above the warning threshold the reading turns urgent. With *Warn about
any filesystem* on, a full `/home` tints the bar even while the bar itself is
showing `/` — so the one you are not watching is still the one that warns you.

Projection text shifts from foreground toward urgent as the projected fill gets
closer. The colours are mixed from the active theme rather than hardcoded,
because there is no amber in an Omarchy palette to reach for.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Refresh interval | `30`s | Disk usage moves slowly. Polling harder mostly spawns processes — but the projection does get sharper. |
| Mount point on the bar | `/` | Which filesystem the bar summarises. Falls back to the fullest one if absent. |
| Bar reading | `percent` | `percent` = 42%, `free` = 201G free, `used` = 60G/274G. |
| Warning threshold | `85`% | At or above this the reading turns urgent. `0` disables. |
| Warn about any filesystem | on | Tint the bar when *some other* mount crosses the threshold. |
| Ignore filesystems smaller than | `1` GB | Keeps EFI stubs and small loop mounts out of the list. |
| Collapse subvolumes | on | One row per underlying device. Without it, btrfs subvolumes read as several disks that are all equally full. |
| Hide these mount points | — | JSON array, e.g. `["/boot", "/mnt/backup"]`. |

## Implementation note

The source is `findmnt --json --list --bytes --real`, not `df`. `findmnt` emits
real JSON with byte counts already parsed, so nothing here has to guess where
one whitespace-padded column ends and the next begins — mount points with
spaces in them are common on removable media named from a filesystem label, and
column slicing gets those wrong.

Pseudo and image-backed filesystems that `--real` still lets through
(`squashfs`, `overlay`, `tmpfs`, flatpak runtimes, container overlays…) are
filtered out by type.

## Requirements

- Omarchy 4.x (`omarchy-shell` / Quickshell)
- `findmnt` (util-linux — already on any Arch system)

## License

MIT — see [LICENSE](LICENSE).
