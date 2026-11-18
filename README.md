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

## Usage

Every command takes `-d folder` for the backup folder, which defaults to the
current folder.

### Create a backup

```sh
amber init -d /Volumes/Backup/amber \
  --include ~/Documents --include ~/Projects \
  --exclude "*.tmp" --exclude node_modules
```

The folder must not exist yet; `init` creates it. `--include` and `--exclude`
can be repeated. Includes are applied before excludes. An exclude without a `/`
matches file and folder names anywhere, otherwise it matches full paths
(`--exclude "/Users/me/Projects/*/build"`). `init` also takes every option of
`amber config` (see below).

The backup folder can be moved or mounted somewhere else later.

### Back up

```sh
amber backup -d /Volumes/Backup/amber
```

```
new      /Users/me/Documents/notes.txt
changed  /Users/me/Documents/todo.txt
deleted  /Users/me/Documents/old.txt
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
amber config -d /Volumes/Backup/amber        # show every setting
amber config -d /Volumes/Backup/amber --max-versions 10 --min-versions 2 --max-size 500G
amber config -d /Volumes/Backup/amber --keep-deleted 90
amber config -d /Volumes/Backup/amber --no-compress "*.log" --no-compress "/Users/me/Videos/*"
amber config -d /Volumes/Backup/amber --compress "*.zip"
amber config -d /Volumes/Backup/amber --include ~/Music --exclude "*.iso" --remove-exclude "*.tmp"
```

| Option | Default | |
|---|---|---|
| `--include path` | | Adds a path to back up. `--remove-include path` removes one (at least one must be left). |
| `--exclude pattern` | | Adds an exclude. `--remove-exclude pattern` removes one. |
| `--max-versions n` | unlimited | The most previous versions of each file that are kept, on top of its latest version. A delete counts as a version. |
| `--max-size size` | unlimited | The most space the backup can use, like `500G`, `1.5T` or `200M` (powers of 1024). |
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
amber cleanup -d /Volumes/Backup/amber
amber cleanup -d /Volumes/Backup/amber --excluded
```

Removes the versions the settings no longer allow. `backup` does the same
every time it runs. `--excluded` also removes every version of the files the
includes and excludes no longer back up.

### Check

```sh
amber fsck -d /Volumes/Backup/amber
amber fsck -d /Volumes/Backup/amber --hash
```

Checks that nothing in the backup folder is missing or out of place. `--hash`
also reads everything back and checks its contents, which reads the whole
backup.

### List

```sh
amber ls -d /Volumes/Backup/amber ~/Documents
amber ls -d /Volumes/Backup/amber -t "2026-11-01 09:00" ~/Documents ~/Projects
```

```
      482113  2026-11-01 14:30:22  photo.jpg
          11  2026-11-18 11:05:43  notes.txt
      120034  2026-11-17 18:45:10  app/
```

Shows each folder as it was at `-t` (local time, default now). A date by itself
means the end of that day. A folder's size is the total of everything in it.

### Restore

```sh
amber restore -d /Volumes/Backup/amber ~/Documents                       # creates ./Documents
amber restore -d /Volumes/Backup/amber ~/Documents /tmp/old-docs         # creates /tmp/old-docs
amber restore -d /Volumes/Backup/amber ~/Documents/notes.txt             # creates ./notes.txt
amber restore -d /Volumes/Backup/amber -t 2026-11-01 ~/Documents/notes.txt /tmp/notes-nov1.txt
```

Restores a file or folder as it was at `-t` (default now). The target defaults
to its name in the current folder, and must not exist yet. Every restored file
is checked against what was backed up and gets back its modified time.

If the path was deleted at that time, `restore` says when and prints the
command to restore it as it was just before:

```
amber: /Users/me/Documents/notes.txt was deleted at 2026-11-17 10:00:01. To restore it as it was just before then, run:

  amber restore -d /Volumes/Backup/amber -t '2026-11-17 10:00:00' /Users/me/Documents/notes.txt
```

### Stats

```sh
amber stats -d /Volumes/Backup/amber
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

Upgrading amber is safe: existing backups are upgraded automatically the
first time they're opened.

## Building

Needs [V](https://vlang.io) and zlib (`libz`), which macOS has. On Linux
install its headers (for example `zlib1g-dev`).

```sh
v install elliotchance.vsql
v -o amber .
v test .
```
