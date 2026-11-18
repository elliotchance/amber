module main

import os
import flag
import time

const default_db_path = 'amber.vsql'

const usage = 'usage:
  amber init [-f file.vsql] --destination folder --include path ... [--exclude pattern ...]
             [--max-versions n] [--max-size size]
      Create a new backup file. --include and --exclude can be repeated.
      Includes are applied before excludes. An exclude without a "/" matches
      file and folder names (like "*.tmp"), otherwise it matches full paths.

  amber config [-f file.vsql] [--max-versions n] [--max-size size]
      Show the settings, or change the limits. --max-versions is how many
      previous versions of each file are kept. --max-size (like 500G) is the
      most space the destination can use. Both default to "unlimited", and the
      next backup removes the oldest versions that no longer fit.

  amber backup [-f file.vsql]
      Back up every included file that is new or has changed.

  amber ls [-f file.vsql] [-t time] path ...
      List files and folders as they were at time (default now). time is
      YYYY-MM-DD [HH:MM[:SS]] in local time; a date alone is the end of that day.

  amber restore [-f file.vsql] [-t time] path target
      Restore path (a file or folder) as it was at time (default now) into the
      target folder, which must not exist yet.

  amber stats [-f file.vsql]
      Show what is backed up and how much space it uses.

-f defaults to ${default_db_path} in the current folder.'

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
	db_path := fp.string('file', `f`, default_db_path, '')
	destination := fp.string('destination', 0, '', '')
	includes := fp.string_multi('include', 0, '')
	excludes := fp.string_multi('exclude', 0, '')
	max_versions := parse_max_versions(fp.string('max-versions', 0, 'unlimited', ''))!
	max_size := parse_max_size(fp.string('max-size', 0, 'unlimited', ''))!
	fp.finalize()!

	if destination == '' {
		return error('--destination is required')
	}
	if !os.is_dir(destination) {
		return error('destination ${destination} is not a folder')
	}
	if includes.len == 0 {
		return error('at least one --include is required')
	}
	mut abs_includes := []string{}
	for include in includes {
		if !os.exists(include) {
			return error('include ${include} does not exist')
		}
		abs_includes << os.real_path(include)
	}

	create_database(db_path, Config{
		destination:  os.real_path(destination)
		includes:     abs_includes
		excludes:     excludes
		max_versions: max_versions
		max_size:     max_size
	})!
	println('created ${db_path}')
}

fn cmd_config(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	db_path := fp.string('file', `f`, default_db_path, '')
	versions_arg := fp.string('max-versions', 0, '', '')
	size_arg := fp.string('max-size', 0, '', '')
	fp.finalize()!

	if versions_arg != '' || size_arg != '' {
		max_versions := if versions_arg == '' {
			?i64(none)
		} else {
			parse_max_versions(versions_arg)!
		}
		max_size := if size_arg == '' { ?i64(none) } else { parse_max_size(size_arg)! }
		set_limits(db_path, max_versions, max_size)!
	}

	mut db := open_database(db_path)!
	defer {
		db.close()
	}
	for line in config_lines(read_config(mut db)!) {
		println(line)
	}
}

fn config_lines(config Config) []string {
	mut lines := []string{}
	lines << 'Destination:    ${config.destination}'
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
	db_path := fp.string('file', `f`, default_db_path, '')
	fp.finalize()!

	result := backup(db_path, time_to_us(time.utc()), fn (line string) {
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
}

fn cmd_ls(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	db_path := fp.string('file', `f`, default_db_path, '')
	at := fp.string('time', `t`, '', '')
	paths := fp.finalize()!
	if paths.len == 0 {
		return error('ls needs at least one path')
	}

	as_of := if at == '' { time_to_us(time.utc()) } else { parse_local_time(at)! }
	for line in ls(db_path, paths, as_of)! {
		println(line)
	}
}

fn cmd_restore(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	db_path := fp.string('file', `f`, default_db_path, '')
	at := fp.string('time', `t`, '', '')
	paths := fp.finalize()!
	if paths.len != 2 {
		return error('restore needs a path and a target folder')
	}
	if os.exists(paths[1]) {
		return error('${paths[1]} already exists')
	}

	as_of := if at == '' { time_to_us(time.utc()) } else { parse_local_time(at)! }
	n := restore(db_path, paths[0], paths[1], as_of, fn (line string) {
		println(line)
	})!
	println('${n} restored')
}

fn cmd_stats(args []string) ! {
	mut fp := flag.new_flag_parser(args)
	db_path := fp.string('file', `f`, default_db_path, '')
	fp.finalize()!

	for line in stats(db_path, time_to_us(time.utc()))! {
		println(line)
	}
}

fn fail(err IError) {
	eprintln('amber: ${err}')
	exit(1)
}

fn exit_with_usage() {
	eprintln(usage)
	exit(1)
}
