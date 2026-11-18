module main

import os
import crypto.sha256
import elliotchance.vsql.vsql

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

		restore_file(mut db, config.dir, objects, v, out)!
		set_mtime(out, v.modified) or { return at(.write_target, err) }
		log('restored ${out}')
	}
	return files.len
}

// restore_file writes the chunks of v to out, which must not exist yet. Each
// chunk is checked against its SHA-256 as it's read, and the whole file
// against v.sha256 at the end.
fn restore_file(mut db vsql.Connection, dir string, objects map[string]string, v FileVersion, out string) ! {
	chunks := if v.manifest == '' { [v.sha256] } else { manifest_chunks(mut db, v.manifest)! }
	mut f := os.create(out) or { return at(.write_target, err) }
	defer {
		f.close()
	}
	mut whole := sha256.new()
	for sha in chunks {
		compression := objects[sha] or {
			return stage_error(.missing_object, '${v.path}: chunk ${sha} is not in the index')
		}
		data := read_object(dir, sha, compression) or {
			return stage_error(if err is StageError { err.stage } else { Stage.missing_object },
				'${v.path}: ${err.msg()}')
		}
		f.write(data) or { return at(.write_target, err) }
		whole.write(data) or { return at(.checksum, err) }
	}
	if whole.sum([]u8{}).hex() != v.sha256 {
		return stage_error(.checksum, '${out}: restored file does not match its SHA-256 ${v.sha256}')
	}
}
