module main

import os

// restore copies path, as it was at as_of (microseconds since the UNIX epoch),
// into target, which must not exist yet. A folder's contents go directly into
// target, and a file goes into target under its own name. Each restored file
// is checked against its SHA-256 and gets back its modified time.
fn restore(db_path string, path_arg string, target string, as_of i64, log fn (string)) !int {
	if os.exists(target) {
		return error('${target} already exists')
	}

	mut db := open_database(db_path)!
	defer {
		db.close()
	}

	config := read_config(mut db)!
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
		return error('${path_arg}: not in the backup')
	}

	os.mkdir_all(target)!
	mut rels := files.keys()
	rels.sort()
	for rel in rels {
		v := files[rel]
		out := os.join_path(target, rel)
		os.mkdir_all(os.dir(out))!

		object := object_path(config.destination, v.sha256)
		compression := objects[v.sha256] or { return error('${v.path}: object ${v.sha256} is not in the database') }
		if compression == 'ZIP' {
			os.write_file_array(out, unzip_single_entry(os.read_bytes(object)!)!)!
		} else {
			os.cp(object, out)!
		}

		if sha256_file(out)! != v.sha256 {
			return error('${out}: restored file does not match its SHA-256 ${v.sha256}')
		}
		set_mtime(out, v.modified)!
		log('restored ${out}')
	}
	return files.len
}
