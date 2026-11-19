module main

import os

// Files are split into chunks with FastCDC (content-defined chunking). Cut
// points depend on the bytes around them, not on their offset, so inserting or
// removing bytes only changes the chunks around the edit: the cut points after
// it line up again and those chunks are shared with the previous version.
//
// Chunks average 4 MiB and are between 1 MiB and 16 MiB, except the last chunk
// of a file, which can be smaller. A file smaller than min_chunk is one chunk.
const min_chunk = 1 << 20
const avg_chunk = 4 << 20
const max_chunk = 16 << 20

// The gear hash shifts left, so its top bits depend on the last 64 bytes. A cut
// happens when the masked top bits are all zero. Before avg_chunk the mask has
// two more bits than log2(avg_chunk) (cuts are less likely), after it two fewer
// (more likely), which keeps chunk sizes close to the average ("normalized
// chunking" from the FastCDC paper).
const mask_small = ((u64(1) << 24) - 1) << 40
const mask_large = ((u64(1) << 20) - 1) << 44

// gear is a fixed table of random numbers. It must never change: it decides
// where files are cut, so a different table would share no chunks with
// existing backups (they would still restore, but nothing would deduplicate).
const gear = make_gear()

fn make_gear() []u64 {
	// splitmix64 from a fixed seed.
	mut table := []u64{len: 256}
	mut x := u64(0x616d626572) // "amber"
	for i in 0 .. 256 {
		x += 0x9e3779b97f4a7c15
		mut z := x
		z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
		z = (z ^ (z >> 27)) * 0x94d049bb133111eb
		table[i] = z ^ (z >> 31)
	}
	return table
}

// cut_point returns the length of the first chunk of data. data must hold at
// least max_chunk bytes unless it's the end of the file.
fn cut_point(data []u8) int {
	mut n := data.len
	if n <= min_chunk {
		return n
	}
	if n > max_chunk {
		n = max_chunk
	}
	normal := if n < avg_chunk { n } else { avg_chunk }
	mut h := u64(0)
	mut i := min_chunk
	for i < normal {
		h = (h << 1) + gear[data[i]]
		if h & mask_small == 0 {
			return i + 1
		}
		i++
	}
	for i < n {
		h = (h << 1) + gear[data[i]]
		if h & mask_large == 0 {
			return i + 1
		}
		i++
	}
	return n
}

// Chunker reads a file and returns it one chunk at a time, holding at most
// two max_chunk buffers in memory.
struct Chunker {
mut:
	f       os.File
	buf     []u8
	start   int // where the next chunk starts in buf
	end     int // how much of buf is filled
	eof     bool
	emitted bool
}

fn new_chunker(path string) !Chunker {
	return Chunker{
		f:   os.open(path)!
		buf: []u8{len: 2 * max_chunk}
	}
}

fn (mut c Chunker) close() {
	c.f.close()
}

// next returns the next chunk and true, or false at the end of the file. An
// empty file is one empty chunk. The chunk is only valid until the next call.
fn (mut c Chunker) next() !([]u8, bool) {
	c.fill()!
	if c.start == c.end {
		if c.emitted {
			return []u8{}, false
		}
		c.emitted = true
		return []u8{}, true
	}
	n := cut_point(c.buf[c.start..c.end])
	chunk := unsafe { c.buf[c.start..c.start + n] }
	c.start += n
	c.emitted = true
	return chunk, true
}

// fill makes sure at least max_chunk bytes are available after start (unless
// the file ends sooner), moving what's left to the front of buf first.
fn (mut c Chunker) fill() ! {
	if c.eof || c.end - c.start >= max_chunk {
		return
	}
	if c.start > 0 {
		copy(mut c.buf, c.buf[c.start..c.end])
		c.end -= c.start
		c.start = 0
	}
	for c.end < c.buf.len {
		mut window := unsafe { c.buf[c.end..] }
		n := c.f.read(mut window) or {
			if err is os.Eof {
				c.eof = true
				break
			}
			return err
		}
		if n == 0 {
			c.eof = true
			break
		}
		c.end += n
	}
}
