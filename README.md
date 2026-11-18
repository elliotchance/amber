# 🍯 amber

A backup tool that keeps the full history of every file in a folder, like
Time Machine. Written in [V](https://vlang.io) and stores its index in
[vsql](https://github.com/elliotchance/vsql).

🚧 Work in progress.

## Usage

A backup is one folder that holds the index (`db.vsql`) and every stored
file. Every command takes `-d folder` for it, which defaults to the current
folder.

### Create a backup

```sh
amber init -d /Volumes/Backup/amber \
  --include ~/Documents --include ~/Projects \
  --exclude "*.tmp" --exclude node_modules
```

The folder must not exist yet; `init` creates it. `--include` and `--exclude`
can be repeated. Includes are applied before excludes. An exclude without a `/`
matches file and folder names, otherwise it matches full paths
(`--exclude "/Users/me/Projects/*/build"`). `init` also takes `--max-versions`
and `--max-size` (see below).

The index doesn't store where the backup folder is, so it can be moved or
mounted somewhere else.

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

A file whose size and modified time match its latest version is skipped.
Otherwise it's hashed (SHA-256) and stored once in the backup folder at
`AB/CD/SHA256`, where `AB` and `CD` are the first four characters of the hash.
Files with the same content share one object, so touching a file without
changing it adds a version but doesn't store anything new.

Files with an already compressed extension (MP3, MP4, JPEG, ZIP, RAR, ...) and
files smaller than a block are stored as is. Everything else is zipped with the
`zip` command, which streams, so any file size works. A zipped object is only
kept if it's smaller than the original. Objects are normal ZIP files, so
`unzip -p` can recover one without amber.

Every change to a path, including a delete, is a new version numbered from 1.
Symbolic links are skipped.

### Limits

```sh
amber config -d /Volumes/Backup/amber                       # show the settings
amber config -d /Volumes/Backup/amber --max-versions 10 --max-size 500G
amber config -d /Volumes/Backup/amber --max-size unlimited
```

- `--max-versions` is how many previous versions of each file are kept, on top
  of its latest version. A delete counts as a version.
- `--max-size` (like `500G`, `1.5T` or `200M`, in powers of 1024) is the most
  space the stored objects can use.

Both default to unlimited and can be changed at any time. `backup` prunes
before and after it runs: first old versions beyond `--max-versions`, then the
oldest previous versions until the objects fit `--max-size`. The latest version
of a file is never pruned. Version numbers are never reused.

If a new object wouldn't fit (or the disk fills up), `backup` stops. Every file
backed up before that is kept, and nothing of the file that didn't fit is left
behind, so after raising the limit (or freeing space) `backup` carries on from
there.

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
amber restore -d /Volumes/Backup/amber ~/Documents /tmp/documents
amber restore -d /Volumes/Backup/amber -t 2026-11-01 ~/Documents/notes.txt /tmp/old-notes
```

Copies a folder (or a file) as it was at `-t` into a new folder, which must not
already exist. Files are unzipped, checked against their SHA-256 and get back
their modified times.

### Stats

```sh
amber stats -d /Volumes/Backup/amber
```

## Exit codes

Every command uses the same exit codes. Each one is the stage that failed:

| Code | Stage |
|---|---|
| 0 | Success |
| 1 | Unknown (a bug: every error should have a stage) |
| 2 | Usage: bad command, flag or argument |
| 3 | Index missing: the folder has no `db.vsql` |
| 4 | Index exists: the `init` folder already exists |
| 5 | Create index |
| 6 | Open index |
| 7 | Read index |
| 8 | Write index |
| 10 | Read source: a file couldn't be read or hashed. `backup` still backs up everything else first. |
| 11 | Compress (`zip`) |
| 12 | Write object |
| 13 | No space: `--max-size` reached |
| 14 | `zip` or `unzip` isn't installed |
| 20 | Not found: the path isn't in the backup at that time |
| 21 | The restore target already exists |
| 22 | Missing object: the index points to an object that isn't there |
| 23 | Decompress (`unzip`) |
| 24 | Checksum: a restored file doesn't match its SHA-256 |
| 25 | Write target: writing a restored file or its modified time |

## Index

| Table | |
|---|---|
| `config` | `max_versions` and `max_size` (NULL for unlimited). |
| `patterns` | Include and exclude globs. |
| `objects` | One row per stored object: SHA-256, original and stored size, compression (`NONE` or `ZIP`). |
| `files` | One row per version of a path: version number, size, modified time (microseconds), SHA-256, whether it was deleted, and when it was backed up. |

## Building

Needs `zip` and `unzip` at runtime.

```sh
v install elliotchance.vsql
v -o amber .
v test .
```
