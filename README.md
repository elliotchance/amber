# 🍯 amber

A backup tool that keeps the full history of every file in a folder, like
Time Machine. Written in [V](https://vlang.io) and stores its history in
[vsql](https://github.com/elliotchance/vsql).

🚧 Work in progress.

## Usage

Create the backup file (or update an existing one):

```sh
amber init                  # amber.vsql in the current folder
amber init /my/file.vsql
```

Back up the current folder. The backup file must already exist:

```sh
amber backup                # amber.vsql in the current folder
amber backup /my/file.vsql
```

## Building

```sh
v install elliotchance.vsql
v -o amber .
```
