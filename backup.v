module main

import crypto.sha256
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
	result.pruned += prune(mut db, config, now, log)!.versions
	latest := latest_versions(mut db, '', now)!
	mut objects := known_objects(mut db)!
	mut manifests := known_manifests(mut db)!
	mut total := stored_total(mut db)!
	opts := StoreOptions{
		blksize:     block_size(config.dir)
		no_compress: config.no_compress
	}

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

		// Each file is one transaction: its new chunks are written first, then
		// its rows are committed together. If backup is killed, the index never
		// points at a missing chunk. The chunks of at most one file can be left
		// without rows, and the next backup records them.
		room := if config.max_size == unlimited { unlimited } else { config.max_size - total }
		file := store_file(path, config.dir, objects, room, opts) or {
			if err is StageError && err.stage == .read_source {
				log('skipped  ${path}: ${err.msg()}')
				result.skipped++
				continue
			}
			// Everything backed up so far is committed, and this file's chunks
			// were removed again, so running backup again carries on from here.
			stage := if err is StageError { err.stage } else { Stage.write_object }
			return stage_error(stage, 'backup stopped: ${err.msg()}; ${result.new + result.changed} files were backed up before stopping')
		}

		new_manifest := file.manifest != '' && file.manifest !in manifests
		w.add_file(path, prev.version + 1, st, file, new_manifest) or {
			return at(.write_index, err)
		}
		for o in file.new_objects {
			objects[o.sha] = o.compression
			total += o.stored_size
		}
		if new_manifest {
			manifests[file.manifest] = true
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
	result.pruned += prune(mut db, config, now, log)!.versions
	return result
}

struct NewObject {
	sha         string
	size        i64
	stored_size i64
	compression string
}

// StoredFile is a file whose chunks are all in the backup folder, but which
// isn't in the index yet.
struct StoredFile {
mut:
	sha256      string // of the whole file
	manifest    string // empty for a file that's one chunk
	chunks      []string
	new_objects []NewObject
	new_bytes   i64
}

// store_file reads path once: it's split into chunks, each chunk that isn't
// stored yet is written, and the whole file is hashed. objects is every chunk
// already in the index, and room is how many more bytes can be stored. If
// anything fails, the chunks it wrote are removed again (no row refers to
// them yet).
fn store_file(path string, dir string, objects map[string]string, room i64, opts StoreOptions) !StoredFile {
	mut file := StoredFile{}
	store_chunks(path, dir, objects, room, opts, mut file) or {
		for o in file.new_objects {
			remove_object(dir, o.sha)
		}
		return err
	}
	return file
}

fn store_chunks(path string, dir string, objects map[string]string, room i64, opts StoreOptions, mut file StoredFile) ! {
	mut c := new_chunker(path) or { return at(.read_source, err) }
	defer {
		c.close()
	}
	mut whole := sha256.new()
	mut written := map[string]bool{}
	for {
		chunk, ok := c.next() or { return at(.read_source, err) }
		if !ok {
			break
		}
		whole.write(chunk) or { return at(.read_source, err) }
		sha := sha256.sum(chunk).hex()
		file.chunks << sha
		if sha in objects || sha in written {
			continue
		}

		data, compression := encode_chunk(path, sha, chunk, opts) or {
			return at(.compress, err)
		}
		check_room(path, file.new_bytes + data.len, room)!
		write_object(dir, sha, data)!
		written[sha] = true
		file.new_objects << NewObject{
			sha:         sha
			size:        chunk.len
			stored_size: data.len
			compression: compression
		}
		file.new_bytes += data.len
	}

	file.sha256 = whole.sum([]u8{}).hex()
	if file.chunks.len > 1 {
		file.manifest = sha256.sum(file.chunks.join('').bytes()).hex()
	} else {
		// A file that's one chunk is its own object.
		file.chunks = []
	}
}

// IndexWriter adds the versions and objects of one backup run.
struct IndexWriter {
mut:
	db             &vsql.Connection
	backed_up      vsql.Value
	insert_file    vsql.PreparedStmt
	insert_deleted vsql.PreparedStmt
	insert_object  vsql.PreparedStmt
	insert_part    vsql.PreparedStmt
}

fn new_index_writer(mut db vsql.Connection, now i64) !IndexWriter {
	return IndexWriter{
		db:             db
		backed_up:      vsql.new_timestamp_value(us_to_timestamp(now))!
		insert_file:    db.prepare('INSERT INTO files
			(path, version, size, modified, sha256, manifest, deleted, backed_up)
			VALUES (?, ?, ?, ?, ?, ?, FALSE, ?)')!
		insert_deleted: db.prepare('INSERT INTO files
			(path, version, deleted, backed_up) VALUES (?, ?, TRUE, ?)')!
		insert_object:  db.prepare('INSERT INTO objects
			(sha256, size, stored_size, compression) VALUES (?, ?, ?, ?)')!
		insert_part:    db.prepare('INSERT INTO parts (manifest, seq, sha256) VALUES (?, ?, ?)')!
	}
}

fn (mut w IndexWriter) begin() ! {
	w.db.query('START TRANSACTION')!
}

fn (mut w IndexWriter) commit() ! {
	w.db.query('COMMIT')!
}

// add_file records a new version of path, with its new chunks and manifest,
// in one transaction.
fn (mut w IndexWriter) add_file(path string, version int, st FileStat, file StoredFile, new_manifest bool) ! {
	w.begin()!
	w.write_file(path, version, st, file, new_manifest) or {
		w.db.query('ROLLBACK') or {}
		return err
	}
	w.commit()!
}

fn (mut w IndexWriter) write_file(path string, version int, st FileStat, file StoredFile, new_manifest bool) ! {
	for o in file.new_objects {
		w.insert_object.query({
			'?1': vsql.new_varchar_value(o.sha)
			'?2': vsql.new_bigint_value(o.size)
			'?3': vsql.new_bigint_value(o.stored_size)
			'?4': vsql.new_varchar_value(o.compression)
		})!
	}
	if new_manifest {
		for i, sha in file.chunks {
			w.insert_part.query({
				'?1': vsql.new_varchar_value(file.manifest)
				'?2': vsql.new_integer_value(i)
				'?3': vsql.new_varchar_value(sha)
			})!
		}
	}
	w.insert_file.query({
		'?1': vsql.new_varchar_value(path)
		'?2': vsql.new_integer_value(version)
		'?3': vsql.new_bigint_value(st.size)
		'?4': vsql.new_timestamp_value(us_to_timestamp(st.mtime_us))!
		'?5': vsql.new_varchar_value(file.sha256)
		'?6': if file.manifest == '' {
			vsql.new_null_value(.is_varchar)
		} else {
			vsql.new_varchar_value(file.manifest)
		}
		'?7': w.backed_up
	})!
}

fn (mut w IndexWriter) add_delete(path string, version int) ! {
	w.insert_deleted.query({
		'?1': vsql.new_varchar_value(path)
		'?2': vsql.new_integer_value(version)
		'?3': w.backed_up
	})!
}
