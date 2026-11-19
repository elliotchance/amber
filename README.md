# 🍯 amber

A backup tool that keeps the full history of every file in a folder, like
Time Machine. Back up as often as you like and restore any file or folder as it
was at any point in time.

- **Every version is kept.** Each change or delete gets a new version number
  for that path, so nothing is lost when a file is edited, deleted or recreated.
- **Fast incremental backups.** Files whose size and modified time haven't
  changed are skipped without being read.
- **Deduplication.** A small edit to a large file stores only the part that
  changed, and identical files are only stored once.
- **Compression.** Files are compressed when that saves space. Already
  compressed formats are skipped, and the list is configurable.
- **Restore by time.** List or restore any file or folder as it was at a given
  time. Restoring something that was deleted then tells you the time to use.
- **Limits and cleanup.** Cap the number of versions, the total size and how
  long deleted files are kept. Old versions are only removed to make room when
  you allow it.
- **Safe.** A backup that is interrupted or runs out of space keeps everything
  backed up so far and carries on next time. `amber fsck` checks nothing is
  missing or damaged.
- **Portable.** A backup is one folder that can be moved or
  mounted anywhere.
- **Scriptable.** Every command exits with a code that says what failed.

## Install

On Linux or macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/elliotchance/amber/main/install.sh | sh
```

It installs the latest release in `~/.local/bin` (or `AMBER_INSTALL_DIR`). Run it
again to update.

`amber version` shows the version you have:

```
v1.2.3 2026-11-18
```

Existing backups are upgraded automatically the first time a new version
opens them. A backup used by a newer amber can't be opened by an older one.

## Usage

Every command takes `-d folder` for the backup folder, which defaults to the
current folder.

### Create a backup

```sh
cd ~/Documents
amber init -d /Volumes/Backup/documents --exclude "*.tmp" --exclude node_modules
```

This backs up the current folder, the root of the backup, into
`/Volumes/Backup/documents`, which must not exist yet. `--root folder` backs up
another folder instead. Every path in the backup is relative to the root.

Everything in the root is backed up, except what's excluded. `--include` limits
it to what matches, and `--exclude` leaves out what matches. Both can be
repeated. A file is backed up if it, or a folder it's in, matches an include
(or there are no includes), and neither it nor any folder it's in matches an
exclude.

| Pattern | Matches |
|---|---|
| `node_modules` | every file or folder named `node_modules`, at any depth |
| `*.tmp` | every `.tmp` file, at any depth |
| `/build` | only `build` in the root |
| `/Projects/*/build` | `build` in each folder of `Projects` |
| `/Notes/**/*.md` | `.md` files at any depth in `Notes` |

A pattern that starts with `/` is anchored to the root. `*` doesn't match `/`,
`**` does. Patterns can't go outside the root.

`init` also takes every option of `amber config` (see below). The backup folder
can be moved or mounted somewhere else later. It has a `README.md` that says
what it is and how to back it up and restore it, which amber keeps up to date.

The index of a backup is `db.vsql` in the backup folder. To keep it somewhere
else (such as off a network volume), give `-f file` to `init` and to every
command after that. It can be moved, as long as `-f` says where it is.

### Back up

```sh
amber backup -d /Volumes/Backup/documents
```

```
new      Notes/ideas.txt
changed  Notes/todo.txt
deleted  old.txt
1 new, 1 changed, 1 deleted, 120 unchanged
```

Files that haven't changed since the last backup are skipped. Each new file,
change or delete becomes a new version of that file. Only the parts of a file
that changed take up more space, and identical content is only stored once.
Files are compressed when that saves space. Symbolic links are skipped.

If the backup is interrupted, or runs out of space, everything backed up until
then is kept, and running `backup` again carries on from there.

### Settings

```sh
amber config -d /Volumes/Backup/documents        # show every setting
amber config -d /Volumes/Backup/documents --max-versions 10 --min-versions 2 --max-size 500G
amber config -d /Volumes/Backup/documents --keep-deleted 90
amber config -d /Volumes/Backup/documents --no-compress "*.log" --no-compress "/Videos"
amber config -d /Volumes/Backup/documents --compress "*.zip"
amber config -d /Volumes/Backup/documents --include /Music --exclude "*.iso" --remove-exclude "*.tmp"
amber config -d /Volumes/Backup/documents --root /Volumes/Other/Documents
```

| Option | Default | |
|---|---|---|
| `--root folder` | the current folder | The folder that's backed up. Changing it is for when the files have moved: nothing else changes, since every path is relative to it. |
| `--include pattern` | everything | Adds an include. `--remove-include pattern` removes one. |
| `--exclude pattern` | | Adds an exclude. `--remove-exclude pattern` removes one. |
| `--max-versions n` | unlimited | The most previous versions of each file that are kept, on top of its latest version. A delete counts as a version. |
| `--max-size size` | unlimited | The most space the backup can use, like `500G`, `1.5T` or `200M`. Units are base 10, like disk sizes: `1K` is 1000 bytes. |
| `--min-versions n` | unlimited | To stay under `--max-size`, the oldest previous versions can be removed, but each file keeps at least this many. With the default nothing is removed, and `backup` stops when it's full. |
| `--keep-deleted days` | forever | How long a deleted file is kept. After that, every version of it is removed. |
| `--no-compress pattern` | already compressed formats | Adds a pattern of files that aren't compressed, matched like excludes but ignoring case. `--compress pattern` removes one. Changes only affect files backed up from then on. |

The latest version of a file that still exists is never removed.

Changing the includes and excludes doesn't change what's already backed up.
Files that are no longer included (or are now excluded) aren't recorded as
deleted: their history is kept, `backup` counts them as "no longer included",
and they can still be restored. Including them again carries on from their
latest version. `amber cleanup --excluded` removes their history.

### Clean up

```sh
amber cleanup -d /Volumes/Backup/documents
amber cleanup -d /Volumes/Backup/documents --excluded
```

Removes the versions the settings no longer allow. `backup` does the same
every time it runs. `--excluded` also removes every version of the files the
includes and excludes no longer back up.

### Check

```sh
amber fsck -d /Volumes/Backup/documents
amber fsck -d /Volumes/Backup/documents --hash
```

Checks that nothing in the backup folder is missing or out of place. `--hash`
also reads everything back and checks its contents, which reads the whole
backup.

### List

```sh
amber ls -d /Volumes/Backup/documents
amber ls -d /Volumes/Backup/documents -t "2026-11-01 09:00" Notes Projects
```

```
      482113  2026-11-01 14:30:22  photo.jpg
          11  2026-11-18 11:05:43  notes.txt
      120034  2026-11-17 18:45:10  app/
```

Shows each folder as it was at `-t` (local time, default now). Paths are
relative to the root, which is listed when no path is given. A date by itself
means the end of that day. A folder's size is the total of everything in it.

### Restore

```sh
amber restore -d /Volumes/Backup/documents . /tmp/documents          # everything
amber restore -d /Volumes/Backup/documents Notes                     # creates ./Notes
amber restore -d /Volumes/Backup/documents Notes/todo.txt            # creates ./todo.txt
amber restore -d /Volumes/Backup/documents -t 2026-11-01 Notes/todo.txt /tmp/todo-nov1.txt
```

Restores a file or folder (relative to the root, or `.` for all of it) as it was
at `-t` (default now). The target defaults to its name in the current folder,
and must not exist yet. Every restored file is checked against what was backed
up and gets back its modified time.

If the path was deleted at that time, `restore` says when and prints the
command to restore it as it was just before:

```
amber: Notes/todo.txt was deleted at 2026-11-17 10:00:01. To restore it as it was just before then, run:

  amber restore -d /Volumes/Backup/documents -t '2026-11-17 10:00:00' Notes/todo.txt
```

### Stats

```sh
amber stats -d /Volumes/Backup/documents
```

Shows the settings, how many backups, files and versions there are, and how
much space they use.

## Exit codes

Every command uses the same exit codes, so scripts can tell what failed:

| Code | |
|---|---|
| 0 | Success |
| 1 | Unknown error |
| 2 | Bad command, option or argument |
| 3 | The folder isn't an amber backup |
| 4 | `init`: the folder already exists |
| 5 | The backup couldn't be created |
| 6 | The backup couldn't be opened |
| 7 | The backup couldn't be read |
| 8 | The backup couldn't be written |
| 9 | The backup was made by a newer amber |
| 10 | A file couldn't be read. `backup` still backs up everything else first. |
| 11 | A file couldn't be compressed |
| 12 | A file couldn't be stored |
| 13 | Out of space, or `--max-size` reached |
| 20 | The path isn't in the backup at that time |
| 21 | The restore target already exists |
| 22 | Part of the backup is missing |
| 23 | Part of the backup couldn't be decompressed |
| 24 | A restored file doesn't match what was backed up |
| 25 | A restored file couldn't be written |
| 26 | The path was deleted at that time |
| 30 | `fsck` found problems |

## Development

amber is written in [V](https://vlang.io). It needs zlib, which macOS already
has (on Linux install `zlib1g-dev`).

```sh
v install elliotchance.vsql
v test .
v -prod -o amber .
```

Pushing a tag that starts with `v` (like `v1.0.0`) publishes the binaries for
every system to its release.
