module main

import time

#flag -I @VMODROOT/c
#include "amber_stat.h"

fn C.amber_stat(path &char, size &i64, mtime_ns &i64, blksize &i64) int
fn C.amber_set_mtime(path &char, mtime_us i64) int
fn C.amber_local_to_unix(year int, month int, day int, hour int, minute int, second int) i64

struct FileStat {
	size     i64
	mtime_us i64 // modified time, rounded to the nearest microsecond
	blksize  i64
}

// file_stat returns the modified time of path rounded to the nearest
// microsecond, since that's what vsql stores. macOS (and most Linux file
// systems) record nanoseconds.
fn file_stat(path string) !FileStat {
	mut size := i64(0)
	mut mtime_ns := i64(0)
	mut blksize := i64(0)
	if C.amber_stat(&char(path.str), &size, &mtime_ns, &blksize) != 0 {
		return error('cannot stat ${path}')
	}
	return FileStat{
		size:     size
		mtime_us: round_ns_to_us(mtime_ns)
		blksize:  blksize
	}
}

fn round_ns_to_us(ns i64) i64 {
	if ns >= 0 {
		return (ns + 500) / 1000
	}
	return -((-ns + 500) / 1000)
}

// set_mtime sets the modified (and access) time of path, in microseconds since
// the UNIX epoch.
fn set_mtime(path string, mtime_us i64) ! {
	if C.amber_set_mtime(&char(path.str), mtime_us) != 0 {
		return error('cannot set the modified time of ${path}')
	}
}

// local_to_unix converts t, a time in the local time zone, to seconds since the
// UNIX epoch.
fn local_to_unix(t time.Time) i64 {
	return C.amber_local_to_unix(t.year, t.month, t.day, t.hour, t.minute, t.second)
}
