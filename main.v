module main

import os
import flag
import time

const usage = 'usage:
  amber init -d folder --include path ... [--exclude pattern ...]
             [--max-versions n] [--max-size size]
      Create a new backup folder, which must not exist yet. It holds the index
      (db.vsql) and every stored file. --include and --exclude can be repeated.
      Includes are applied before excludes. An exclude without a "/" matches
      file and folder names (like "*.tmp"), otherwise it matches full paths.

  amber config [-d folder] [--max-versions n] [--max-size size]
      Show the settings, or change the limits. --max-versions is how many
      previous versions of each file are kept. --max-size (like 500G) is the
      most space the stored files can use. Both default to "unlimited", and the
      next backup removes the oldest versions that no longer fit.

  amber backup [-d folder]
      Back up every included file that is new or has changed.

  amber ls [-d folder] [-t time] path ...
      List files and folders as they were at time (default now). time is
      YYYY-MM-DD [HH:MM[:SS]] in local time; a date alone is the end of that day.

  amber restore [-d folder] [-t time] path target
      Restore path (a file or folder) as it was at time (default now) into the
      target folder, which must not exist yet.

  amber stats [-d folder]
      Show what is backed up and how much space it uses.

-d is the backup folder, which defaults to the current folder.

exit codes (the stage that failed):
  0  success                 10  read source file        20  not found in backup
  1  unknown (a bug)         11  compress (zip)          21  restore target exists
  2  usage                   12  write object            22  missing object
  3  index missing           13  no space (max size)     23  decompress (unzip)
  4  index exists            14  zip/unzip not installed 24  checksum mismatch
  5  create index                                        25  write restored file
  6  open index
  7  read index
  8  write index'

fn main() {
	if os.args.len < 2 {
		exit_with_usage()
	}
	args := os.args[2..]
	match os.args[1] {
		'init' { cmd_init(args) or { fail(err) } }
		'backup' { cmd_backup(args) or { fail(err) } }
		'config' { cmd_config(args) or { fail(err) } }
		'ls' { cmd_ls(args) or { fail(err) } }
		'restore' { cmd_restore(args) or { fail(err) } }
		'stats' { cmd_stats(args) or { fail(err) } }
		else { exit_with_usage() }
	}
}

fn cmd_init(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '', '')
	includes := fp.string_multi('include', 0, '')
	excludes := fp.string_multi('exclude', 0, '')
	max_versions := parse_max_versions(fp.string('max-versions', 0, 'unlimited', ''))!
	max_size := parse_max_size(fp.string('max-size', 0, 'unlimited', ''))!
	fp.finalize() or { return at(.usage, err) }

	if dir == '' {
		return stage_error(.usage, '-d is required')
	}
	if os.exists(dir) {
		return stage_error(.index_exists, '${dir} already exists')
	}
	if includes.len == 0 {
		return stage_error(.usage, 'at least one --include is required')
	}
	mut abs_includes := []string{}
	for include in includes {
		if !os.exists(include) {
			return stage_error(.usage, 'include ${include} does not exist')
		}
		abs_includes << os.real_path(include)
	}

	create_database(dir, Config{
		includes:     abs_includes
		excludes:     excludes
		max_versions: max_versions
		max_size:     max_size
	})!
	println('created ${dir}')
}

fn cmd_config(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	versions_arg := fp.string('max-versions', 0, '', '')
	size_arg := fp.string('max-size', 0, '', '')
	fp.finalize() or { return at(.usage, err) }

	if versions_arg != '' || size_arg != '' {
		max_versions := if versions_arg == '' {
			?i64(none)
		} else {
			parse_max_versions(versions_arg)!
		}
		max_size := if size_arg == '' { ?i64(none) } else { parse_max_size(size_arg)! }
		set_limits(dir, max_versions, max_size)!
	}

	mut db := open_database(dir)!
	defer {
		db.close()
	}
	for line in config_lines(read_config(mut db, dir)!) {
		println(line)
	}
}

fn config_lines(config Config) []string {
	mut lines := []string{}
	lines << 'Backup folder:  ${config.dir}'
	for include in config.includes {
		lines << 'Include:        ${include}'
	}
	for exclude in config.excludes {
		lines << 'Exclude:        ${exclude}'
	}
	lines << 'Max versions:   ${format_max_versions(config.max_versions)}'
	lines << 'Max size:       ${format_max_size(config.max_size)}'
	return lines
}

fn cmd_backup(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	fp.finalize() or { return at(.usage, err) }

	result := backup(dir, time_to_us(time.utc()), fn (line string) {
		println(line)
	})!
	mut summary := '${result.new} new, ${result.changed} changed, ${result.deleted} deleted, ${result.unchanged} unchanged'
	if result.skipped > 0 {
		summary += ', ${result.skipped} skipped'
	}
	if result.pruned > 0 {
		summary += ', ${result.pruned} old versions pruned'
	}
	println(summary)
	if result.skipped > 0 {
		return stage_error(.read_source, '${result.skipped} files could not be read')
	}
}

fn cmd_ls(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	time_arg := fp.string('time', `t`, '', '')
	paths := fp.finalize() or { return at(.usage, err) }
	if paths.len == 0 {
		return stage_error(.usage, 'ls needs at least one path')
	}

	as_of := if time_arg == '' { time_to_us(time.utc()) } else { parse_local_time(time_arg)! }
	for line in ls(dir, paths, as_of)! {
		println(line)
	}
}

fn cmd_restore(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	time_arg := fp.string('time', `t`, '', '')
	paths := fp.finalize() or { return at(.usage, err) }
	if paths.len != 2 {
		return stage_error(.usage, 'restore needs a path and a target folder')
	}
	if os.exists(paths[1]) {
		return stage_error(.target_exists, '${paths[1]} already exists')
	}

	as_of := if time_arg == '' { time_to_us(time.utc()) } else { parse_local_time(time_arg)! }
	n := restore(dir, paths[0], paths[1], as_of, fn (line string) {
		println(line)
	})!
	println('${n} restored')
}

fn cmd_stats(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	dir := fp.string('dir', `d`, '.', '')
	fp.finalize() or { return at(.usage, err) }

	for line in stats(dir, time_to_us(time.utc()))! {
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
