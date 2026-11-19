module main

import os
import crypto.sha256
import elliotchance.vsql.vsql

// restore copies path (relative to the root), as it was at as_of (microseconds since the UNIX epoch),
// to target. A folder becomes the folder target, and a file becomes the file
// target. An empty target is path's name in the current folder. target must
// not exist yet. Each restored file is checked against its SHA-256 and gets
// back its modified time.
fn restore(b Backup, path_arg string, target_arg string, as_of i64, log fn (string)) !int {
	dir := b.dir
	mut db := open_database(b)!
	defer {
		db.close()
	}

	config := read_config(mut db, dir)!
	objects := known_objects(mut db)!
	path := clean_path(path_arg)!
	versions := latest_versions(mut db, path, as_of)!

	// Relative path in target => version. A file is "".
	mut files := map[string]FileVersion{}
	if v := versions[path] {
		if !v.deleted {
			files[''] = v
		}
	}
	if files.len == 0 {
		for p, v in versions {
			if !v.deleted && p != path {
				files[if path == '' { p } else { p[path.len + 1..] }] = v
			}
		}
	}
	if files.len == 0 {
		info := deleted_info(mut db, path, as_of)!
		if info.found {
			return stage_error(.deleted, '${path_arg} was deleted at ${format_local(info.deleted_at)}. To restore it as it was just before then, run:\n\n  ${restore_command(b, path_arg, target_arg, info.before)}')
		}
		return stage_error(.not_found, '${path_arg}: not in the backup')
	}

	name := if path == '' { os.base(config.root) } else { os.base(path) }
	target := if target_arg == '' { os.join_path(os.getwd(), name) } else { target_arg }
	if os.exists(target) {
		return stage_error(.target_exists, '${target} already exists')
	}

	mut rels := files.keys()
	rels.sort()
	for rel in rels {
		v := files[rel]
		out := if rel == '' { target } else { os.join_path(target, rel) }
		os.mkdir_all(os.dir(out)) or { return at(.write_target, err) }
		restore_file(mut db, config.dir, objects, v, out)!
		set_mtime(out, v.modified) or { return at(.write_target, err) }
		log('restored ${out}')
	}
	return files.len
}

// restore_command is the restore command for the same arguments at a time
// (microseconds since the UNIX epoch), as the user would type it.
fn restore_command(b Backup, path_arg string, target_arg string, at_time i64) string {
	mut args := ['amber', 'restore']
	if b.dir != '.' {
		args << ['-d', shell_quote(b.dir)]
	}
	if b.index != db_file(b.dir) {
		args << ['-f', shell_quote(b.index)]
	}
	args << ['-t', shell_quote(format_local(at_time))]
	args << shell_quote(path_arg)
	if target_arg != '' {
		args << shell_quote(target_arg)
	}
	return args.join(' ')
}

// shell_quote quotes s for a shell, only if it needs it.
fn shell_quote(s string) string {
	if s != '' && s.contains_only('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-~+=:,@') {
		return s
	}
	return "'" + s.replace("'", "'\\''") + "'"
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
