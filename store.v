module main

import os
import crypto.sha256

// Files with these extensions are already compressed, so they're stored as is.
const compressed_extensions = ['.7z', '.aac', '.apk', '.avi', '.br', '.bz2', '.cab', '.dmg', '.docx',
	'.epub', '.flac', '.gif', '.gz', '.heic', '.heif', '.jar', '.jpeg', '.jpg', '.lz', '.lz4',
	'.lzma', '.m4a', '.m4v', '.mkv', '.mov', '.mp3', '.mp4', '.odp', '.ods', '.odt', '.ogg', '.opus',
	'.png', '.pptx', '.rar', '.tbz', '.tgz', '.txz', '.webm', '.webp', '.xlsx', '.xz', '.zip',
	'.zst']

const hash_buffer_size = 1 << 20

fn sha256_file(path string) !string {
	mut f := os.open(path)!
	defer {
		f.close()
	}
	mut d := sha256.new()
	mut buf := []u8{len: hash_buffer_size}
	for {
		n := f.read(mut buf) or { break }
		if n == 0 {
			break
		}
		d.write(buf[..n])!
	}
	return d.sum([]u8{}).hex()
}

fn object_path(dir string, sha string) string {
	return os.join_path(dir, sha[0..2], sha[2..4], sha)
}

// should_compress is true unless the file is smaller than a block (it can't
// use less space) or is already compressed. A zipped object is still only kept
// if it's smaller than the original.
fn should_compress(path string, size i64, blksize i64) bool {
	if size < blksize {
		return false
	}
	return os.file_ext(path).to_lower() !in compressed_extensions
}

// store_object copies path into the backup folder dir as sha and returns the
// stored size and compression. room is how many more bytes can be stored (or
// unlimited); the object is not kept if it wouldn't fit.
//
// Files are zipped with the zip command, which streams, so there's no limit on
// size (it switches to ZIP64 over 4 GiB). Everything is written to a temporary
// file first and removed if anything fails (including a full disk), so a
// failed copy never leaves a partial object behind.
fn store_object(path string, sha string, size i64, dir string, room i64) !(i64, string) {
	target := object_path(dir, sha)
	tmp := target + '.tmp'
	os.mkdir_all(os.dir(target)) or { return at(.write_object, err) }
	os.rm(tmp) or {}

	stored_size, compression := write_object(path, tmp, size, dir, room) or {
		os.rm(tmp) or {}
		remove_empty_parents(target)
		return err
	}
	os.rename(tmp, target) or {
		os.rm(tmp) or {}
		return at(.write_object, err)
	}
	return stored_size, compression
}

fn write_object(path string, tmp string, size i64, dir string, room i64) !(i64, string) {
	if should_compress(path, size, block_size(dir)) {
		zip_file(path, tmp)!
		zipped_size := i64(os.file_size(tmp))
		if zipped_size < size {
			check_room(path, zipped_size, room)!
			return zipped_size, 'ZIP'
		}
		// Zipping didn't make it smaller, so store it as is.
		os.rm(tmp) or { return at(.write_object, err) }
	}

	check_room(path, size, room)!
	os.cp(path, tmp) or { return at(.write_object, err) }
	return i64(os.file_size(tmp)), 'NONE'
}

fn check_room(path string, needed i64, room i64) ! {
	if room != unlimited && needed > room {
		if room <= 0 {
			return stage_error(.no_space, 'max size reached: ${path} needs ${human_size(needed)} but the backup is ${human_size(-room)} over the max size')
		}
		return stage_error(.no_space, 'max size reached: ${path} needs ${human_size(needed)} but only ${human_size(room)} is left')
	}
}

// restore_object writes the original contents of an object to out, which must
// not exist yet.
fn restore_object(object string, compression string, out string) ! {
	if !os.is_file(object) {
		return stage_error(.missing_object, 'object ${object} is missing')
	}
	if compression != 'ZIP' {
		os.cp(object, out) or { return at(.write_target, err) }
		return
	}

	// unzip can only write an entry to a folder (without going through a
	// shell), so it goes into a temporary folder next to out and is moved
	// from there. The folder is on the same file system, so the move is
	// just a rename.
	tmp_dir := out + '.amber-tmp'
	os.mkdir(tmp_dir) or { return at(.write_target, err) }
	defer {
		os.rmdir_all(tmp_dir) or {}
	}
	run_command(.decompress, ['unzip', '-q', '-j', '-o', object, '-d', tmp_dir])!
	entries := os.ls(tmp_dir) or { return at(.decompress, err) }
	if entries.len != 1 {
		return stage_error(.decompress, 'object ${object} has ${entries.len} entries, expected 1')
	}
	os.rename(os.join_path(tmp_dir, entries[0]), out) or { return at(.write_target, err) }
}

// zip_file zips path into a new archive at zip_path, which holds one entry.
fn zip_file(path string, zip_path string) ! {
	// -j stores just the file name, -X leaves out extra file attributes, and
	// -q is quiet. zip_path ends in ".tmp", so zip won't add ".zip" to it.
	run_command(.compress, ['zip', '-q', '-j', '-X', zip_path, path])!
}

// run_command runs a command without a shell. A failure has the given stage, unless
// the command isn't installed.
fn run_command(stage Stage, args []string) ! {
	os.find_abs_path_of_executable(args[0]) or {
		return stage_error(.missing_tool, '${args[0]} is not installed, it is needed to store and restore compressed files')
	}
	result := os.exec(args)
	if result.exit_code != 0 {
		return stage_error(stage, '${args[0]} failed (exit ${result.exit_code}): ${result.output.trim_space()}')
	}
}

// remove_empty_parents removes the AB/CD folders of an object if they're
// empty. os.rmdir fails (and does nothing) if they're not.
fn remove_empty_parents(object string) {
	os.rmdir(os.dir(object)) or {}
	os.rmdir(os.dir(os.dir(object))) or {}
}

fn block_size(dir string) i64 {
	st := file_stat(dir) or { return 4096 }
	return if st.blksize > 0 { st.blksize } else { 4096 }
}
