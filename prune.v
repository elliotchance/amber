module main

import os
import elliotchance.vsql.vsql

struct PruneStats {
mut:
	versions int // rows removed from files
	objects  int // objects removed from the backup folder
	bytes    i64 // stored bytes freed
}

// cleanup removes everything the limits no longer allow (the same as backup
// does before it starts), at now (microseconds since the UNIX epoch).
fn cleanup(dir string, now i64, log fn (string)) !PruneStats {
	mut db := open_database(dir)!
	defer {
		db.close()
	}
	config := read_config(mut db, dir)!
	return prune(mut db, config, now, log)!
}

struct PruneRow {
	id        i64
	path      string
	version   int
	object    string // the object of a file that's one chunk
	manifest  string // the manifest of a file that's more than one chunk
	deleted   bool
	backed_up i64
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
fn prune(mut db vsql.Connection, config Config, now i64, log fn (string)) !PruneStats {
	if config.max_versions == unlimited && config.max_size == unlimited
		&& config.keep_deleted == unlimited {
		return PruneStats{}
	}

	mut p := plan_prune(mut db, config, now) or { return at(.read_index, err) }
	if p.remove.len == 0 {
		return PruneStats{}
	}
	delete_pruned(mut db, p) or { return at(.write_index, err) }

	// Only once the rows are gone, so the index never points at a missing
	// object. Failing to remove a file only leaves an unused object behind.
	for sha in p.freed {
		path := object_path(config.dir, sha)
		os.rm(path) or {}
		remove_empty_parents(path)
	}

	result := PruneStats{
		versions: p.remove.len
		objects:  p.freed.len
		bytes:    p.freed_bytes()
	}
	log('pruned   ${result.versions} old versions, ${result.objects} objects, ${human_size(result.bytes)}')
	return result
}

// plan_prune works out which versions to remove, and which objects that frees.
fn plan_prune(mut db vsql.Connection, config Config, now i64) !Pruner {
	// refs counts what uses each object: versions of files that are one chunk,
	// and manifests (once for each time the chunk appears in it).
	mut by_path := map[string][]PruneRow{}
	mut refs := map[string]int{}
	mut manifest_refs := map[string]int{}
	for row in db.query('SELECT id, path, version, sha256, manifest, deleted, backed_up
		FROM files ORDER BY id')! {
		manifest := if row.get_null('MANIFEST')! { '' } else { row.get_string('MANIFEST')! }
		sha := if row.get_null('SHA256')! { '' } else { row.get_string('SHA256')! }
		r := PruneRow{
			id:        row.get('ID')!.int_value()
			path:      row.get_string('PATH')!
			version:   row.get_int('VERSION')!
			object:    if manifest == '' { sha } else { '' }
			manifest:  manifest
			deleted:   row.get_bool('DELETED')! == .is_true
			backed_up: time_to_us(row.get('BACKED_UP')!.time_value().t)
		}
		by_path[r.path] << r
		if r.object != '' {
			refs[r.object]++
		}
		if r.manifest != '' {
			manifest_refs[r.manifest]++
		}
	}
	mut parts := map[string][]string{}
	for row in db.query('SELECT manifest, sha256 FROM parts')! {
		manifest := row.get_string('MANIFEST')!
		sha := row.get_string('SHA256')!
		parts[manifest] << sha
		refs[sha]++
	}
	mut stored_sizes := map[string]i64{}
	mut total := i64(0)
	for row in db.query('SELECT sha256, stored_size FROM objects')! {
		size := row.get('STORED_SIZE')!.int_value()
		stored_sizes[row.get_string('SHA256')!] = size
		total += size
	}

	mut p := Pruner{
		refs:          refs
		manifest_refs: manifest_refs
		parts:         parts
		stored_sizes:  stored_sizes
		total:         total
	}

	// A path deleted more than keep_deleted days ago is removed completely.
	mut gone := map[string]bool{}
	if config.keep_deleted != unlimited {
		cutoff := now - config.keep_deleted * 86_400_000_000
		for path, rows in by_path {
			last := rows.last()
			if last.deleted && last.backed_up <= cutoff {
				for r in rows {
					p.drop(r)
				}
				gone[path] = true
			}
		}
	}

	// Rows are in id order, so the last one of each path is its latest.
	mut previous := []PruneRow{}
	for path, rows in by_path {
		if path in gone {
			continue
		}
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

	// To fit max_size, remove the oldest previous versions first, but leave
	// each path at least min_versions of them (by default, unlimited: none
	// are removed).
	if config.max_size != unlimited && config.min_versions != unlimited
		&& p.total > config.max_size {
		mut left := map[string]int{}
		for r in previous {
			left[r.path]++
		}
		previous.sort(a.id < b.id)
		for r in previous {
			if p.total <= config.max_size {
				break
			}
			if left[r.path] <= config.min_versions {
				continue
			}
			p.drop(r)
			left[r.path]--
		}
	}

	return p
}

fn delete_pruned(mut db vsql.Connection, p Pruner) ! {
	db.query('START TRANSACTION')!
	mut delete_file := db.prepare('DELETE FROM files WHERE id = ?')!
	for r in p.remove {
		delete_file.query({
			'?1': vsql.new_bigint_value(r.id)
		})!
	}
	mut delete_parts := db.prepare('DELETE FROM parts WHERE manifest = ?')!
	for manifest in p.freed_manifests {
		delete_parts.query({
			'?1': vsql.new_varchar_value(manifest)
		})!
	}
	mut delete_object := db.prepare('DELETE FROM objects WHERE sha256 = ?')!
	for sha in p.freed {
		delete_object.query({
			'?1': vsql.new_varchar_value(sha)
		})!
	}
	db.query('COMMIT')!
}

// Pruner tracks which versions are being removed and which objects that
// frees.
struct Pruner {
mut:
	refs            map[string]int // what uses each object
	manifest_refs   map[string]int // versions using each manifest
	parts           map[string][]string
	stored_sizes    map[string]i64
	total           i64 // stored bytes still in use
	remove          []PruneRow
	freed           []string // objects no longer used
	freed_manifests []string
}

fn (p Pruner) freed_bytes() i64 {
	mut n := i64(0)
	for sha in p.freed {
		n += p.stored_sizes[sha]
	}
	return n
}

fn (mut p Pruner) drop(r PruneRow) {
	p.remove << r
	if r.object != '' {
		p.release(r.object)
	}
	if r.manifest != '' {
		p.manifest_refs[r.manifest]--
		if p.manifest_refs[r.manifest] == 0 {
			p.freed_manifests << r.manifest
			for sha in p.parts[r.manifest] {
				p.release(sha)
			}
		}
	}
}

fn (mut p Pruner) release(sha string) {
	p.refs[sha]--
	if p.refs[sha] == 0 {
		p.freed << sha
		p.total -= p.stored_sizes[sha]
	}
}
