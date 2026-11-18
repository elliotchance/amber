module main

import os

// Walker finds every file under the include paths that isn't excluded.
struct Walker {
	includes []string
	excludes []string
	// skip is paths amber must never back up itself: the backup folder.
	skip []string
}

// is_excluded applies the exclude patterns. A pattern without a "/" is matched
// against the file or folder name, otherwise it's matched against the full
// path.
fn (w Walker) is_excluded(path string) bool {
	for s in w.skip {
		if path == s || path.starts_with(s + '/') {
			return true
		}
	}
	return matches_any(path, w.excludes)
}

// covers is true if the patterns back up path: it's under an include, and
// neither it nor any folder between it and that include is excluded.
fn (w Walker) covers(path string) bool {
	for include in w.includes {
		if path != include && !path.starts_with(include.trim_right('/') + '/') {
			continue
		}
		mut p := path
		for {
			if w.is_excluded(p) {
				break
			}
			if p == include || p.len <= include.len {
				return true
			}
			p = os.dir(p)
		}
	}
	return false
}

// matches_any is true if path matches one of patterns. A pattern without a
// "/" is matched against the file or folder name, otherwise it's matched
// against the full path.
fn matches_any(path string, patterns []string) bool {
	name := os.base(path)
	for pattern in patterns {
		if pattern.contains('/') {
			if path.match_glob(pattern) {
				return true
			}
		} else if name.match_glob(pattern) {
			return true
		}
	}
	return false
}

// walk appends each regular file under path to out. Symbolic links aren't
// followed or backed up.
fn (w Walker) walk(path string, mut out []string) {
	if w.is_excluded(path) || os.is_link(path) {
		return
	}
	if os.is_dir(path) {
		mut names := os.ls(path) or { return }
		names.sort()
		for name in names {
			w.walk(os.join_path(path, name), mut out)
		}
		return
	}
	if os.is_file(path) {
		out << path
	}
}

fn new_walker(config Config) Walker {
	return Walker{
		includes: config.includes
		excludes: config.excludes
		skip:     [config.dir]
	}
}
