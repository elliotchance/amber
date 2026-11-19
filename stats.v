module main

import os
import elliotchance.vsql.vsql

// stats describes the backup as of now (microseconds since the UNIX epoch).
fn stats(b Backup, now i64) ![]string {
	dir := b.dir
	mut db := open_database(b)!
	defer {
		db.close()
	}

	config := read_config(mut db, dir)!
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

	totals := index_totals(mut db) or { return at(.read_index, err) }
	versions, runs, objects, original, stored, zipped := totals.versions, totals.runs, totals.objects, totals.original, totals.stored, totals.zipped
	first := if runs > 0 { format_local(totals.first) } else { '' }
	last := if runs > 0 { format_local(totals.last) } else { '' }

	mut lines := []string{}
	lines << config_lines(config)
	lines << 'Index size:     ${human_size(i64(os.file_size(b.index)))}'
	lines << ''
	lines << 'Backups kept:   ${runs}'
	if runs > 0 {
		lines << 'First backup:   ${first}'
		lines << 'Last backup:    ${last}'
	}
	lines << 'Files:          ${current_files} (${human_size(current_size)})'
	lines << 'Deleted files:  ${deleted_paths}'
	lines << 'Versions:       ${versions}'
	lines << ''
	// The average is of what was actually stored, before compression. Small
	// files are one chunk each, so it's often much smaller than avg_chunk.
	average := if objects == 0 { '' } else { ', ${human_size(original / objects)} average' }
	lines << 'Chunks:         ${objects} (${zipped} zipped${average})'
	lines << 'Original size:  ${human_size(original)}'
	mut stored_line := 'Stored size:    ${human_size(stored)}'
	if original > 0 {
		stored_line += ' (${f64(stored) * 100 / f64(original):.1f}% of original)'
	}
	lines << stored_line
	if config.max_size != unlimited {
		lines << 'Space left:     ${human_size(config.max_size - stored)}'
	}
	return lines
}

fn format_local(us i64) string {
	return us_to_time(us).local().format_ss()
}

const kb = i64(1000)
const mb = 1000 * kb
const gb = 1000 * mb
const tb = 1000 * gb

// human_size is a size in base 10 units (1 KB is 1000 bytes), like disk sizes.
fn human_size(n i64) string {
	units := ['B', 'KB', 'MB', 'GB', 'TB']
	mut size := f64(n)
	mut unit := 0
	for size >= 1000 && unit < units.len - 1 {
		size /= 1000
		unit++
	}
	return if unit == 0 { '${n} B' } else { '${size:.1f} ${units[unit]}' }
}

struct IndexTotals {
mut:
	versions i64
	runs     i64
	first    i64
	last     i64
	objects  i64
	original i64
	stored   i64
	zipped   i64
}

fn index_totals(mut db vsql.Connection) !IndexTotals {
	mut t := IndexTotals{}
	for row in db.query('SELECT COUNT(*) AS versions, COUNT(DISTINCT backed_up) AS runs,
		MIN(backed_up) AS first, MAX(backed_up) AS last FROM files')! {
		t.versions = row.get('VERSIONS')!.int_value()
		t.runs = row.get('RUNS')!.int_value()
		if t.versions > 0 {
			t.first = time_to_us(row.get('FIRST')!.time_value().t)
			t.last = time_to_us(row.get('LAST')!.time_value().t)
		}
	}
	for row in db.query("SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS original,
		COALESCE(SUM(stored_size), 0) AS stored,
		COALESCE(SUM(CASE WHEN compression = 'ZIP' THEN 1 ELSE 0 END), 0) AS zipped
		FROM objects")! {
		t.objects = row.get('N')!.int_value()
		t.original = row.get('ORIGINAL')!.int_value()
		t.stored = row.get('STORED')!.int_value()
		t.zipped = row.get('ZIPPED')!.int_value()
	}
	return t
}
