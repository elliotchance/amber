module main

#flag -I @VMODROOT/c
#flag -lz
#include "amber_zlib.h"

fn C.amber_deflate(input &u8, in_len u32, output &u8, out_cap u32) i64
fn C.amber_inflate(input &u8, in_len u32, output &u8, out_cap u32) i64
fn C.amber_crc32(data &u8, len u32) u32

// deflate_smaller compresses data with zlib's raw deflate, or returns none if
// that wouldn't make it smaller. The system zlib is used because it compresses
// a chunk in one call with fixed working memory.
fn deflate_smaller(data []u8) ?[]u8 {
	if data.len == 0 {
		return none
	}
	mut out := []u8{len: data.len}
	n := C.amber_deflate(data.data, u32(data.len), out.data, u32(out.len))
	if n < 0 {
		return none
	}
	return out[..int(n)]
}

// inflate_chunk decompresses raw deflate data that was size bytes originally.
fn inflate_chunk(data []u8, size int) ![]u8 {
	mut out := []u8{len: size}
	n := C.amber_inflate(data.data, u32(data.len), out.data, u32(size))
	if n != size {
		return error('corrupt compressed data')
	}
	return out
}

fn crc32_of(data []u8) u32 {
	return C.amber_crc32(data.data, u32(data.len))
}
