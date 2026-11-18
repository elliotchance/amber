module main

import os

// restore copies path, as it was at as_of (microseconds since the UNIX epoch),
// into target, which must not exist yet. A folder's contents go directly into
// target, and a file goes into target under its own name. Each restored file
// is checked against its SHA-256 and gets back its modified time.
fn restore(dir string, path_arg string, target string, as_of i64, log fn (string)) !int {
	if os.exists(target) {
		return stage_error(.target_exists, '${target} already exists')
	}

	mut db := open_database(dir)!
	defer {
		db.close()
	}

	config := read_config(mut db, dir)!
	objects := known_objects(mut db)!
	path := os.abs_path(path_arg).trim_right('/')
	versions := latest_versions(mut db, path, as_of)!

	// Relative path in target => version.
	mut files := map[string]FileVersion{}
	if v := versions[path] {
		if !v.deleted {
			files[os.base(path)] = v
		}
	}
	if files.len == 0 {
		for p, v in versions {
			if !v.deleted && p != path {
				files[p[path.len + 1..]] = v
			}
		}
	}
	if files.len == 0 {
		return stage_error(.not_found, '${path_arg}: not in the backup')
	}

	os.mkdir_all(target) or { return at(.write_target, err) }
	mut rels := files.keys()
	rels.sort()
	for rel in rels {
		v := files[rel]
		out := os.join_path(target, rel)
		os.mkdir_all(os.dir(out)) or { return at(.write_target, err) }

		object := object_path(config.dir, v.sha256)
		compression := objects[v.sha256] or {
			return stage_error(.missing_object, '${v.path}: object ${v.sha256} is not in the index')
		}
		restore_object(object, compression, out)!

		if sha256_file(out) or { return at(.checksum, err) } != v.sha256 {
			return stage_error(.checksum, '${out}: restored file does not match its SHA-256 ${v.sha256}')
		}
		set_mtime(out, v.modified) or { return at(.write_target, err) }
		log('restored ${out}')
	}
	return files.len
}
