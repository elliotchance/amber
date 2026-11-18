module main

import os
import time
import elliotchance.vsql.vsql

const schema = [
	'CREATE TABLE config (
		destination VARCHAR(4096) NOT NULL
	)',
	"CREATE TABLE patterns (
		kind VARCHAR(7) NOT NULL CHECK (kind IN ('include', 'exclude')),
		glob VARCHAR(4096) NOT NULL
	)",
	// objects holds one row for each file stored in the destination, at
	// destination/AB/CD/SHA256. Many files (or versions of a file) can share
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

struct Config {
	destination string
	includes    []string
	excludes    []string
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

fn create_database(path string, config Config) ! {
	if os.exists(path) {
		return error('${path} already exists')
	}

	write_schema(path, config) or {
		remove_database(path)
		return err
	}
}

// remove_database removes path and the files vsql keeps next to it.
fn remove_database(path string) {
	for suffix in ['', '.wal', '.session', '.isolation', '.isolation.queue'] {
		os.rm(path + suffix) or {}
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

	mut stmt := db.prepare('INSERT INTO config (destination) VALUES (?)')!
	stmt.query({
		'?1': vsql.new_varchar_value(config.destination)
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

fn open_database(path string) !&vsql.Connection {
	if !os.exists(path) {
		return error('${path} does not exist, run "amber init -f ${path}" to create it')
	}
	return vsql.open(path)!
}

fn read_config(mut db vsql.Connection) !Config {
	mut destination := ''
	for row in db.query('SELECT destination FROM config')! {
		destination = row.get_string('DESTINATION')!
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
		destination: destination
		includes:    includes
		excludes:    excludes
	}
}

// latest_versions returns the latest row of every path in files whose path is
// exactly prefix or under prefix (an empty prefix is every path), only counting
// rows backed up at or before as_of (microseconds since the UNIX epoch).
fn latest_versions(mut db vsql.Connection, prefix string, as_of i64) !map[string]FileVersion {
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
	mut result := map[string]string{}
	for row in db.query('SELECT sha256, compression FROM objects')! {
		result[row.get_string('SHA256')!] = row.get_string('COMPRESSION')!
	}
	return result
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
