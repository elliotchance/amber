module main

import os
import elliotchance.vsql.vsql

struct PruneStats {
mut:
	versions int // rows removed from files
	objects  int // objects removed from the destination
	bytes    i64 // stored bytes freed
}

struct PruneRow {
	id      i64
	path    string
	version int
	sha256  string // empty for a deleted version
}

// prune enforces config.max_versions and config.max_size:
//
// 1. Each path keeps its latest version and up to max_versions previous ones.
// 2. If the objects still use more than max_size, previous versions are removed
//    oldest first until they fit. The latest version of a path is never
//    removed, so this can't always get under the limit.
//
// An object is removed when no version uses it anymore. Rows are deleted and
// committed before the object files are removed, so a crash can leave an
// unused file behind, but never a version without its object.
fn prune(mut db vsql.Connection, config Config, log fn (string)) !PruneStats {
	if config.max_versions == unlimited && config.max_size == unlimited {
		return PruneStats{}
	}

	mut by_path := map[string][]PruneRow{}
	mut refs := map[string]int{}
	for row in db.query('SELECT id, path, version, sha256 FROM files ORDER BY id')! {
		r := PruneRow{
			id:      row.get('ID')!.int_value()
			path:    row.get_string('PATH')!
			version: row.get_int('VERSION')!
			sha256:  if row.get_null('SHA256')! { '' } else { row.get_string('SHA256')! }
		}
		by_path[r.path] << r
		if r.sha256 != '' {
			refs[r.sha256]++
		}
	}
	mut stored_sizes := map[string]i64{}
	mut total := i64(0)
	for row in db.query('SELECT sha256, stored_size FROM objects')! {
		size := row.get('STORED_SIZE')!.int_value()
		stored_sizes[row.get_string('SHA256')!] = size
		total += size
	}

	mut p := Pruner{
		refs:         refs
		stored_sizes: stored_sizes
		total:        total
	}

	// Rows are in id order, so the last one of each path is its latest.
	mut previous := []PruneRow{}
	for _, rows in by_path {
		older := rows[..rows.len - 1]
		mut keep_from := 0
		if config.max_versions != unlimited && older.len > config.max_versions {
			keep_from = older.len - int(config.max_versions)
			for r in older[..keep_from] {
				p.drop(r)
			}
		}
		previous << older[keep_from..]
	}

	if config.max_size != unlimited && p.total > config.max_size {
		previous.sort(a.id < b.id)
		for r in previous {
			if p.total <= config.max_size {
				break
			}
			p.drop(r)
		}
	}

	remove := p.remove
	freed := p.freed
	if remove.len == 0 {
		return PruneStats{}
	}

	mut result := PruneStats{
		versions: remove.len
		objects:  freed.len
	}
	db.query('START TRANSACTION')!
	mut delete_file := db.prepare('DELETE FROM files WHERE id = ?')!
	for r in remove {
		delete_file.query({
			'?1': vsql.new_bigint_value(r.id)
		})!
	}
	mut delete_object := db.prepare('DELETE FROM objects WHERE sha256 = ?')!
	for sha in freed {
		delete_object.query({
			'?1': vsql.new_varchar_value(sha)
		})!
		result.bytes += stored_sizes[sha]
	}
	db.query('COMMIT')!

	for sha in freed {
		path := object_path(config.destination, sha)
		os.rm(path) or {}
		// Remove the AB/CD folders when they're empty. os.rmdir fails if not.
		os.rmdir(os.dir(path)) or {}
		os.rmdir(os.dir(os.dir(path))) or {}
	}
	if result.versions > 0 {
		log('pruned   ${result.versions} old versions, ${result.objects} objects, ${human_size(result.bytes)}')
	}
	return result
}

// Pruner tracks which versions are being removed and which objects that
// frees.
struct Pruner {
mut:
	refs         map[string]int // versions using each object
	stored_sizes map[string]i64
	total        i64 // stored bytes still in use
	remove       []PruneRow
	freed        []string
}

fn (mut p Pruner) drop(r PruneRow) {
	p.remove << r
	if r.sha256 != '' {
		p.refs[r.sha256]--
		if p.refs[r.sha256] == 0 {
			p.freed << r.sha256
			p.total -= p.stored_sizes[r.sha256]
		}
	}
}
