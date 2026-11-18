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
(`--exclude "/Users/me/Projects/*/build"`). `init` also takes every option of
`amber config` (see below).

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
Otherwise it's read once and split into chunks with content-defined chunking
(FastCDC): chunks average 4 MiB and are between 1 MiB and 16 MiB. Cut points
depend on the content, not the offset, so an edit only changes the chunks
around it, even if it inserts or removes bytes. Editing an MP3's tags, for
example, usually stores one new chunk instead of the whole file.

Each chunk is stored once in the backup folder at `AB/CD/SHA256`, where `AB`
and `CD` are the first four characters of its hash, and is shared by every file
and version that contains it. A file smaller than 1 MiB is a single chunk.
Touching a file without changing it adds a version but stores nothing new.

Chunks of files that match a no-compress pattern (see below) and chunks smaller
than a block are stored as is. Everything else is compressed in memory with
zlib and kept only if it's smaller. A compressed
chunk is a standard ZIP file, so `unzip -p` can read one without amber, and the
order of a file's chunks is in the `parts` table.

Every change to a path, including a delete, is a new version numbered from 1.
Symbolic links are skipped.

### Settings

```sh
amber config -d /Volumes/Backup/amber        # show every setting
amber config -d /Volumes/Backup/amber --max-versions 10 --min-versions 2 --max-size 500G
amber config -d /Volumes/Backup/amber --keep-deleted 90
amber config -d /Volumes/Backup/amber --no-compress "*.log" --no-compress "/Users/me/Videos/*"
amber config -d /Volumes/Backup/amber --compress "*.zip"
```

| Option | Default | |
|---|---|---|
| `--max-versions n` | unlimited | The most previous versions of each file that are kept, on top of its latest version. A delete counts as a version. |
| `--max-size size` | unlimited | The most space the stored chunks can use, like `500G`, `1.5T` or `200M` (powers of 1024). |
| `--min-versions n` | unlimited | To stay under `--max-size`, the oldest previous versions can be removed, but each file keeps at least this many. With the default nothing is removed, and `backup` stops when it's full. |
| `--keep-deleted days` | forever | How long a deleted file is kept. After that, every version of it is removed. |
| `--no-compress pattern` | already compressed formats | Adds a pattern of files that are stored as is, matched like excludes but ignoring case. `--compress pattern` removes one. Changes only affect chunks stored from then on. |

Version numbers are never reused, and the latest version of a file that still
exists is never removed.

If a new chunk wouldn't fit `--max-size` (or the disk fills up), `backup`
stops. Every file backed up before that is kept, and nothing of the file that
didn't fit is left behind, so after raising the limit (or freeing space)
`backup` carries on from there.

### Clean up

```sh
amber cleanup -d /Volumes/Backup/amber
```

Removes the versions and chunks the settings no longer allow. `backup` does
the same before it starts (and again at the end).

### Check

```sh
amber fsck -d /Volumes/Backup/amber
amber fsck -d /Volumes/Backup/amber --hash
```

Checks that the index and the backup folder agree: every chunk in the index is
on disk with the right size, every file in the folder's chunk layout is in the
index (including temporary files left by an interrupted backup), and every
version has all of its chunks. `--hash` also reads, decompresses and hashes
every chunk to check its contents, which reads the whole backup.

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
to its name in the current folder, and must not exist yet. Files are checked
against their SHA-256 and get back their modified times.

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
| 9 | The index was made by a newer amber |
| 10 | Read source: a file couldn't be read or hashed. `backup` still backs up everything else first. |
| 11 | Compress (`zip`) |
| 12 | Write object |
| 13 | No space: `--max-size` reached |
| 20 | Not found: the path isn't in the backup at that time |
| 21 | The restore target already exists |
| 22 | Missing object: the index points to an object that isn't there |
| 23 | Decompress (`unzip`) |
| 24 | Checksum: a restored file doesn't match its SHA-256 |
| 25 | Write target: writing a restored file or its modified time |
| 26 | Deleted: the path was deleted at that time |
| 30 | `fsck` found problems |

## Index

| Table | |
|---|---|
| `config` | The index `version`, and the settings (NULL for unlimited or forever). |
| `no_compress` | Patterns of files whose chunks are stored as is. |
| `patterns` | Include and exclude globs. |
| `objects` | One row per stored chunk: SHA-256, original and stored size, compression (`NONE` or `ZIP`). |
| `parts` | The chunks of each file made of more than one chunk, in order, under a manifest (the SHA-256 of its chunks' hashes). |
| `files` | One row per version of a path: version number, size, modified time (microseconds), SHA-256 of the whole file, manifest (none for a file that's one chunk, whose SHA-256 is its object), whether it was deleted, and when it was backed up. |

Each index records the version of its schema. When a newer amber opens an
older index it upgrades it step by step, each step in one transaction, and an
older amber refuses an index made by a newer one (exit 9).

## Building

Needs zlib (`libz`), which macOS has. On Linux install its headers (for
example `zlib1g-dev`).

```sh
v install elliotchance.vsql
v -o amber .
v test .
```
