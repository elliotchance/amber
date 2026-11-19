module main

import os

// The backup folder has a README.md that says what it is and how to use it,
// which is rewritten whenever the backup changes. amber never reads it.

// update_readme rewrites the README.md in the backup folder. It's only a
// convenience, so a failure is a warning rather than an error.
fn update_readme(b Backup, now i64) {
	text := readme_text(b, now) or {
		eprintln('amber: warning: README.md not updated: ${err.msg()}')
		return
	}
	os.write_file(os.join_path(b.dir, 'README.md'), text) or {
		eprintln('amber: warning: README.md not updated: ${err.msg()}')
	}
}

fn readme_text(b Backup, now i64) !string {
	mut db := open_database(b)!
	defer {
		db.close()
	}
	config := read_config(mut db, b.dir)!
	totals := index_totals(mut db) or { return at(.read_index, err) }
	return readme_markdown(b, config, totals.last, now)
}

// readme_markdown is the README.md of a backup. last_backup is 0 if nothing
// has been backed up yet.
fn readme_markdown(b Backup, config Config, last_backup i64, now i64) string {
	dir := os.real_path(b.dir)
	mut base := ['-d', shell_quote(dir)]
	if b.index != db_file(b.dir) {
		base << ['-f', shell_quote(os.real_path(b.index))]
	}
	d := base.join(' ')

	mut init := ['amber init ${d}', '--root ${shell_quote(config.root)}']
	for include in config.includes {
		init << '--include ${shell_quote(include)}'
	}
	for exclude in config.excludes {
		init << '--exclude ${shell_quote(exclude)}'
	}
	if config.max_versions != unlimited {
		init << '--max-versions ${config.max_versions}'
	}
	if config.min_versions != unlimited {
		init << '--min-versions ${config.min_versions}'
	}
	if config.max_size != unlimited {
		init << '--max-size ${format_max_size(config.max_size)}'
	}
	if config.keep_deleted != unlimited {
		init << '--keep-deleted ${config.keep_deleted}'
	}
	for pattern in config.no_compress {
		if pattern !in default_no_compress {
			init << '--no-compress ${shell_quote(pattern)}'
		}
	}
	for pattern in default_no_compress {
		if pattern !in config.no_compress {
			init << '--compress ${shell_quote(pattern)}'
		}
	}

	mut lines := []string{}
	lines << '# amber backup'
	lines << ''
	lines << 'This folder is a backup made by [amber](https://github.com/elliotchance/amber),'
	lines << 'which keeps every version of every file. Use amber to look at or restore it,'
	lines << 'and never change the files in here by hand.'
	lines << ''
	lines << '| | |'
	lines << '|---|---|'
	lines << '| Root | `${config.root}` |'
	if b.index != db_file(b.dir) {
		lines << '| Index | `${os.real_path(b.index)}` |'
	}
	lines << '| Created | ${format_local(config.created)} |'
	lines << '| Last backup | ${if last_backup == 0 { 'never' } else { format_local(last_backup) }} |'
	lines << '| Updated | ${format_local(now)} |'
	lines << ''
	lines << '## Set up'
	lines << ''
	lines << 'The command that sets up a backup with the same settings:'
	lines << ''
	lines << '```sh'
	lines << init.join(' \\\n  ')
	lines << '```'
	lines << ''
	lines << '## Back up'
	lines << ''
	lines << '```sh'
	lines << 'amber backup ${d}'
	lines << '```'
	lines << ''
	lines << '## Look and restore'
	lines << ''
	lines << 'Paths are relative to the root. `-t` is a local time (`YYYY-MM-DD [HH:MM[:SS]]`)'
	lines << 'and defaults to now.'
	lines << ''
	lines << '```sh'
	lines << 'amber ls ${d} [-t time] [path]'
	lines << 'amber restore ${d} [-t time] path [target]'
	lines << 'amber stats ${d}'
	lines << '```'
	lines << ''
	return lines.join('\n')
}
