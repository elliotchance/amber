# 🍯 amber

A backup tool that keeps the full history of every file in a folder, like
Time Machine. Written in [V](https://vlang.io) and stores its index in
[vsql](https://github.com/elliotchance/vsql).

🚧 Work in progress.

## Usage

Every command takes `-f file.vsql` for the index, which defaults to
`amber.vsql` in the current folder.

### Create a backup

```sh
amber init \
  --include ~/Documents --include ~/Projects \
  --exclude "*.tmp" --exclude node_modules \
  --destination /Volumes/Backup/amber
```

`--include` and `--exclude` can be repeated. Includes are applied before
excludes. An exclude without a `/` matches file and folder names, otherwise it
matches full paths (`--exclude "/Users/me/Projects/*/build"`). The destination
folder must already exist. `init` only creates a new index; it fails if the
file already exists. It also takes `--max-versions` and `--max-size` (see
below).

### Limits

```sh
amber config                                  # show the settings
amber config --max-versions 10 --max-size 500G
amber config --max-size unlimited
```

- `--max-versions` is how many previous versions of each file are kept, on top
  of its latest version. A delete counts as a version.
- `--max-size` (like `500G`, `1.5T` or `200M`, in powers of 1024) is the most
  space the objects in the destination can use.

Both default to unlimited and can be changed at any time. `backup` prunes
before and after it runs: first old versions beyond `--max-versions`, then the
oldest previous versions until the objects fit `--max-size`. The latest version
of a file is never pruned. Version numbers are never reused.

If a new object wouldn't fit (or the disk fills up), `backup` stops with an
error. Every file backed up before that is kept, and nothing of the file that
didn't fit is left behind, so after raising the limit (or freeing space)
`backup` carries on from there.

### Back up

```sh
amber backup
```

```
new      /Users/me/Documents/notes.txt
changed  /Users/me/Documents/todo.txt
deleted  /Users/me/Documents/old.txt
1 new, 1 changed, 1 deleted, 120 unchanged
```

A file whose size and modified time match its latest version is skipped.
Otherwise it's hashed (SHA-256) and stored once in the destination at
`AB/CD/SHA256`, where `AB` and `CD` are the first four characters of the hash.
Files with the same content share one object.

Objects smaller than a file system block, already compressed formats (MP3, MP4,
JPEG, ZIP, RAR, ...) and files over 1 GiB are stored as is. Everything else is
stored as a ZIP archive (if that's smaller), so `unzip -p` can recover it
without amber.

Every change to a path, including a delete, is a new version numbered from 1.
Old versions are never removed.

### List

```sh
amber ls ~/Documents
amber ls -t "2026-11-01 09:00" ~/Documents ~/Projects
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
amber restore ~/Documents /tmp/documents
amber restore -t 2026-11-01 ~/Documents/notes.txt /tmp/old-notes
```

Copies a folder (or a file) as it was at `-t` into a new folder, which must not
already exist. Files are unzipped, checked against their SHA-256 and get back
their modified times.

### Stats

```sh
amber stats
```

## Index

| Table | |
|---|---|
| `config` | The destination folder, `max_versions` and `max_size` (NULL for unlimited). |
| `patterns` | Include and exclude globs. |
| `objects` | One row per stored object: SHA-256, original and stored size, compression (`NONE` or `ZIP`). |
| `files` | One row per version of a path: version number, size, modified time (microseconds), SHA-256, whether it was deleted, and when it was backed up. |

## Building

```sh
v install elliotchance.vsql
v -o amber .
v test .
```
