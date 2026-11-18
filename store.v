module main

import os
import crypto.sha256

// default_no_compress is the no_compress patterns of a new backup: formats
// that are already compressed, so compressing them again wastes time.
const default_no_compress = ['*.7z', '*.aac', '*.apk', '*.avi', '*.br', '*.bz2', '*.cab', '*.dmg',
	'*.docx', '*.epub', '*.flac', '*.gif', '*.gz', '*.heic', '*.heif', '*.jar', '*.jpeg', '*.jpg',
	'*.lz', '*.lz4', '*.lzma', '*.m4a', '*.m4v', '*.mkv', '*.mov', '*.mp3', '*.mp4', '*.odp', '*.ods',
	'*.odt', '*.ogg', '*.opus', '*.png', '*.pptx', '*.rar', '*.tbz', '*.tgz', '*.txz', '*.webm',
	'*.webp', '*.xlsx', '*.xz', '*.zip', '*.zst']

// StoreOptions decide how chunks are stored.
struct StoreOptions {
	blksize     i64      // the block size of the backup folder
	no_compress []string // patterns of files that are stored as is
}

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

// should_compress is true unless the chunk is smaller than a block (it can't
// use less space) or its file matches a no_compress pattern (ignoring case). A
// zipped chunk is still only kept if it's smaller.
fn should_compress(path string, size i64, opts StoreOptions) bool {
	if size < opts.blksize {
		return false
	}
	return !matches_any(path.to_lower(), opts.no_compress.map(it.to_lower()))
}

// encode_chunk returns the bytes to store for a chunk and their compression.
// Chunks are at most max_chunk, so this happens in memory. A compressed chunk
// is a standard ZIP archive with one entry, so `unzip -p` can read it.
fn encode_chunk(path string, sha string, chunk []u8, opts StoreOptions) !([]u8, string) {
	if should_compress(path, chunk.len, opts) {
		if compressed := deflate_smaller(chunk) {
			zipped := zip_single_entry(sha, chunk, compressed)
			if zipped.len < chunk.len {
				return zipped, 'ZIP'
			}
		}
	}
	return chunk, 'NONE'
}

// write_object writes data as the object sha. It goes to a temporary file
// first, which is removed if anything fails (including a full disk), so a
// failed write never leaves a partial object behind.
fn write_object(dir string, sha string, data []u8) ! {
	target := object_path(dir, sha)
	tmp := target + '.tmp'
	os.mkdir_all(os.dir(target)) or { return at(.write_object, err) }
	os.write_file_array(tmp, data) or {
		os.rm(tmp) or {}
		remove_empty_parents(target)
		return at(.write_object, err)
	}
	os.rename(tmp, target) or {
		os.rm(tmp) or {}
		return at(.write_object, err)
	}
}

// remove_object removes an object that no row refers to.
fn remove_object(dir string, sha string) {
	path := object_path(dir, sha)
	os.rm(path) or {}
	remove_empty_parents(path)
}

// read_object returns the original contents of the object sha and checks them
// against sha.
fn read_object(dir string, sha string, compression string) ![]u8 {
	path := object_path(dir, sha)
	if !os.is_file(path) {
		return stage_error(.missing_object, 'object ${sha} is missing')
	}
	stored := os.read_bytes(path) or { return at(.missing_object, err) }
	data := if compression == 'ZIP' {
		unzip_single_entry(stored) or {
			return stage_error(.decompress, 'object ${sha}: ${err.msg()}')
		}
	} else {
		stored
	}
	if sha256.sum(data).hex() != sha {
		return stage_error(.checksum, 'object ${sha} does not match its SHA-256')
	}
	return data
}

fn check_room(path string, needed i64, room i64) ! {
	if room != unlimited && needed > room {
		if room <= 0 {
			return stage_error(.no_space, 'max size reached: ${path} needs ${human_size(needed)} more but the backup is ${human_size(-room)} over the max size')
		}
		return stage_error(.no_space, 'max size reached: ${path} needs ${human_size(needed)} more but only ${human_size(room)} is left')
	}
}

// zip_single_entry builds a ZIP archive that holds data (already deflated as
// compressed) as one entry called name, so any unzip tool can restore an
// object.
fn zip_single_entry(name string, data []u8, compressed []u8) []u8 {
	crc := crc32_of(data)

	mut out := []u8{cap: compressed.len + 2 * name.len + 100}
	// Local file header.
	put_u32(mut out, 0x04034b50)
	put_u16(mut out, 20) // version needed to extract
	put_u16(mut out, 0) // flags
	put_u16(mut out, 8) // method: deflate
	put_u16(mut out, 0) // modified time
	put_u16(mut out, 0x21) // modified date: 1980-01-01
	put_u32(mut out, crc)
	put_u32(mut out, u32(compressed.len))
	put_u32(mut out, u32(data.len))
	put_u16(mut out, u16(name.len))
	put_u16(mut out, 0) // extra field length
	out << name.bytes()
	out << compressed

	// Central directory.
	central_offset := out.len
	put_u32(mut out, 0x02014b50)
	put_u16(mut out, 20) // version made by
	put_u16(mut out, 20) // version needed to extract
	put_u16(mut out, 0) // flags
	put_u16(mut out, 8) // method: deflate
	put_u16(mut out, 0) // modified time
	put_u16(mut out, 0x21) // modified date
	put_u32(mut out, crc)
	put_u32(mut out, u32(compressed.len))
	put_u32(mut out, u32(data.len))
	put_u16(mut out, u16(name.len))
	put_u16(mut out, 0) // extra field length
	put_u16(mut out, 0) // comment length
	put_u16(mut out, 0) // disk number
	put_u16(mut out, 0) // internal attributes
	put_u32(mut out, 0) // external attributes
	put_u32(mut out, 0) // offset of the local header
	out << name.bytes()
	central_size := out.len - central_offset

	// End of central directory.
	put_u32(mut out, 0x06054b50)
	put_u16(mut out, 0) // this disk
	put_u16(mut out, 0) // disk with the central directory
	put_u16(mut out, 1) // entries on this disk
	put_u16(mut out, 1) // total entries
	put_u32(mut out, u32(central_size))
	put_u32(mut out, u32(central_offset))
	put_u16(mut out, 0) // comment length

	return out
}

fn put_u16(mut out []u8, v u16) {
	out << u8(v)
	out << u8(v >> 8)
}

fn put_u32(mut out []u8, v u32) {
	put_u16(mut out, u16(v))
	put_u16(mut out, u16(v >> 16))
}

// unzip_single_entry returns the contents of the entry in a ZIP archive made by
// zip_single_entry.
fn unzip_single_entry(data []u8) ![]u8 {
	if data.len < 30 || get_u32(data, 0) != 0x04034b50 || get_u16(data, 8) != 8 {
		return error('not a ZIP object')
	}
	csize := int(get_u32(data, 18))
	size := int(get_u32(data, 22))
	start := 30 + int(get_u16(data, 26)) + int(get_u16(data, 28))
	if start + csize > data.len || size > max_chunk {
		return error('truncated ZIP object')
	}
	return inflate_chunk(data[start..start + csize], size)!
}

fn get_u16(data []u8, pos int) u16 {
	return u16(data[pos]) | (u16(data[pos + 1]) << 8)
}

fn get_u32(data []u8, pos int) u32 {
	return u32(get_u16(data, pos)) | (u32(get_u16(data, pos + 2)) << 16)
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
