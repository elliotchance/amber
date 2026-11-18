module main

import os
import hash.crc32
import crypto.sha256
import compress.deflate

// Files with these extensions are already compressed, so they're stored as is.
const compressed_extensions = ['.7z', '.aac', '.apk', '.avi', '.br', '.bz2', '.cab', '.dmg', '.docx',
	'.epub', '.flac', '.gif', '.gz', '.heic', '.heif', '.jar', '.jpeg', '.jpg', '.lz', '.lz4',
	'.lzma', '.m4a', '.m4v', '.mkv', '.mov', '.mp3', '.mp4', '.odp', '.ods', '.odt', '.ogg', '.opus',
	'.png', '.pptx', '.rar', '.tbz', '.tgz', '.txz', '.webm', '.webp', '.xlsx', '.xz', '.zip',
	'.zst']

// Larger files are stored as is. Compression happens in memory, and plain ZIP
// (without ZIP64) can't hold anything over 4 GiB anyway.
const max_compress_size = i64(1) << 30

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

fn object_path(destination string, sha string) string {
	return os.join_path(destination, sha[0..2], sha[2..4], sha)
}

fn should_compress(path string, size i64, blksize i64) bool {
	if size < blksize || size > max_compress_size {
		return false
	}
	return os.file_ext(path).to_lower() !in compressed_extensions
}

// SpaceLimitError is returned when storing an object would take the
// destination over max_size.
struct SpaceLimitError {
	Error
	path   string
	needed i64
	room   i64
}

fn (e SpaceLimitError) msg() string {
	return 'max size reached: ${e.path} needs ${human_size(e.needed)} but only ${human_size(e.room)} is left'
}

// store_object copies path into the destination as sha and returns the stored
// size and compression. room is how many more bytes can be stored (or
// unlimited); nothing is written if the object wouldn't fit. The object is
// written to a temporary file first, which is removed if anything fails, so a
// failed copy (including a full disk) never leaves a partial object behind.
fn store_object(path string, sha string, size i64, destination string, room i64) !(i64, string) {
	mut data := []u8{}
	mut compression := 'NONE'
	mut stored_size := size
	if should_compress(path, size, destination_block_size(destination)) {
		original := os.read_bytes(path)!
		mut zipped := zip_single_entry(sha, original)!
		// Some files don't get smaller, so it's not worth zipping them.
		if zipped.len < original.len {
			data = unsafe { zipped }
			compression = 'ZIP'
			stored_size = zipped.len
		}
	}
	if room != unlimited && stored_size > room {
		return SpaceLimitError{
			path:   path
			needed: stored_size
			room:   room
		}
	}

	target := object_path(destination, sha)
	tmp := target + '.tmp'
	os.mkdir_all(os.dir(target))!
	write_object(path, tmp, compression, data) or {
		os.rm(tmp) or {}
		return err
	}
	os.rename(tmp, target) or {
		os.rm(tmp) or {}
		return err
	}
	return i64(os.file_size(target)), compression
}

fn write_object(path string, tmp string, compression string, data []u8) ! {
	if compression == 'ZIP' {
		os.write_file_array(tmp, data)!
	} else {
		os.cp(path, tmp)!
	}
}

fn destination_block_size(destination string) i64 {
	st := file_stat(destination) or { return 4096 }
	return if st.blksize > 0 { st.blksize } else { 4096 }
}

// zip_single_entry builds a ZIP archive that holds data as one entry called
// name, so any unzip tool can restore an object.
fn zip_single_entry(name string, data []u8) ![]u8 {
	compressed := deflate.compress_raw(data)!
	crc := crc32.sum(data)

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
	start := 30 + int(get_u16(data, 26)) + int(get_u16(data, 28))
	if start + csize > data.len {
		return error('truncated ZIP object')
	}
	return deflate.decompress_raw_with_consumed(data[start..start + csize])!.decoded
}

fn get_u16(data []u8, at int) u16 {
	return u16(data[at]) | (u16(data[at + 1]) << 8)
}

fn get_u32(data []u8, at int) u32 {
	return u32(get_u16(data, at)) | (u32(get_u16(data, at + 2)) << 16)
}
