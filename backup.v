module main

import os
import elliotchance.vsql.vsql

// Changes are committed in batches, so an interrupted backup keeps most of its
// work without paying for a commit per file.
const commit_every = 100

struct BackupStats {
mut:
	new       int
	changed   int
	unchanged int
	deleted   int
	skipped   int
}

// backup backs up every included file into the destination. now is the time
// (microseconds since the UNIX epoch) recorded as backed_up for every version
// added in this run.
fn backup(db_path string, now i64, log fn (string)) !BackupStats {
	mut db := open_database(db_path)!
	defer {
		db.close()
	}

	config := read_config(mut db)!
	latest := latest_versions(mut db, '', now)!
	mut objects := known_objects(mut db)!

	walker := Walker{
		excludes: config.excludes
		skip:     [os.real_path(db_path), config.destination]
	}
	mut paths := []string{}
	for include in config.includes {
		walker.walk(include, mut paths)
	}

	backed_up := vsql.new_timestamp_value(us_to_timestamp(now))!
	mut insert_file := db.prepare('INSERT INTO files
		(path, version, size, modified, sha256, deleted, backed_up)
		VALUES (?, ?, ?, ?, ?, FALSE, ?)')!
	mut insert_deleted := db.prepare('INSERT INTO files
		(path, version, deleted, backed_up) VALUES (?, ?, TRUE, ?)')!
	mut insert_object := db.prepare('INSERT INTO objects
		(sha256, size, stored_size, compression) VALUES (?, ?, ?, ?)')!

	mut result := BackupStats{}
	mut seen := map[string]bool{}
	mut pending := 0
	db.query('START TRANSACTION')!

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
		if sha !in objects {
			stored_size, compression := store_object(path, sha, st.size, config.destination)!
			insert_object.query({
				'?1': vsql.new_varchar_value(sha)
				'?2': vsql.new_bigint_value(st.size)
				'?3': vsql.new_bigint_value(stored_size)
				'?4': vsql.new_varchar_value(compression)
			})!
			objects[sha] = compression
		}

		insert_file.query({
			'?1': vsql.new_varchar_value(path)
			'?2': vsql.new_integer_value(prev.version + 1)
			'?3': vsql.new_bigint_value(st.size)
			'?4': vsql.new_timestamp_value(us_to_timestamp(st.mtime_us))!
			'?5': vsql.new_varchar_value(sha)
			'?6': backed_up
		})!
		if prev.version == 0 || prev.deleted {
			log('new      ${path}')
			result.new++
		} else {
			log('changed  ${path}')
			result.changed++
		}

		pending++
		if pending >= commit_every {
			db.query('COMMIT')!
			db.query('START TRANSACTION')!
			pending = 0
		}
	}

	mut gone := latest.keys().filter(!latest[it].deleted && it !in seen)
	gone.sort()
	for path in gone {
		insert_deleted.query({
			'?1': vsql.new_varchar_value(path)
			'?2': vsql.new_integer_value(latest[path].version + 1)
			'?3': backed_up
		})!
		log('deleted  ${path}')
		result.deleted++
	}

	db.query('COMMIT')!
	return result
}
