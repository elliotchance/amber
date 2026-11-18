module main

import os
import time
import elliotchance.vsql.vsql

const schema = [
	// max_versions is how many previous versions of each path are kept, and
	// max_size is the most bytes the stored objects can use. NULL means
	// unlimited. The backup folder itself isn't stored, it's wherever db.vsql
	// is, so the folder can be moved or mounted somewhere else.
	'CREATE TABLE config (
		max_versions INTEGER CHECK (max_versions >= 0),
		max_size BIGINT CHECK (max_size >= 0)
	)',
	"CREATE TABLE patterns (
		kind VARCHAR(7) NOT NULL CHECK (kind IN ('include', 'exclude')),
		glob VARCHAR(4096) NOT NULL
	)",
	// objects holds one row for each file stored in the backup folder, at
	// AB/CD/SHA256. Many files (or versions of a file) can share
	// the same object.
	"CREATE TABLE objects (
		sha256 VARCHAR(64) NOT NULL PRIMARY KEY,
		size BIGINT NOT NULL,
		stored_size BIGINT NOT NULL,
		compression VARCHAR(4) NOT NULL CHECK (compression IN ('NONE', 'ZIP'))
	)",
	// files is only ever inserted into. Each row is a new version of a path,
	// numbered from 1 (a delete is a version too). A deleted row has no size,
	// modified or sha256. backed_up is when the backup run started.
	'CREATE TABLE files (
		id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
		path VARCHAR(4096) NOT NULL,
		version INTEGER NOT NULL,
		size BIGINT,
		modified TIMESTAMP(6),
		sha256 VARCHAR(64),
		deleted BOOLEAN NOT NULL,
		backed_up TIMESTAMP(6) NOT NULL,
		UNIQUE (path, version)
	)',
]

// unlimited is the value of Config.max_versions and Config.max_size when
// there's no limit (NULL in the database).
const unlimited = i64(-1)

struct Config {
	dir          string // the backup folder, which holds db.vsql and the objects
	includes     []string
	excludes     []string
	max_versions i64 = unlimited
	max_size     i64 = unlimited
}

// FileVersion is the latest row of a path in files.
struct FileVersion {
	path     string
	version  int
	size     i64
	modified i64 // microseconds since the UNIX epoch
	sha256   string
	deleted  bool
}

// db_file is the index inside a backup folder.
fn db_file(dir string) string {
	return os.join_path(dir, 'db.vsql')
}

// create_database creates the backup folder dir, which must not exist yet,
// and the index inside it. The folder is removed again if anything fails.
fn create_database(dir string, config Config) ! {
	if os.exists(dir) {
		return stage_error(.index_exists, '${dir} already exists')
	}
	os.mkdir_all(dir) or { return at(.create_index, err) }
	write_schema(db_file(dir), config) or {
		os.rmdir_all(dir) or {}
		return at(.create_index, err)
	}
}

fn write_schema(path string, config Config) ! {
	mut db := vsql.open(path)!
	defer {
		db.close()
	}

	db.query('START TRANSACTION')!
	for statement in schema {
		db.query(statement)!
	}

	mut stmt := db.prepare('INSERT INTO config (max_versions, max_size) VALUES (?, ?)')!
	stmt.query({
		'?1': limit_value(config.max_versions, .integer)
		'?2': limit_value(config.max_size, .bigint)
	})!

	mut pattern_stmt := db.prepare('INSERT INTO patterns (kind, glob) VALUES (?, ?)')!
	for pattern in config.includes {
		pattern_stmt.query({
			'?1': vsql.new_varchar_value('include')
			'?2': vsql.new_varchar_value(pattern)
		})!
	}
	for pattern in config.excludes {
		pattern_stmt.query({
			'?1': vsql.new_varchar_value('exclude')
			'?2': vsql.new_varchar_value(pattern)
		})!
	}
	db.query('COMMIT')!
}

fn open_database(dir string) !&vsql.Connection {
	if !os.exists(db_file(dir)) {
		return stage_error(.index_missing, '${dir} is not an amber backup folder (it has no db.vsql), create one with "amber init -d ..."')
	}
	return vsql.open(db_file(dir)) or { return at(.open_index, err) }
}

fn read_config(mut db vsql.Connection, dir string) !Config {
	return read_config_rows(mut db, dir) or { return at(.read_index, err) }
}

fn read_config_rows(mut db vsql.Connection, dir string) !Config {
	mut max_versions := unlimited
	mut max_size := unlimited
	for row in db.query('SELECT max_versions, max_size FROM config')! {
		if !row.get_null('MAX_VERSIONS')! {
			max_versions = row.get('MAX_VERSIONS')!.int_value()
		}
		if !row.get_null('MAX_SIZE')! {
			max_size = row.get('MAX_SIZE')!.int_value()
		}
	}

	mut includes := []string{}
	mut excludes := []string{}
	for row in db.query('SELECT kind, glob FROM patterns')! {
		pattern := row.get_string('GLOB')!
		if row.get_string('KIND')! == 'include' {
			includes << pattern
		} else {
			excludes << pattern
		}
	}

	return Config{
		dir:          os.real_path(dir)
		includes:     includes
		excludes:     excludes
		max_versions: max_versions
		max_size:     max_size
	}
}

// set_limits changes max_versions and max_size. none leaves a limit as it is.
fn set_limits(dir string, max_versions ?i64, max_size ?i64) ! {
	mut db := open_database(dir)!
	defer {
		db.close()
	}
	update_limits(mut db, max_versions, max_size) or { return at(.write_index, err) }
}

fn update_limits(mut db vsql.Connection, max_versions ?i64, max_size ?i64) ! {
	if v := max_versions {
		mut stmt := db.prepare('UPDATE config SET max_versions = ?')!
		stmt.query({
			'?1': limit_value(v, .integer)
		})!
	}
	if v := max_size {
		mut stmt := db.prepare('UPDATE config SET max_size = ?')!
		stmt.query({
			'?1': limit_value(v, .bigint)
		})!
	}
}

enum LimitType {
	integer
	bigint
}

fn limit_value(v i64, typ LimitType) vsql.Value {
	if v == unlimited {
		return vsql.new_null_value(if typ == .integer { .is_integer } else { .is_bigint })
	}
	return if typ == .integer { vsql.new_integer_value(int(v)) } else { vsql.new_bigint_value(v) }
}

// latest_versions returns the latest row of every path in files whose path is
// exactly prefix or under prefix (an empty prefix is every path), only counting
// rows backed up at or before as_of (microseconds since the UNIX epoch).
fn latest_versions(mut db vsql.Connection, prefix string, as_of i64) !map[string]FileVersion {
	return latest_version_rows(mut db, prefix, as_of) or { return at(.read_index, err) }
}

fn latest_version_rows(mut db vsql.Connection, prefix string, as_of i64) !map[string]FileVersion {
	mut result := map[string]FileVersion{}
	as_of_value := vsql.new_timestamp_value(us_to_timestamp(as_of))!
	mut rows := if prefix == '' {
		mut stmt := db.prepare('SELECT path, version, size, modified, sha256, deleted FROM files
			WHERE backed_up <= ? ORDER BY id')!
		stmt.query({
			'?1': as_of_value
		})!
	} else {
		// Everything under "/a/b/" sorts between "/a/b/" and "/a/b0", since "0"
		// comes straight after "/".
		dir := prefix.trim_right('/') + '/'
		mut stmt := db.prepare('SELECT path, version, size, modified, sha256, deleted FROM files
			WHERE (path = ? OR (path >= ? AND path < ?)) AND backed_up <= ?
			ORDER BY id')!
		stmt.query({
			'?1': vsql.new_varchar_value(prefix)
			'?2': vsql.new_varchar_value(dir)
			'?3': vsql.new_varchar_value(dir.trim_right('/') + '0')
			'?4': as_of_value
		})!
	}
	for row in rows {
		path := row.get_string('PATH')!
		version := row.get_int('VERSION')!
		deleted := row.get_bool('DELETED')! == .is_true
		result[path] = if deleted {
			FileVersion{
				path:    path
				version: version
				deleted: true
			}
		} else {
			FileVersion{
				path:     path
				version:  version
				size:     row.get('SIZE')!.int_value()
				modified: time_to_us(row.get('MODIFIED')!.time_value().t)
				sha256:   row.get_string('SHA256')!
			}
		}
	}
	return result
}

// known_objects returns the compression of every stored object.
fn known_objects(mut db vsql.Connection) !map[string]string {
	return known_object_rows(mut db) or { return at(.read_index, err) }
}

fn known_object_rows(mut db vsql.Connection) !map[string]string {
	mut result := map[string]string{}
	for row in db.query('SELECT sha256, compression FROM objects')! {
		result[row.get_string('SHA256')!] = row.get_string('COMPRESSION')!
	}
	return result
}

// stored_total is how many bytes the objects use.
fn stored_total(mut db vsql.Connection) !i64 {
	return stored_total_row(mut db) or { return at(.read_index, err) }
}

fn stored_total_row(mut db vsql.Connection) !i64 {
	for row in db.query('SELECT COALESCE(SUM(stored_size), 0) AS total FROM objects')! {
		return row.get('TOTAL')!.int_value()
	}
	return 0
}

// us_to_timestamp formats microseconds since the UNIX epoch as a TIMESTAMP(6)
// literal in UTC.
fn us_to_timestamp(us i64) string {
	t := us_to_time(us)
	return '${t.year:04}-${t.month:02}-${t.day:02} ${t.hour:02}:${t.minute:02}:${t.second:02}.${t.nanosecond / 1000:06}'
}

fn us_to_time(us i64) time.Time {
	mut secs := us / 1_000_000
	mut rem := us % 1_000_000
	if rem < 0 {
		secs--
		rem += 1_000_000
	}
	return time.unix_microsecond(secs, int(rem))
}

fn time_to_us(t time.Time) i64 {
	return t.unix() * 1_000_000 + t.nanosecond / 1000
}
