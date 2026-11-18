module main

import os
import elliotchance.vsql.vsql

const default_db_path = 'amber.vsql'

const usage = 'usage:
  amber init [file.vsql]    create (or update) the backup file
  amber backup [file.vsql]  back up the current folder

file.vsql defaults to ${default_db_path} in the current folder.'

fn main() {
	args := os.args[1..]
	if args.len == 0 || args.len > 2 {
		exit_with_usage()
	}

	path := if args.len == 2 { args[1] } else { default_db_path }

	match args[0] {
		'init' { cmd_init(path) or { fail(err) } }
		'backup' { cmd_backup(path) or { fail(err) } }
		else { exit_with_usage() }
	}
}

// cmd_init creates the backup file, or updates it if it already exists.
fn cmd_init(path string) ! {
	exists := os.exists(path)
	mut db := vsql.open(path)!
	defer {
		db.close()
	}

	if exists {
		println('updated ${path}')
	} else {
		println('created ${path}')
	}
}

// cmd_backup backs up the current folder into an existing backup file.
fn cmd_backup(path string) ! {
	if !os.exists(path) {
		return error('${path} does not exist, run "amber init ${path}" to create it')
	}

	mut db := vsql.open(path)!
	defer {
		db.close()
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
