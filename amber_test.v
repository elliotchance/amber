module main

import os
import crypto.sha256
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
	// The backup folder is made by init.
	backup_dir := os.join_path(os.real_path(root), 'backup')
	return Env{
		root: os.real_path(root)
		src:  os.real_path(src)
		dest: backup_dir
		db:   backup_dir
	}
}

fn (e Env) init(excludes []string) {
	create_database(e.dest, Config{
		includes: [e.src]
		excludes: excludes
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
	mut db := vsql.open(db_file(e.dest)) or { panic(err) }
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
	create_database(e.dest, Config{ includes: [e.src] }) or {
		assert err.msg().contains('already exists')
		return
	}
	assert false
}

fn test_backup_needs_existing_file() {
	backup('/nonexistent', 0, fn (_ string) {}) or {
		assert err.msg().contains('is not an amber backup folder')
		assert exit_code(err) == 3
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

	assert read_object(e.dest, zipped.get_string('SHA256')!, 'ZIP')!.bytestr() == big
	// The zip command's own tools can read it too.
	assert os.execute('unzip -p ${stored}').output == big
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
	assert 'Chunks:         2 (1 zipped, 4.0 MiB average)' in lines
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
	mut db := vsql.open(db_file(e.dest))!
	mut c := read_config(mut db, e.dest)!
	db.close()
	assert c.max_versions == 3
	assert c.max_size == unlimited

	set_limits(e.db, none, 1 << 20)!
	db = vsql.open(db_file(e.dest))!
	c = read_config(mut db, e.dest)!
	db.close()
	assert c.max_versions == 3
	assert c.max_size == 1 << 20

	set_limits(e.db, unlimited, unlimited)!
	db = vsql.open(db_file(e.dest))!
	c = read_config(mut db, e.dest)!
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

fn test_exit_codes() {
	assert exit_code(error('plain')) == 1
	assert exit_code(at(.read_index, error('x'))) == 7
	// The innermost stage wins.
	assert exit_code(at(.write_index, at(.compress, error('x')))) == 11

	mut failed := 0
	e := new_env('codes')
	e.init([])
	create_database(e.dest, Config{ includes: [e.src] }) or {
		failed++
		assert exit_code(err) == 4
	}
	parse_max_size('lots') or {
		failed++
		assert exit_code(err) == 2
	}
	parse_local_time('soon') or {
		failed++
		assert exit_code(err) == 2
	}
	ls(e.dest, [e.src], 1 * day) or {
		failed++
		assert exit_code(err) == 20
	}

	big := 'compress me '.repeat(10_000)
	a := e.write('a.txt', big)
	e.backup(1 * day)
	restore(e.dest, e.src, e.root, 1 * day, fn (_ string) {}) or {
		failed++
		assert exit_code(err) == 21
	}

	// A damaged object fails its checksum, a missing one is reported as missing.
	sha := sha256_file(a)!
	os.write_file(object_path(e.dest, sha), 'garbage')!
	restore(e.dest, e.src, os.join_path(e.root, 'r1'), 1 * day, fn (_ string) {}) or {
		failed++
		assert exit_code(err) == 23 // it's not a ZIP anymore
	}
	os.rm(object_path(e.dest, sha))!
	restore(e.dest, e.src, os.join_path(e.root, 'r2'), 1 * day, fn (_ string) {}) or {
		failed++
		assert exit_code(err) == 22
	}

	set_limits(e.dest, none, 10)!
	e.write('b.txt', big + big)
	backup(e.dest, 2 * day, fn (_ string) {}) or {
		failed++
		assert exit_code(err) == 13
	}
	assert failed == 8
}

fn test_checksum_mismatch() {
	e := new_env('checksum')
	e.init([])
	a := e.write('a.jpg', 'x'.repeat(10_000))
	e.backup(1 * day)
	// Same size, different content: only the checksum can catch it.
	os.write_file(object_path(e.dest, sha256_file(a)!), 'y'.repeat(10_000))!
	restore(e.dest, e.src, os.join_path(e.root, 'out'), 1 * day, fn (_ string) {}) or {
		assert exit_code(err) == 24
		return
	}
	assert false
}

// random_bytes is repeatable pseudo-random data (xorshift64), which doesn't
// compress and has no repeats, so chunk boundaries are realistic.
fn random_bytes(n int, seed u64) []u8 {
	mut out := []u8{len: n}
	mut x := seed
	for i in 0 .. n {
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
		out[i] = u8(x >> 32)
	}
	return out
}

fn chunk_sizes(data []u8) []int {
	mut sizes := []int{}
	mut start := 0
	for start < data.len {
		n := cut_point(data[start..])
		sizes << n
		start += n
	}
	return sizes
}

fn chunk_hashes(data []u8) []string {
	mut hashes := []string{}
	mut start := 0
	for start < data.len {
		n := cut_point(data[start..])
		hashes << sha256.sum(data[start..start + n]).hex()
		start += n
	}
	return hashes
}

fn test_chunk_sizes() {
	data := random_bytes(64 << 20, 1)
	sizes := chunk_sizes(data)
	assert arrays_sum(sizes) == data.len
	for s in sizes[..sizes.len - 1] {
		assert s >= min_chunk
		assert s <= max_chunk
	}
	// Averages about 4 MiB.
	avg := data.len / sizes.len
	assert avg > 2 << 20 && avg < 8 << 20, 'average ${avg}'
	// Small data is one chunk.
	assert chunk_sizes(random_bytes(1000, 2)) == [1000]
	// The same data always cuts in the same places.
	assert chunk_sizes(data) == sizes
}

fn arrays_sum(a []int) int {
	mut n := 0
	for x in a {
		n += x
	}
	return n
}

fn test_insert_only_changes_nearby_chunks() {
	data := random_bytes(40 << 20, 3)
	before := chunk_hashes(data)

	mut edited := []u8{}
	edited << data[..100]
	edited << 'a new ID3 tag that is longer than before'.bytes()
	edited << data[100..]
	after := chunk_hashes(edited)

	shared := after.filter(it in before).len
	assert shared >= after.len - 1, '${shared} of ${after.len} chunks shared'
}

fn test_chunked_file_round_trip() {
	e := new_env('chunked')
	e.init([])
	data := random_bytes(12 << 20, 4)
	path := e.write('big.bin', data.bytestr())
	e.backup(1 * day)

	rows := e.rows('SELECT sha256, manifest FROM files')
	assert rows.len == 1
	manifest := rows[0].get_string('MANIFEST')!
	assert manifest.len == 64
	assert rows[0].get_string('SHA256')! == sha256_file(path)!
	parts := e.rows('SELECT seq, sha256 FROM parts ORDER BY seq')
	assert parts.len == chunk_hashes(data).len
	assert parts.map(it.get_string('SHA256')!) == chunk_hashes(data)
	assert e.objects_on_disk().len == parts.len

	// Same-length edit at the start: only the first chunk is new.
	mut edited := data.clone()
	edited[10] ^= 0xff
	os.write_file_array(path, edited)!
	e.backup(2 * day)
	assert e.objects_on_disk().len == parts.len + 1

	out := os.join_path(e.root, 'out')
	restore(e.dest, e.src, out, 1 * day, fn (_ string) {})!
	assert os.read_bytes(os.join_path(out, 'big.bin'))! == data
	out2 := os.join_path(e.root, 'out2')
	restore(e.dest, e.src, out2, 2 * day, fn (_ string) {})!
	assert os.read_bytes(os.join_path(out2, 'big.bin'))! == edited
}

fn test_prune_chunked_versions() {
	e := new_env('prune_chunks')
	e.init([])
	data := random_bytes(12 << 20, 5)
	path := e.write('big.bin', data.bytestr())
	e.backup(1 * day)
	n := e.objects_on_disk().len

	mut edited := data.clone()
	edited[10] ^= 0xff
	os.write_file_array(path, edited)!
	e.backup(2 * day)
	assert e.objects_on_disk().len == n + 1

	// Dropping version 1 frees only its first chunk, the rest are shared.
	set_limits(e.dest, 0, none)!
	assert e.backup(3 * day).pruned == 1
	assert e.objects_on_disk().len == n
	assert e.rows('SELECT * FROM parts').len == n
	out := os.join_path(e.root, 'out')
	restore(e.dest, e.src, out, 3 * day, fn (_ string) {})!
	assert os.read_bytes(os.join_path(out, 'big.bin'))! == edited

	// Once the file is deleted and pruned, nothing is left.
	os.rm(path)!
	e.backup(4 * day)
	e.backup(5 * day)
	assert e.objects_on_disk().len == 0
	assert e.rows('SELECT * FROM parts').len == 0
}

fn test_max_size_mid_file_leaves_nothing() {
	e := new_env('mid_file')
	e.init([])
	set_limits(e.dest, none, 5 << 20)!
	e.write('big.bin', random_bytes(12 << 20, 6).bytestr())
	backup(e.dest, 1 * day, fn (_ string) {}) or {
		assert exit_code(err) == 13
		assert e.objects_on_disk().len == 0
		assert e.rows('SELECT * FROM objects').len == 0
		assert e.rows('SELECT * FROM files').len == 0
		return
	}
	assert false
}
