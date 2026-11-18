module main

import elliotchance.vsql.vsql

struct BackupStats {
mut:
	new       int
	changed   int
	unchanged int
	deleted   int
	skipped   int
	pruned    int // old versions removed by max_versions or max_size
}

// backup backs up every included file into the backup folder dir. now is the time
// (microseconds since the UNIX epoch) recorded as backed_up for every version
// added in this run.
fn backup(dir string, now i64, log fn (string)) !BackupStats {
	mut db := open_database(dir)!
	defer {
		db.close()
	}

	config := read_config(mut db, dir)!
	mut result := BackupStats{}
	result.pruned += prune(mut db, config, log)!.versions
	latest := latest_versions(mut db, '', now)!
	mut objects := known_objects(mut db)!
	mut total := stored_total(mut db)!

	walker := Walker{
		excludes: config.excludes
		skip:     [config.dir]
	}
	mut paths := []string{}
	for include in config.includes {
		walker.walk(include, mut paths)
	}

	mut w := new_index_writer(mut db, now) or { return at(.write_index, err) }
	mut seen := map[string]bool{}

	for path in paths {
		seen[path] = true
		st := file_stat(path) or {
			log('skipped  ${path}: ${err}')
			result.skipped++
			continue
		}
		prev := latest[path] or { FileVersion{} }
		if prev.version > 0 && !prev.deleted && prev.size == st.size && prev.modified == st.mtime_us {
			result.unchanged++
			continue
		}

		sha := sha256_file(path) or {
			log('skipped  ${path}: ${err}')
			result.skipped++
			continue
		}
		// Each file is one transaction: its object (if it's new) is written and
		// renamed into place first, then its rows are committed together. If
		// backup is killed, the index never points at a missing object. At most
		// one object can be left without rows, and the next backup records it.
		new_object := sha !in objects
		mut stored_size := i64(0)
		mut compression := objects[sha] or { '' }
		if new_object {
			room := if config.max_size == unlimited { unlimited } else { config.max_size - total }
			stored_size, compression = store_object(path, sha, st.size, config.dir, room) or {
				// Everything backed up so far is committed, and the failed
				// object was never written (or was removed), so running backup
				// again carries on from here.
				stage := if err is StageError { err.stage } else { Stage.write_object }
				return stage_error(stage, 'backup stopped: ${err.msg()}; ${result.new + result.changed} files were backed up before stopping')
			}
		}

		w.add_file(path, prev.version + 1, st, sha, new_object, stored_size, compression) or {
			return at(.write_index, err)
		}
		if new_object {
			total += stored_size
			objects[sha] = compression
		}
		if prev.version == 0 || prev.deleted {
			log('new      ${path}')
			result.new++
		} else {
			log('changed  ${path}')
			result.changed++
		}
	}

	mut gone := latest.keys().filter(!latest[it].deleted && it !in seen)
	gone.sort()
	w.begin() or { return at(.write_index, err) }
	for path in gone {
		w.add_delete(path, latest[path].version + 1) or { return at(.write_index, err) }
		log('deleted  ${path}')
		result.deleted++
	}

	w.commit() or { return at(.write_index, err) }
	result.pruned += prune(mut db, config, log)!.versions
	return result
}

// IndexWriter adds the versions and objects of one backup run.
struct IndexWriter {
mut:
	db             &vsql.Connection
	backed_up      vsql.Value
	insert_file    vsql.PreparedStmt
	insert_deleted vsql.PreparedStmt
	insert_object  vsql.PreparedStmt
}

fn new_index_writer(mut db vsql.Connection, now i64) !IndexWriter {
	return IndexWriter{
		db:             db
		backed_up:      vsql.new_timestamp_value(us_to_timestamp(now))!
		insert_file:    db.prepare('INSERT INTO files
			(path, version, size, modified, sha256, deleted, backed_up)
			VALUES (?, ?, ?, ?, ?, FALSE, ?)')!
		insert_deleted: db.prepare('INSERT INTO files
			(path, version, deleted, backed_up) VALUES (?, ?, TRUE, ?)')!
		insert_object:  db.prepare('INSERT INTO objects
			(sha256, size, stored_size, compression) VALUES (?, ?, ?, ?)')!
	}
}

fn (mut w IndexWriter) begin() ! {
	w.db.query('START TRANSACTION')!
}

fn (mut w IndexWriter) commit() ! {
	w.db.query('COMMIT')!
}

// add_file records a new version of path (and its object, if it's new) in
// one transaction.
fn (mut w IndexWriter) add_file(path string, version int, st FileStat, sha string, new_object bool, stored_size i64, compression string) ! {
	w.begin()!
	w.write_file(path, version, st, sha, new_object, stored_size, compression) or {
		w.db.query('ROLLBACK') or {}
		return err
	}
	w.commit()!
}

fn (mut w IndexWriter) write_file(path string, version int, st FileStat, sha string, new_object bool, stored_size i64, compression string) ! {
	if new_object {
		w.add_object(sha, st.size, stored_size, compression)!
	}
	w.add_version(path, version, st.size, st.mtime_us, sha)!
}

fn (mut w IndexWriter) add_object(sha string, size i64, stored_size i64, compression string) ! {
	w.insert_object.query({
		'?1': vsql.new_varchar_value(sha)
		'?2': vsql.new_bigint_value(size)
		'?3': vsql.new_bigint_value(stored_size)
		'?4': vsql.new_varchar_value(compression)
	})!
}

fn (mut w IndexWriter) add_version(path string, version int, size i64, mtime_us i64, sha string) ! {
	w.insert_file.query({
		'?1': vsql.new_varchar_value(path)
		'?2': vsql.new_integer_value(version)
		'?3': vsql.new_bigint_value(size)
		'?4': vsql.new_timestamp_value(us_to_timestamp(mtime_us))!
		'?5': vsql.new_varchar_value(sha)
		'?6': w.backed_up
	})!
}

fn (mut w IndexWriter) add_delete(path string, version int) ! {
	w.insert_deleted.query({
		'?1': vsql.new_varchar_value(path)
		'?2': vsql.new_integer_value(version)
		'?3': w.backed_up
	})!
}
