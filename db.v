module main

import os
import time
import elliotchance.vsql.vsql

// migrations upgrade an index one version at a time: migrations[0] upgrades
// version 1 to 2, migrations[1] upgrades 2 to 3, and so on. Only ever append
// to it. schema always creates the latest version, so a change to the
// schema needs a migration that makes the same change to an existing index.
const migrations = [][]string{}

// schema_version is the version of the index this amber reads and writes.
const schema_version = migrations.len + 1

const schema = [
	// version is the schema_version that wrote this index (see migrations).
	// max_versions is the most previous versions of each path that are kept.
	// max_size is the most bytes the stored objects can use; to stay under
	// it, previous versions can be removed while a path keeps at least
	// min_versions of them. keep_deleted
	// is how many days a deleted path is kept before all of its versions are
	// removed. NULL means unlimited (or forever). The backup folder itself isn't stored, it's wherever db.vsql
	// is, so the folder can be moved or mounted somewhere else.
	'CREATE TABLE config (
		version INTEGER NOT NULL,
		max_versions INTEGER CHECK (max_versions >= 0),
		min_versions INTEGER CHECK (min_versions >= 0),
		max_size BIGINT CHECK (max_size >= 0),
		keep_deleted INTEGER CHECK (keep_deleted >= 0)
	)',
	// no_compress is patterns of files whose chunks are stored as is, matched
	// like excludes but ignoring case. Changing it only affects new chunks.
	'CREATE TABLE no_compress (
		glob VARCHAR(4096) NOT NULL PRIMARY KEY
	)',
	"CREATE TABLE patterns (
		kind VARCHAR(7) NOT NULL CHECK (kind IN ('include', 'exclude')),
		glob VARCHAR(4096) NOT NULL
	)",
	// objects holds one row for each chunk stored in the backup folder, at
	// AB/CD/SHA256, where sha256 is the hash of the chunk's original bytes.
	// size is the chunk's original size and stored_size its size on disk.
	// Chunks are shared by every file (and version) that contains them.
	"CREATE TABLE objects (
		sha256 VARCHAR(64) NOT NULL PRIMARY KEY,
		size BIGINT NOT NULL,
		stored_size BIGINT NOT NULL,
		compression VARCHAR(4) NOT NULL CHECK (compression IN ('NONE', 'ZIP'))
	)",
	// parts lists the chunks of a file made of more than one chunk, in order.
	// A manifest is the SHA-256 of its chunks' hashes (as hex, one after the
	// other), so files with the same chunks share one manifest.
	'CREATE TABLE parts (
		manifest VARCHAR(64) NOT NULL,
		seq INTEGER NOT NULL,
		sha256 VARCHAR(64) NOT NULL,
		PRIMARY KEY (manifest, seq)
	)',
	// files is only ever inserted into. Each row is a new version of a path,
	// numbered from 1 (a delete is a version too). sha256 is the hash of the
	// whole file. A file that's one chunk has no manifest and sha256 is also
	// its object. Otherwise manifest lists its chunks in parts. A deleted row
	// has no size, modified, sha256 or manifest. backed_up is when the backup
	// run started.
	'CREATE TABLE files (
		id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
		path VARCHAR(4096) NOT NULL,
		version INTEGER NOT NULL,
		size BIGINT,
		modified TIMESTAMP(6),
		sha256 VARCHAR(64),
		manifest VARCHAR(64),
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
	max_versions i64      = unlimited
	min_versions i64      = unlimited
	max_size     i64      = unlimited
	keep_deleted i64      = unlimited // days
	no_compress  []string = default_no_compress
}

// FileVersion is the latest row of a path in files.
struct FileVersion {
	path     string
	version  int
	size     i64
	modified i64 // microseconds since the UNIX epoch
	sha256   string
	manifest string // empty when the file is one chunk (sha256 is its object)
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

	mut stmt := db.prepare('INSERT INTO config
		(version, max_versions, min_versions, max_size, keep_deleted) VALUES (?, ?, ?, ?, ?)')!
	stmt.query({
		'?1': vsql.new_integer_value(schema_version)
		'?2': limit_value(config.max_versions, .integer)
		'?3': limit_value(config.min_versions, .integer)
		'?4': limit_value(config.max_size, .bigint)
		'?5': limit_value(config.keep_deleted, .integer)
	})!

	add_no_compress_rows(mut db, config.no_compress)!

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
	mut db := vsql.open(db_file(dir)) or { return at(.open_index, err) }
	migrate(mut db, dir) or {
		db.close()
		return err
	}
	return db
}

// migrate upgrades an index made by an older amber to schema_version. Each
// step runs in its own transaction with the version bump, so a failure leaves
// the index at the last version that completed. An index made by a newer
// amber is refused, because this one can't know what it means.
fn migrate(mut db vsql.Connection, dir string) ! {
	mut version := index_version(mut db) or { return at(.open_index, err) }
	if version > schema_version {
		return stage_error(.index_newer, '${dir} was made by a newer amber (index version ${version}, this amber reads up to ${schema_version}), upgrade amber to use it')
	}
	for version < schema_version {
		migrate_step(mut db, version) or {
			db.query('ROLLBACK') or {}
			return stage_error(.write_index, 'upgrading ${dir} from index version ${version} to ${version + 1}: ${err.msg()}')
		}
		version++
	}
}

fn index_version(mut db vsql.Connection) !int {
	for row in db.query('SELECT version FROM config')! {
		return row.get_int('VERSION')!
	}
	return error('the index has no config')
}

fn migrate_step(mut db vsql.Connection, from int) ! {
	db.query('START TRANSACTION')!
	for statement in migrations[from - 1] {
		db.query(statement)!
	}
	mut stmt := db.prepare('UPDATE config SET version = ?')!
	stmt.query({
		'?1': vsql.new_integer_value(from + 1)
	})!
	db.query('COMMIT')!
}

fn read_config(mut db vsql.Connection, dir string) !Config {
	return read_config_rows(mut db, dir) or { return at(.read_index, err) }
}

fn read_config_rows(mut db vsql.Connection, dir string) !Config {
	mut max_versions := unlimited
	mut max_size := unlimited
	mut keep_deleted := unlimited
	mut min_versions := unlimited
	for row in db.query('SELECT max_versions, min_versions, max_size, keep_deleted FROM config')! {
		if !row.get_null('MIN_VERSIONS')! {
			min_versions = row.get('MIN_VERSIONS')!.int_value()
		}
		if !row.get_null('KEEP_DELETED')! {
			keep_deleted = row.get('KEEP_DELETED')!.int_value()
		}
		if !row.get_null('MAX_VERSIONS')! {
			max_versions = row.get('MAX_VERSIONS')!.int_value()
		}
		if !row.get_null('MAX_SIZE')! {
			max_size = row.get('MAX_SIZE')!.int_value()
		}
	}

	mut no_compress := []string{}
	for row in db.query('SELECT glob FROM no_compress ORDER BY glob')! {
		no_compress << row.get_string('GLOB')!
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
		keep_deleted: keep_deleted
		min_versions: min_versions
		no_compress:  no_compress
	}
}

// set_keep_deleted changes how many days deleted paths are kept (or
// unlimited for forever).
fn set_keep_deleted(dir string, days i64) ! {
	mut db := open_database(dir)!
	defer {
		db.close()
	}
	update_keep_deleted(mut db, days) or { return at(.write_index, err) }
}

// set_min_versions changes how many previous versions max_size can't remove
// (or unlimited, so it can't remove any).
fn set_min_versions(dir string, n i64) ! {
	mut db := open_database(dir)!
	defer {
		db.close()
	}
	mut stmt := db.prepare('UPDATE config SET min_versions = ?') or {
		return at(.write_index, err)
	}
	stmt.query({
		'?1': limit_value(n, .integer)
	}) or { return at(.write_index, err) }
}

// change_no_compress adds and then removes no_compress patterns. Removing a
// pattern that isn't there is an error, adding one that is does nothing.
fn change_no_compress(dir string, add []string, remove []string) ! {
	mut db := open_database(dir)!
	defer {
		db.close()
	}
	current := read_config(mut db, dir)!.no_compress
	no_compress_list(current, add, remove)!
	update_no_compress(mut db, add.filter(it !in current), remove) or {
		db.query('ROLLBACK') or {}
		return at(.write_index, err)
	}
}

fn update_no_compress(mut db vsql.Connection, add []string, remove []string) ! {
	db.query('START TRANSACTION')!
	add_no_compress_rows(mut db, add)!
	mut stmt := db.prepare('DELETE FROM no_compress WHERE glob = ?')!
	for pattern in remove {
		stmt.query({
			'?1': vsql.new_varchar_value(pattern)
		})!
	}
	db.query('COMMIT')!
}

fn add_no_compress_rows(mut db vsql.Connection, patterns []string) ! {
	mut stmt := db.prepare('INSERT INTO no_compress (glob) VALUES (?)')!
	mut seen := map[string]bool{}
	for pattern in patterns {
		if pattern in seen {
			continue
		}
		seen[pattern] = true
		stmt.query({
			'?1': vsql.new_varchar_value(pattern)
		})!
	}
}

fn update_keep_deleted(mut db vsql.Connection, days i64) ! {
	mut stmt := db.prepare('UPDATE config SET keep_deleted = ?')!
	stmt.query({
		'?1': limit_value(days, .integer)
	})!
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
		mut stmt := db.prepare('SELECT path, version, size, modified, sha256, manifest, deleted FROM files
			WHERE backed_up <= ? ORDER BY id')!
		stmt.query({
			'?1': as_of_value
		})!
	} else {
		// Everything under "/a/b/" sorts between "/a/b/" and "/a/b0", since "0"
		// comes straight after "/".
		dir := prefix.trim_right('/') + '/'
		mut stmt := db.prepare('SELECT path, version, size, modified, sha256, manifest, deleted FROM files
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
				manifest: if row.get_null('MANIFEST')! { '' } else { row.get_string('MANIFEST')! }
			}
		}
	}
	return result
}

struct DeletedInfo {
	found      bool // false if it was never in the backup, or still exists
	deleted_at i64  // when the path (or the last file in the folder) was deleted
	before     i64  // a time just before deleted_at, when it still existed
}

// deleted_info is when path (a file, or every file in a folder) was deleted,
// as of as_of. For a
// folder it's the file deleted last, since the folder existed until then.
fn deleted_info(mut db vsql.Connection, path string, as_of i64) !DeletedInfo {
	return deleted_info_rows(mut db, path, as_of) or { return at(.read_index, err) }
}

fn deleted_info_rows(mut db vsql.Connection, path string, as_of i64) !DeletedInfo {
	dir := path.trim_right('/') + '/'
	mut stmt := db.prepare('SELECT path, deleted, backed_up FROM files
		WHERE (path = ? OR (path >= ? AND path < ?)) AND backed_up <= ? ORDER BY id')!
	// path => whether its latest row is a delete, and that row's backed_up
	mut deleted := map[string]bool{}
	mut latest := map[string]i64{}
	for row in stmt.query({
		'?1': vsql.new_varchar_value(path)
		'?2': vsql.new_varchar_value(dir)
		'?3': vsql.new_varchar_value(dir.trim_right('/') + '0')
		'?4': vsql.new_timestamp_value(us_to_timestamp(as_of))!
	})! {
		p := row.get_string('PATH')!
		d := row.get_bool('DELETED')! == .is_true
		t := time_to_us(row.get('BACKED_UP')!.time_value().t)
		deleted[p] = d
		latest[p] = t
	}

	mut info := DeletedInfo{}
	for p, d in deleted {
		if !d {
			return DeletedInfo{} // something still exists
		}
		if latest[p] > info.deleted_at {
			info = DeletedInfo{
				found:      true
				deleted_at: latest[p]
				// -t is to the second, so a second earlier is the last time
				// that's certain to be before the delete.
				before:     latest[p] - 1_000_000
			}
		}
	}
	return info
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

// known_manifests returns every manifest in parts.
fn known_manifests(mut db vsql.Connection) !map[string]bool {
	return known_manifest_rows(mut db) or { return at(.read_index, err) }
}

fn known_manifest_rows(mut db vsql.Connection) !map[string]bool {
	mut result := map[string]bool{}
	for row in db.query('SELECT manifest FROM parts WHERE seq = 0')! {
		result[row.get_string('MANIFEST')!] = true
	}
	return result
}

// manifest_chunks returns the chunks of a manifest in order.
fn manifest_chunks(mut db vsql.Connection, manifest string) ![]string {
	return manifest_chunk_rows(mut db, manifest) or { return at(.read_index, err) }
}

fn manifest_chunk_rows(mut db vsql.Connection, manifest string) ![]string {
	mut stmt := db.prepare('SELECT sha256 FROM parts WHERE manifest = ? ORDER BY seq')!
	mut result := []string{}
	for row in stmt.query({
		'?1': vsql.new_varchar_value(manifest)
	})! {
		result << row.get_string('SHA256')!
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
