module main

import os
import compress.szip
import elliotchance.vsql.vsql

const day = i64(86_400_000_000)

struct Env {
	root string
	src  string
	dest string
	db   string
}

fn new_env(name string) Env {
	root := os.join_path(os.vtmp_dir(), 'amber_test_${name}_${os.getpid()}')
	os.rmdir_all(root) or {}
	src := os.join_path(root, 'src')
	dest := os.join_path(root, 'dest')
	os.mkdir_all(src) or { panic(err) }
	os.mkdir_all(dest) or { panic(err) }
	return Env{
		root: os.real_path(root)
		src:  os.real_path(src)
		dest: os.real_path(dest)
		db:   os.join_path(os.real_path(root), 'amber.vsql')
	}
}

fn (e Env) init(excludes []string) {
	create_database(e.db, Config{
		destination: e.dest
		includes:    [e.src]
		excludes:    excludes
	}) or { panic(err) }
}

fn (e Env) write(name string, data string) string {
	path := os.join_path(e.src, name)
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, data) or { panic(err) }
	return path
}

fn (e Env) backup(now i64) BackupStats {
	return backup(e.db, now, fn (_ string) {}) or { panic(err) }
}

fn (e Env) rows(query string) []vsql.Row {
	mut db := vsql.open(e.db) or { panic(err) }
	defer {
		db.close()
	}
	mut rows := []vsql.Row{}
	for row in db.query(query) or { panic(err) } {
		rows << row
	}
	return rows
}

fn test_init_fails_if_file_exists() {
	e := new_env('exists')
	e.init([])
	create_database(e.db, Config{ destination: e.dest, includes: [e.src] }) or {
		assert err.msg().contains('already exists')
		return
	}
	assert false
}

fn test_backup_needs_existing_file() {
	backup('/nonexistent/amber.vsql', 0, fn (_ string) {}) or {
		assert err.msg().contains('does not exist')
		return
	}
	assert false
}

fn test_versions_deletes_and_recreates() {
	e := new_env('versions')
	e.init([])
	path := e.write('a.txt', 'one')

	assert e.backup(1 * day) == BackupStats{
		new: 1
	}
	assert e.backup(2 * day) == BackupStats{
		unchanged: 1
	}

	e.write('a.txt', 'two!')
	assert e.backup(3 * day) == BackupStats{
		changed: 1
	}

	os.rm(path)!
	assert e.backup(4 * day) == BackupStats{
		deleted: 1
	}
	assert e.backup(5 * day) == BackupStats{}

	e.write('a.txt', 'three')
	assert e.backup(6 * day) == BackupStats{
		new: 1
	}

	rows := e.rows('SELECT version, size, deleted FROM files ORDER BY id')
	assert rows.map('${it.get_int('VERSION')!}:${it.get_string('SIZE')!}:${it.get_string('DELETED')!}') == [
		'1:3:FALSE',
		'2:4:FALSE',
		'3:NULL:TRUE',
		'4:5:FALSE',
	]
}

fn test_touch_without_change_is_new_version_same_object() {
	e := new_env('touch')
	e.init([])
	path := e.write('a.txt', 'same')
	os.utime(path, 1_000_000, 1_000_000)!
	e.backup(1 * day)
	os.utime(path, 2_000_000, 2_000_000)!
	assert e.backup(2 * day) == BackupStats{
		changed: 1
	}
	assert e.rows('SELECT * FROM files').len == 2
	assert e.rows('SELECT * FROM objects').len == 1
}

fn test_identical_files_share_one_object() {
	e := new_env('dedupe')
	e.init([])
	e.write('a.txt', 'same content')
	e.write('sub/b.txt', 'same content')
	e.backup(1 * day)
	assert e.rows('SELECT * FROM files').len == 2
	assert e.rows('SELECT * FROM objects').len == 1
}

fn test_compression() {
	e := new_env('compress')
	e.init([])
	small := 'tiny'
	big := 'compress me '.repeat(10_000)
	e.write('small.txt', small)
	e.write('big.txt', big)
	e.write('big.mp3', big + '!')
	e.write('BIG.ZIP', big + '.')
	e.backup(1 * day)

	rows := e.rows('SELECT o.sha256, o.size, o.stored_size, o.compression, f.path
		FROM objects o JOIN files f ON f.sha256 = o.sha256 ORDER BY f.path')
	mut by_name := map[string]vsql.Row{}
	for row in rows {
		by_name[os.base(row.get_string('PATH')!)] = row
	}

	assert by_name['small.txt'].get_string('COMPRESSION')! == 'NONE'
	assert by_name['BIG.ZIP'].get_string('COMPRESSION')! == 'NONE'
	assert by_name['big.mp3'].get_string('COMPRESSION')! == 'NONE'

	zipped := by_name['big.txt']
	assert zipped.get_string('COMPRESSION')! == 'ZIP'
	assert zipped.get('SIZE')!.int_value() == big.len
	stored := object_path(e.dest, zipped.get_string('SHA256')!)
	assert zipped.get('STORED_SIZE')!.int_value() == os.file_size(stored)
	assert os.file_size(stored) < u64(big.len)

	mut z := szip.open(stored, .no_compression, .read_only)!
	defer {
		z.close()
	}
	z.open_entry_by_index(0)!
	assert z.read_entry_bytes()!.bytestr() == big
}

fn test_excludes() {
	e := new_env('excludes')
	e.init(['*.tmp', 'node_modules', '${e.src}/skip/*'])
	e.write('keep.txt', 'a')
	e.write('x.tmp', 'b')
	e.write('node_modules/m.js', 'c')
	e.write('deep/node_modules/m.js', 'd')
	e.write('skip/s.txt', 'e')
	e.write('deep/keep.txt', 'f')
	e.backup(1 * day)
	paths := e.rows('SELECT path FROM files ORDER BY path').map(it.get_string('PATH')!)
	assert paths == ['${e.src}/deep/keep.txt', '${e.src}/keep.txt']
}

fn test_mtime_rounds_to_microseconds() {
	assert round_ns_to_us(1_000_000_499) == 1_000_000
	assert round_ns_to_us(1_000_000_500) == 1_000_001
	assert round_ns_to_us(1_999_999_999) == 2_000_000
}

fn test_timestamp_round_trip() {
	us := i64(1_763_456_789_123_456)
	assert us_to_timestamp(us) == '2025-11-18 09:06:29.123456'
	assert time_to_us(us_to_time(us)) == us
}

fn test_ls_at_time() {
	e := new_env('ls')
	e.init([])
	e.write('a.txt', 'one')
	e.write('dir/b.txt', 'four')
	e.backup(1 * day)
	e.write('a.txt', 'three')
	os.rm(os.join_path(e.src, 'dir', 'b.txt'))!
	e.write('dir/c.txt', 'seven!!')
	e.backup(2 * day)

	names := fn (lines []string) []string {
		return lines.map(it.fields()[0] + ' ' + it.fields()[3])
	}

	assert names(ls(e.db, [e.src], 1 * day)!) == ['3 a.txt', '4 dir/']
	assert names(ls(e.db, [e.src], 2 * day)!) == ['5 a.txt', '7 dir/']
	assert names(ls(e.db, ['${e.src}/dir'], 1 * day)!) == ['4 b.txt']
	assert names(ls(e.db, ['${e.src}/dir'], 2 * day)!) == ['7 c.txt']
	ls(e.db, [e.src], 0) or {
		assert err.msg().contains('not in the backup')
		return
	}
	assert false
}

fn test_restore() {
	e := new_env('restore')
	e.init([])
	big := 'compress me '.repeat(10_000)
	a := e.write('a.txt', big)
	e.write('dir/b.txt', 'tiny')
	set_mtime(a, 1_700_000_000_123_456)!
	e.backup(1 * day)
	e.write('a.txt', 'newer')
	e.backup(2 * day)

	target := os.join_path(e.root, 'out')
	assert restore(e.db, e.src, target, 1 * day, fn (_ string) {})! == 2
	assert os.read_file(os.join_path(target, 'a.txt'))! == big
	assert os.read_file(os.join_path(target, 'dir', 'b.txt'))! == 'tiny'
	assert file_stat(os.join_path(target, 'a.txt'))!.mtime_us == 1_700_000_000_123_456

	// A file goes into the target under its own name.
	target2 := os.join_path(e.root, 'out2')
	assert restore(e.db, a, target2, 2 * day, fn (_ string) {})! == 1
	assert os.read_file(os.join_path(target2, 'a.txt'))! == 'newer'

	restore(e.db, e.src, target, 2 * day, fn (_ string) {}) or {
		assert err.msg().contains('already exists')
		return
	}
	assert false
}

fn test_stats() {
	e := new_env('stats')
	e.init(['*.tmp'])
	e.write('a.txt', 'compress me '.repeat(10_000))
	b := e.write('b.txt', 'tiny')
	e.backup(1 * day)
	os.rm(b)!
	e.backup(2 * day)

	lines := stats(e.db, 3 * day)!
	assert 'Exclude:        *.tmp' in lines
	assert 'Backups kept:   2' in lines
	assert 'Files:          1 (117.2 KiB)' in lines
	assert 'Deleted files:  1' in lines
	assert 'Versions:       3' in lines
	assert 'Objects:        2 (1 zipped)' in lines
}

fn test_human_size() {
	assert human_size(0) == '0 B'
	assert human_size(1023) == '1023 B'
	assert human_size(1536) == '1.5 KiB'
	assert human_size(i64(3) << 30) == '3.0 GiB'
}

fn test_parse_local_time() {
	// Round trip through the local time zone, whatever it is.
	us := parse_local_time('2026-07-04 12:30:15')!
	assert us % 1_000_000 == 999_999
	assert us_to_time(us).local().format_ss() == '2026-07-04 12:30:15'
	assert us_to_time(parse_local_time('2026-01-15 08:00')!).local().format_ss() == '2026-01-15 08:00:59'
	assert us_to_time(parse_local_time('2026-01-15')!).local().format_ss() == '2026-01-15 23:59:59'
}

fn (e Env) objects_on_disk() []string {
	mut found := []string{}
	for ab in os.ls(e.dest) or { [] } {
		for cd in os.ls(os.join_path(e.dest, ab)) or { [] } {
			found << os.ls(os.join_path(e.dest, ab, cd)) or { [] }
		}
	}
	found.sort()
	return found
}

fn (e Env) versions(name string) []int {
	return e.rows("SELECT version FROM files WHERE path = '${os.join_path(e.src, name)}' ORDER BY version").map(it.get_int('VERSION') or { panic(err) })
}

fn test_parse_limits() {
	assert parse_max_versions('unlimited')! == unlimited
	assert parse_max_versions('0')! == 0
	assert parse_max_versions('12')! == 12
	parse_max_versions('-1') or { assert err.msg().contains('invalid') }
	parse_max_versions('x') or { assert err.msg().contains('invalid') }

	assert parse_max_size('unlimited')! == unlimited
	assert parse_max_size('1000')! == 1000
	assert parse_max_size('2K')! == 2048
	assert parse_max_size('500G')! == i64(500) << 30
	assert parse_max_size('500GB')! == i64(500) << 30
	assert parse_max_size('1.5TiB')! == i64(3) << 39
	assert parse_max_size('10mb')! == i64(10) << 20
	parse_max_size('G') or { assert err.msg().contains('invalid') }
	parse_max_size('-5G') or { assert err.msg().contains('invalid') }
	parse_max_size('5X') or { assert err.msg().contains('invalid') }
}

fn test_set_limits() {
	e := new_env('limits')
	e.init([])
	set_limits(e.db, 3, none)!
	mut db := vsql.open(e.db)!
	mut c := read_config(mut db)!
	db.close()
	assert c.max_versions == 3
	assert c.max_size == unlimited

	set_limits(e.db, none, 1 << 20)!
	db = vsql.open(e.db)!
	c = read_config(mut db)!
	db.close()
	assert c.max_versions == 3
	assert c.max_size == 1 << 20

	set_limits(e.db, unlimited, unlimited)!
	db = vsql.open(e.db)!
	c = read_config(mut db)!
	db.close()
	assert c.max_versions == unlimited
	assert c.max_size == unlimited
}

fn test_max_versions_prunes_old_versions_and_objects() {
	e := new_env('max_versions')
	e.init([])
	for i in 1 .. 6 {
		e.write('a.jpg', 'version ${i}')
		e.backup(i * day)
	}
	assert e.versions('a.jpg') == [1, 2, 3, 4, 5]
	assert e.objects_on_disk().len == 5

	set_limits(e.db, 1, none)!
	e.write('a.jpg', 'version 6')
	stats := e.backup(6 * day)
	assert stats.changed == 1
	assert stats.pruned == 3 + 1 // v1-v3 before the backup and v4 after it

	// Version numbers keep going, they aren't reused.
	assert e.versions('a.jpg') == [5, 6]
	assert e.rows('SELECT * FROM objects').len == 2
	assert e.objects_on_disk().len == 2

	// A delete is a version too.
	os.rm(os.join_path(e.src, 'a.jpg'))!
	e.backup(7 * day)
	assert e.versions('a.jpg') == [6, 7]
	assert e.objects_on_disk().len == 1

	set_limits(e.db, 0, none)!
	e.backup(8 * day)
	assert e.versions('a.jpg') == [7]
	assert e.objects_on_disk().len == 0
	assert e.rows('SELECT * FROM objects').len == 0
}

fn test_max_size_prunes_oldest_previous_versions() {
	e := new_env('max_size_prune')
	e.init([])
	e.write('a.jpg', 'a'.repeat(1000))
	e.write('b.jpg', 'b'.repeat(1000))
	e.backup(1 * day)
	e.write('a.jpg', 'A'.repeat(1000))
	e.backup(2 * day)
	e.write('b.jpg', 'B'.repeat(1000))
	e.backup(3 * day)
	assert e.objects_on_disk().len == 4

	// Only the oldest previous version (a.jpg v1) has to go to fit 3000 bytes.
	set_limits(e.db, none, 3000)!
	assert e.backup(4 * day).pruned == 1
	assert e.versions('a.jpg') == [2]
	assert e.versions('b.jpg') == [1, 2]

	// Latest versions are never pruned, even when they don't fit.
	set_limits(e.db, none, 100)!
	assert e.backup(5 * day).pruned == 1
	assert e.versions('a.jpg') == [2]
	assert e.versions('b.jpg') == [2]
	assert e.objects_on_disk().len == 2
}

fn test_max_size_stops_backup_cleanly() {
	e := new_env('max_size_stop')
	e.init([])
	set_limits(e.db, none, 2500)!
	e.write('1.jpg', '1'.repeat(1000))
	e.write('2.jpg', '2'.repeat(1000))
	e.write('3.jpg', '3'.repeat(1000))
	e.write('4.jpg', '4'.repeat(1000))

	backup(e.db, 1 * day, fn (_ string) {}) or {
		assert err.msg().contains('max size reached')
		assert err.msg().contains('3.jpg')
		assert err.msg().contains('2 files were backed up')
	}
	// The first two are complete, nothing of 3.jpg is left behind.
	assert e.rows('SELECT path FROM files ORDER BY path').map(os.base(it.get_string('PATH')!)) == [
		'1.jpg',
		'2.jpg',
	]
	assert e.rows('SELECT * FROM objects').len == 2
	assert e.objects_on_disk().len == 2
	assert !e.objects_on_disk().any(it.ends_with('.tmp'))

	// After the device is expanded, backup carries on where it stopped.
	set_limits(e.db, none, unlimited)!
	assert e.backup(2 * day) == BackupStats{
		new:       2
		unchanged: 2
	}
	assert e.objects_on_disk().len == 4
	assert e.versions('3.jpg') == [1]
}
