module main

import os
import flag
import time

const usage = 'usage:
  amber init -d folder [--root folder] [--include pattern ...] [--exclude pattern ...]
             [--max-versions n] [--min-versions n] [--max-size size] [--keep-deleted days]
             [--no-compress pattern ...] [--compress pattern ...]
      Create a new backup folder, which must not exist yet. --root is the folder
      to back up (default the current folder). Every path in the backup is
      relative to it.
      --include and --exclude can be repeated. With no includes, everything in
      the root is backed up. A file is backed up if it (or a folder it is in)
      matches an include, and neither it nor any folder it is in matches an
      exclude. A pattern that starts with "/" is anchored to the root ("/foo"
      is only foo in the root), any other pattern matches at any depth ("foo"
      is every file or folder named foo). "*" does not match "/", "**" does.

  amber config [-d folder] [--root folder] [--include pattern ...] [--remove-include pattern ...]
               [--exclude pattern ...] [--remove-exclude pattern ...] [--max-versions n] [--min-versions n] [--max-size size]
               [--keep-deleted days] [--no-compress pattern ...] [--compress pattern ...]
      Show the settings, or change them. Limits default to "unlimited".
      --root changes the folder that is backed up, for when the files have
      moved. Nothing else changes.
      --include and --exclude add to the patterns, --remove-include and
      --remove-exclude remove from them. Backed up files that are no longer
      included are kept as they are (not recorded as deleted); cleanup
      --excluded removes them.
      --max-versions is the most previous versions of each file that are kept.
      --max-size (like 500G) is the most space the stored files can use. To
      stay under it, the oldest previous versions can be removed, but each file
      keeps at least --min-versions of them, so with the default nothing is
      removed and backup stops when it is full.
      --keep-deleted is how many days a deleted file is kept before every
      version of it is removed from the backup (default "forever").
      --no-compress adds a pattern of files that are stored as is, and
      --compress removes one. They are matched like excludes, ignoring case, and
      start as a list of already compressed formats (like "*.mp3"). Changes
      only affect chunks stored from then on.

  amber backup [-d folder]
      Back up every included file that is new or has changed. It runs cleanup
      first.

  amber cleanup [-d folder] [--excluded]
      With --excluded, also remove every version of the files that are no
      longer included (or are now excluded).
      Remove the versions and chunks that the limits no longer allow (old
      versions past --max-versions, files deleted longer ago than
      --keep-deleted, and old versions to fit --max-size).

  amber fsck [-d folder] [--hash]
      Check that the index and the stored chunks agree: every chunk in the
      index is on disk with the right size, every file on disk is in the index,
      and every version has all of its chunks. --hash also reads and hashes
      every chunk to check its contents, which reads the whole backup.

  amber ls [-d folder] [-t time] [path ...]
      List files and folders as they were at time (default now). time is
      YYYY-MM-DD [HH:MM[:SS]] in local time; a date alone is the end of that day.
      Paths are relative to the root, which is listed when there are none.

  amber restore [-d folder] [-t time] path [target]
      Restore path (a file or folder, relative to the root, "." for all of it)
      as it was at time (default now) to target,
      which must not exist yet. target defaults to the name of path in the
      current folder. If path was deleted at that time, the error shows the
      command to restore it from when it last existed.

  amber stats [-d folder]
      Show what is backed up and how much space it uses.

  amber version
      Show the version of amber and the date it was released.

-d is the backup folder, which defaults to the current folder. -f is the index,
which defaults to db.vsql in the backup folder. It can be kept somewhere else
(like off a network volume) and moved, as long as -f is given every time.

exit codes (the stage that failed):
  0  success                 10  read source file        20  not found in backup
  1  unknown (a bug)         11  compress (zip)          21  restore target exists
  2  usage                   12  write object            22  missing object
  3  index missing           13  no space (max size)     23  decompress (unzip)
  4  index exists                                        24  checksum mismatch
  5  create index                                        25  write restored file
                                                         26  deleted at that time
                                                         30  fsck found problems
  6  open index
  7  read index
  8  write index
  9  index made by a newer amber'

fn main() {
	if os.args.len < 2 {
		exit_with_usage()
	}
	args := os.args[2..]
	match os.args[1] {
		'init' { cmd_init(args) or { fail(err) } }
		'backup' { cmd_backup(args) or { fail(err) } }
		'cleanup' { cmd_cleanup(args) or { fail(err) } }
		'config' { cmd_config(args) or { fail(err) } }
		'fsck' { cmd_fsck(args) or { fail(err) } }
		'ls' { cmd_ls(args) or { fail(err) } }
		'restore' { cmd_restore(args) or { fail(err) } }
		'stats' { cmd_stats(args) or { fail(err) } }
		'version' { println(version_line()) }
		else { exit_with_usage() }
	}
}

fn cmd_init(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '', '')
	file := fp.string('file', `f`, '', '')
	root_arg := fp.string('root', 0, '.', '')
	includes := fp.string_multi('include', 0, '')
	excludes := fp.string_multi('exclude', 0, '')
	max_versions := parse_max_versions(fp.string('max-versions', 0, 'unlimited', ''))!
	min_versions := parse_min_versions(fp.string('min-versions', 0, 'unlimited', ''))!
	max_size := parse_max_size(fp.string('max-size', 0, 'unlimited', ''))!
	keep_deleted := parse_keep_deleted(fp.string('keep-deleted', 0, 'forever', ''))!
	add_no_compress := fp.string_multi('no-compress', 0, '')
	remove_no_compress := fp.string_multi('compress', 0, '')
	fp.finalize() or { return at(.usage, err) }
	b := new_backup(dir, file)

	if dir == '' {
		return stage_error(.usage, '-d is required')
	}
	if os.exists(dir) {
		return stage_error(.index_exists, '${dir} already exists')
	}
	check_versions(min_versions, max_versions)!
	root := check_root(root_arg)!
	check_patterns(includes, excludes)!

	now := time_to_us(time.utc())
	create_database(b, Config{
		root:         root
		created:      now
		includes:     includes
		excludes:     excludes
		max_versions: max_versions
		min_versions: min_versions
		max_size:     max_size
		keep_deleted: keep_deleted
		no_compress:  no_compress_list(default_no_compress, add_no_compress, remove_no_compress)!
	})!
	update_readme(b, now)
	println('created ${dir}')
}

fn cmd_config(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	file := fp.string('file', `f`, '', '')
	root_arg := fp.string('root', 0, '', '')
	versions_arg := fp.string('max-versions', 0, '', '')
	size_arg := fp.string('max-size', 0, '', '')
	keep_arg := fp.string('keep-deleted', 0, '', '')
	add_includes := fp.string_multi('include', 0, '')
	remove_includes := fp.string_multi('remove-include', 0, '')
	add_excludes := fp.string_multi('exclude', 0, '')
	remove_excludes := fp.string_multi('remove-exclude', 0, '')
	min_arg := fp.string('min-versions', 0, '', '')
	add_no_compress := fp.string_multi('no-compress', 0, '')
	remove_no_compress := fp.string_multi('compress', 0, '')
	fp.finalize() or { return at(.usage, err) }
	b := new_backup(dir, file)

	// Check every value before changing any of them.
	if versions_arg != '' || min_arg != '' {
		mut db := open_database(b)!
		current := read_config(mut db, dir)!
		db.close()
		check_versions(if min_arg == '' {
			current.min_versions
		} else {
			parse_min_versions(min_arg)!
		},
			if versions_arg == '' {
				current.max_versions
			} else {
				parse_max_versions(versions_arg)!
			})!
	}
	if size_arg != '' {
		parse_max_size(size_arg)!
	}
	if keep_arg != '' {
		parse_keep_deleted(keep_arg)!
	}
	root := if root_arg == '' { '' } else { check_root(root_arg)! }
	check_patterns(add_includes, add_excludes)!

	if root != '' {
		set_root(b, root)!
	}
	if versions_arg != '' || size_arg != '' {
		max_versions := if versions_arg == '' {
			?i64(none)
		} else {
			parse_max_versions(versions_arg)!
		}
		max_size := if size_arg == '' { ?i64(none) } else { parse_max_size(size_arg)! }
		set_limits(b, max_versions, max_size)!
	}
	if add_includes.len + remove_includes.len + add_excludes.len + remove_excludes.len > 0 {
		change_patterns(b, PatternChanges{
			add_includes:    add_includes
			add_excludes:    add_excludes
			remove_includes: remove_includes
			remove_excludes: remove_excludes
		})!
	}
	if add_no_compress.len > 0 || remove_no_compress.len > 0 {
		change_no_compress(b, add_no_compress, remove_no_compress)!
	}
	if min_arg != '' {
		set_min_versions(b, parse_min_versions(min_arg)!)!
	}
	if keep_arg != '' {
		set_keep_deleted(b, parse_keep_deleted(keep_arg)!)!
	}

	mut db := open_database(b)!
	defer {
		db.close()
	}
	if args.any(it.starts_with('--') && it !in ['--dir', '--file']) {
		update_readme(b, time_to_us(time.utc()))
	}
	for line in config_lines(read_config(mut db, dir)!) {
		println(line)
	}
}

fn config_lines(config Config) []string {
	mut lines := []string{}
	lines << 'Backup folder:  ${config.dir}'
	lines << 'Root:           ${config.root}'
	if config.includes.len == 0 {
		lines << 'Include:        everything'
	}
	for include in config.includes {
		lines << 'Include:        ${include}'
	}
	for exclude in config.excludes {
		lines << 'Exclude:        ${exclude}'
	}
	lines << 'Max versions:   ${format_max_versions(config.max_versions)}'
	lines << 'Min versions:   ${format_max_versions(config.min_versions)}'
	lines << 'Max size:       ${format_max_size(config.max_size)}'
	lines << 'Keep deleted:   ${format_keep_deleted(config.keep_deleted)}'
	lines << wrap_list('No compress:    ', config.no_compress, 80)
	return lines
}

fn cmd_backup(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	file := fp.string('file', `f`, '', '')
	fp.finalize() or { return at(.usage, err) }
	b := new_backup(dir, file)

	now := time_to_us(time.utc())
	result := backup(b, now, fn (line string) {
		println(line)
	})!
	update_readme(b, now)
	mut summary := '${result.new} new, ${result.changed} changed, ${result.deleted} deleted, ${result.unchanged} unchanged'
	if result.skipped > 0 {
		summary += ', ${result.skipped} skipped'
	}
	if result.pruned > 0 {
		summary += ', ${result.pruned} old versions pruned'
	}
	if result.excluded > 0 {
		summary += ', ${result.excluded} no longer included (kept)'
	}
	println(summary)
	if result.skipped > 0 {
		return stage_error(.read_source, '${result.skipped} files could not be read')
	}
}

fn cmd_cleanup(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	file := fp.string('file', `f`, '', '')
	excluded := fp.bool('excluded', 0, false, '')
	fp.finalize() or { return at(.usage, err) }
	b := new_backup(dir, file)

	now := time_to_us(time.utc())
	result := cleanup(b, now, excluded, fn (line string) {
		println(line)
	})!
	update_readme(b, now)
	if result.versions == 0 {
		println('nothing to clean up')
	}
}

fn cmd_fsck(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	file := fp.string('file', `f`, '', '')
	hash := fp.bool('hash', 0, false, '')
	fp.finalize() or { return at(.usage, err) }
	b := new_backup(dir, file)

	result := fsck(b, hash, fn (line string) {
		println(line)
	})!
	for problem in result.problems {
		println(problem)
	}
	println('checked ${result.versions} versions and ${result.objects} chunks${if hash {
		' (hashed)'
	} else {
		''
	}}: ${result.problems.len} problems')
	if result.problems.len > 0 {
		return stage_error(.fsck, '${result.problems.len} problems found')
	}
}

fn cmd_ls(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	file := fp.string('file', `f`, '', '')
	time_arg := fp.string('time', `t`, '', '')
	mut paths := fp.finalize() or { return at(.usage, err) }
	b := new_backup(dir, file)
	if paths.len == 0 {
		paths = ['.']
	}

	as_of := if time_arg == '' { time_to_us(time.utc()) } else { parse_local_time(time_arg)! }
	for line in ls(b, paths, as_of)! {
		println(line)
	}
}

fn cmd_restore(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	file := fp.string('file', `f`, '', '')
	time_arg := fp.string('time', `t`, '', '')
	paths := fp.finalize() or { return at(.usage, err) }
	b := new_backup(dir, file)
	if paths.len < 1 || paths.len > 2 {
		return stage_error(.usage, 'restore needs a path and an optional target')
	}

	as_of := if time_arg == '' { time_to_us(time.utc()) } else { parse_local_time(time_arg)! }
	n := restore(b, paths[0], if paths.len == 2 { paths[1] } else { '' }, as_of, fn (line string) {
		println(line)
	})!
	println('${n} restored')
}

fn cmd_stats(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	file := fp.string('file', `f`, '', '')
	fp.finalize() or { return at(.usage, err) }
	b := new_backup(dir, file)

	for line in stats(b, time_to_us(time.utc()))! {
		println(line)
	}
}

fn fail(err IError) {
	eprintln('amber: ${err.msg()}')
	exit(exit_code(err))
}

fn exit_with_usage() {
	eprintln(usage)
	exit(int(Stage.usage))
}

// no_compress_list is patterns with add added and remove removed. Removing a
// pattern that isn't there is an error.
fn no_compress_list(patterns []string, add []string, remove []string) ![]string {
	mut result := patterns.clone()
	for pattern in add {
		if pattern !in result {
			result << pattern
		}
	}
	for pattern in remove {
		if pattern !in result {
			return stage_error(.usage, 'no compress pattern "${pattern}" is not in the list')
		}
		result = result.filter(it != pattern)
	}
	return result
}

// wrap_list joins items after label, wrapping lines at width and indenting
// them to line up after the label.
fn wrap_list(label string, items []string, width int) string {
	if items.len == 0 {
		return label + '(none)'
	}
	indent := ' '.repeat(label.len)
	mut lines := []string{}
	mut line := label
	for item in items {
		if line.len > label.len && line.len + 1 + item.len > width {
			lines << line
			line = indent
		}
		if line.len > label.len {
			line += ' '
		}
		line += item
	}
	lines << line
	return lines.join('\n')
}

// check_root is the absolute path of a root, which must be an existing folder.
fn check_root(path string) !string {
	if !os.is_dir(path) {
		return stage_error(.usage, 'root ${path} is not a folder')
	}
	return os.real_path(path)
}

fn check_patterns(includes []string, excludes []string) ! {
	for pattern in includes {
		check_pattern('include', pattern)!
	}
	for pattern in excludes {
		check_pattern('exclude', pattern)!
	}
}
