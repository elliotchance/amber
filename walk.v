module main

import os

// Walker finds every file under the include paths that isn't excluded.
struct Walker {
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
