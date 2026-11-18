module main

import os

// stats describes the backup as of now (microseconds since the UNIX epoch).
fn stats(db_path string, now i64) ![]string {
	mut db := open_database(db_path)!
	defer {
		db.close()
	}

	config := read_config(mut db)!
	latest := latest_versions(mut db, '', now)!
	mut current_files := 0
	mut current_size := i64(0)
	mut deleted_paths := 0
	for _, v in latest {
		if v.deleted {
			deleted_paths++
		} else {
			current_files++
			current_size += v.size
		}
	}

	mut versions := i64(0)
	mut runs := i64(0)
	mut first := ''
	mut last := ''
	for row in db.query('SELECT COUNT(*) AS versions, COUNT(DISTINCT backed_up) AS runs,
		MIN(backed_up) AS first, MAX(backed_up) AS last FROM files')! {
		versions = row.get('VERSIONS')!.int_value()
		runs = row.get('RUNS')!.int_value()
		if versions > 0 {
			first = format_local(time_to_us(row.get('FIRST')!.time_value().t))
			last = format_local(time_to_us(row.get('LAST')!.time_value().t))
		}
	}

	mut objects := i64(0)
	mut original := i64(0)
	mut stored := i64(0)
	mut zipped := i64(0)
	for row in db.query("SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS original,
		COALESCE(SUM(stored_size), 0) AS stored,
		COALESCE(SUM(CASE WHEN compression = 'ZIP' THEN 1 ELSE 0 END), 0) AS zipped
		FROM objects")! {
		objects = row.get('N')!.int_value()
		original = row.get('ORIGINAL')!.int_value()
		stored = row.get('STORED')!.int_value()
		zipped = row.get('ZIPPED')!.int_value()
	}

	mut lines := []string{}
	lines << 'Database:       ${os.real_path(db_path)} (${human_size(i64(os.file_size(db_path)))})'
	lines << 'Destination:    ${config.destination}'
	for include in config.includes {
		lines << 'Include:        ${include}'
	}
	for exclude in config.excludes {
		lines << 'Exclude:        ${exclude}'
	}
	lines << ''
	lines << 'Backups:        ${runs}'
	if runs > 0 {
		lines << 'First backup:   ${first}'
		lines << 'Last backup:    ${last}'
	}
	lines << 'Files:          ${current_files} (${human_size(current_size)})'
	lines << 'Deleted files:  ${deleted_paths}'
	lines << 'Versions:       ${versions}'
	lines << ''
	lines << 'Objects:        ${objects} (${zipped} zipped)'
	lines << 'Original size:  ${human_size(original)}'
	mut stored_line := 'Stored size:    ${human_size(stored)}'
	if original > 0 {
		stored_line += ' (${f64(stored) * 100 / f64(original):.1f}% of original)'
	}
	lines << stored_line
	return lines
}

fn format_local(us i64) string {
	return us_to_time(us).local().format_ss()
}

fn human_size(n i64) string {
	units := ['B', 'KiB', 'MiB', 'GiB', 'TiB']
	mut size := f64(n)
	mut unit := 0
	for size >= 1024 && unit < units.len - 1 {
		size /= 1024
		unit++
	}
	return if unit == 0 { '${n} B' } else { '${size:.1f} ${units[unit]}' }
}
