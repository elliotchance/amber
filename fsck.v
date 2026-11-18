module main

import os
import elliotchance.vsql.vsql

struct FsckResult {
mut:
	objects  int
	versions int
	problems []string
}

struct FsckObject {
	size        i64
	stored_size i64
	compression string
}

// fsck checks that the index and the objects in the backup folder agree. With
// hash, every object is also read, decompressed and hashed to check it matches
// its name, which reads the whole backup.
fn fsck(dir string, hash bool, log fn (string)) !FsckResult {
	mut db := open_database(dir)!
	defer {
		db.close()
	}
	config := read_config(mut db, dir)!
	objects := fsck_objects(mut db) or { return at(.read_index, err) }
	parts := fsck_parts(mut db) or { return at(.read_index, err) }
	versions := fsck_versions(mut db) or { return at(.read_index, err) }

	mut result := FsckResult{
		objects:  objects.len
		versions: versions.len
	}
	mut used := map[string]bool{}
	mut used_manifests := map[string]bool{}

	// Every version's object, or manifest and its chunks, is in the index.
	for v in versions {
		if v.deleted {
			continue
		}
		if v.manifest == '' {
			used[v.sha256] = true
			if v.sha256 !in objects {
				result.problems << '${v.path} version ${v.version}: object ${v.sha256} is not in the index'
			}
			continue
		}
		used_manifests[v.manifest] = true
		chunks := parts[v.manifest] or {
			result.problems << '${v.path} version ${v.version}: manifest ${v.manifest} has no parts'
			continue
		}
		for sha in chunks {
			used[sha] = true
			if sha !in objects {
				result.problems << '${v.path} version ${v.version}: chunk ${sha} is not in the index'
			}
		}
	}
	for manifest, chunks in parts {
		if manifest !in used_manifests {
			result.problems << 'manifest ${manifest} is not used by any version'
			for sha in chunks {
				used[sha] = true // reported with its manifest
			}
		}
	}

	// Every object in the index is on disk with the right size, and is used.
	mut shas := objects.keys()
	shas.sort()
	for sha in shas {
		o := objects[sha]
		path := object_path(config.dir, sha)
		if !os.is_file(path) {
			result.problems << 'object ${sha} is missing from the backup folder'
			continue
		}
		if i64(os.file_size(path)) != o.stored_size {
			result.problems << 'object ${sha} is ${os.file_size(path)} bytes, the index says ${o.stored_size}'
			continue
		}
		if sha !in used {
			result.problems << 'object ${sha} is not used by any version'
		}
		if hash {
			data := read_object(config.dir, sha, o.compression) or {
				result.problems << err.msg()
				continue
			}
			if data.len != o.size {
				result.problems << 'object ${sha} is ${data.len} bytes when decompressed, the index says ${o.size}'
			}
		}
	}

	// Every file in the backup folder's object layout is in the index.
	for ab in os.ls(config.dir) or { [] } {
		if ab.len != 2 || !os.is_dir(os.join_path(config.dir, ab)) {
			continue
		}
		for cd in os.ls(os.join_path(config.dir, ab)) or { [] } {
			for name in os.ls(os.join_path(config.dir, ab, cd)) or { [] } {
				rel := os.join_path(ab, cd, name)
				if name.ends_with('.tmp') {
					result.problems << '${rel} is a temporary file left by an interrupted backup'
				} else if !name.starts_with(ab + cd) {
					result.problems << '${rel} is in the wrong folder'
				} else if name !in objects {
					result.problems << '${rel} is not in the index'
				}
			}
		}
	}

	return result
}

fn fsck_objects(mut db vsql.Connection) !map[string]FsckObject {
	mut result := map[string]FsckObject{}
	for row in db.query('SELECT sha256, size, stored_size, compression FROM objects')! {
		result[row.get_string('SHA256')!] = FsckObject{
			size:        row.get('SIZE')!.int_value()
			stored_size: row.get('STORED_SIZE')!.int_value()
			compression: row.get_string('COMPRESSION')!
		}
	}
	return result
}

// fsck_parts returns each manifest's chunks in order.
fn fsck_parts(mut db vsql.Connection) !map[string][]string {
	mut result := map[string][]string{}
	for row in db.query('SELECT manifest, sha256 FROM parts ORDER BY manifest, seq')! {
		result[row.get_string('MANIFEST')!] << row.get_string('SHA256')!
	}
	return result
}

fn fsck_versions(mut db vsql.Connection) ![]FileVersion {
	mut result := []FileVersion{}
	for row in db.query('SELECT path, version, sha256, manifest, deleted FROM files ORDER BY id')! {
		deleted := row.get_bool('DELETED')! == .is_true
		result << FileVersion{
			path:     row.get_string('PATH')!
			version:  row.get_int('VERSION')!
			deleted:  deleted
			sha256:   if deleted { '' } else { row.get_string('SHA256')! }
			manifest: if row.get_null('MANIFEST')! { '' } else { row.get_string('MANIFEST')! }
		}
	}
	return result
}
