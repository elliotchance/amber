module main

import os

// Walker finds every file under the root that the includes and excludes back
// up. Paths are relative to the root ("" is the root itself).
struct Walker {
	root     string
	includes []string
	excludes []string
	// skip is the backup folder, relative to the root, if it's under the root.
	// amber never backs up itself.
	skip string
}

fn new_walker(config Config) Walker {
	return Walker{
		root:     config.root
		includes: config.includes
		excludes: config.excludes
		skip:     relative_to(config.dir, config.root) or { '' }
	}
}

// relative_to is path relative to root, or none if it isn't under root.
fn relative_to(path string, root string) ?string {
	if path == root {
		return ''
	}
	prefix := if root.ends_with('/') { root } else { root + '/' }
	if path.starts_with(prefix) {
		return path[prefix.len..]
	}
	return none
}

// abs is the full path of rel.
fn (w Walker) abs(rel string) string {
	return if rel == '' { w.root } else { os.join_path(w.root, rel) }
}

// excludes_self is true if rel itself is excluded (not counting the folders
// it's in).
fn (w Walker) excludes_self(rel string) bool {
	if w.skip != '' && (rel == w.skip || rel.starts_with(w.skip + '/')) {
		return true
	}
	return rel != '' && matches_any(rel, w.excludes)
}

// covers is true if the patterns back up rel: it, or a folder it's in,
// matches an include (or there are no includes), and neither it nor any
// folder it's in is excluded.
fn (w Walker) covers(rel string) bool {
	mut included := w.includes.len == 0
	mut p := rel
	for p != '' {
		if w.excludes_self(p) {
			return false
		}
		if !included && matches_any(p, w.includes) {
			included = true
		}
		p = parent(p)
	}
	return included
}

// parent is the folder rel is in ("" for the root).
fn parent(rel string) string {
	i := rel.last_index('/') or { return '' }
	return rel[..i]
}

// paths is every file the patterns back up, sorted. An include that's anchored
// and has no wildcards only needs its own folder read, any other include needs
// the whole root.
fn (w Walker) paths() []string {
	mut starts := ['']
	if w.includes.len > 0 && w.includes.all(it.starts_with('/') && !has_wildcard(it)) {
		starts = w.includes.map(it.trim('/'))
	}
	mut found := map[string]bool{}
	for start in starts {
		if start != '' && !w.covers(start) {
			continue
		}
		mut out := []string{}
		w.walk(start, mut out)
		for p in out {
			found[p] = true
		}
	}
	mut result := found.keys()
	result.sort()
	return result
}

// walk appends each regular file under rel that's backed up to out. Excluded
// folders aren't read. Symbolic links aren't followed or backed up.
fn (w Walker) walk(rel string, mut out []string) {
	if w.excludes_self(rel) {
		return
	}
	path := w.abs(rel)
	if os.is_link(path) {
		return
	}
	if os.is_dir(path) {
		mut names := os.ls(path) or { return }
		names.sort()
		for name in names {
			w.walk(if rel == '' { name } else { rel + '/' + name }, mut out)
		}
		return
	}
	if os.is_file(path) && w.covers(rel) {
		out << rel
	}
}

fn has_wildcard(pattern string) bool {
	return pattern.contains_any('*?[')
}

// matches_any is true if rel (a path relative to the root) matches one of
// patterns. A pattern that starts with "/" is anchored to the root. Any other
// pattern can match at any depth: "foo" matches every file or folder named
// foo, and "a/b" every b in a folder named a.
fn matches_any(rel string, patterns []string) bool {
	for pattern in patterns {
		if pattern.starts_with('/') {
			if glob_match(pattern[1..], rel) {
				return true
			}
			continue
		}
		for i := 0; i < rel.len; i++ {
			if (i == 0 || rel[i - 1] == `/`) && glob_match(pattern, rel[i..]) {
				return true
			}
		}
	}
	return false
}

// glob_match matches a whole path against pattern. "*" matches anything but
// "/", "**" matches anything (including "/"), "?" is one character other than
// "/", and "[abc]", "[a-z]" and "[!abc]" match one character from a set.
// "**/" also matches no folders at all, so "a/**/b" matches "a/b".
fn glob_match(pattern string, s string) bool {
	if pattern == '' {
		return s == ''
	}
	if pattern.starts_with('**') {
		rest := pattern[2..]
		if rest.starts_with('/') && glob_match(rest[1..], s) {
			return true
		}
		for i in 0 .. s.len + 1 {
			if glob_match(rest, s[i..]) {
				return true
			}
		}
		return false
	}
	match pattern[0] {
		`*` {
			for i in 0 .. s.len + 1 {
				if glob_match(pattern[1..], s[i..]) {
					return true
				}
				if i < s.len && s[i] == `/` {
					break
				}
			}
			return false
		}
		`?` {
			return s.len > 0 && s[0] != `/` && glob_match(pattern[1..], s[1..])
		}
		`[` {
			end := pattern.index_after(']', 2) or { -1 }
			if end > 0 && s.len > 0 && s[0] != `/` {
				return class_match(pattern[1..end], s[0]) && glob_match(pattern[end + 1..], s[1..])
			}
			if end > 0 {
				return false
			}
		}
		else {}
	}
	return s.len > 0 && s[0] == pattern[0] && glob_match(pattern[1..], s[1..])
}

// class_match is true if c is in a "[...]" set (without the brackets).
fn class_match(class string, c u8) bool {
	negate := class.len > 0 && (class[0] == `!` || class[0] == `^`)
	set := if negate { class[1..] } else { class }
	mut found := false
	mut i := 0
	for i < set.len {
		if i + 2 < set.len && set[i + 1] == `-` {
			if c >= set[i] && c <= set[i + 2] {
				found = true
			}
			i += 3
		} else {
			if c == set[i] {
				found = true
			}
			i++
		}
	}
	return found != negate
}

// clean_path turns a path given to ls or restore into a path relative to the
// root. A leading "/" or "./" and a trailing "/" are ignored, and "." is the
// root. ".." isn't allowed, since nothing outside the root is backed up.
fn clean_path(arg string) !string {
	mut parts := []string{}
	for part in arg.split('/') {
		if part == '' || part == '.' {
			continue
		}
		if part == '..' {
			return stage_error(.usage, '${arg}: paths are inside the backup root and cannot use ".."')
		}
		parts << part
	}
	return parts.join('/')
}

// check_pattern checks an include or exclude can only match inside the root.
fn check_pattern(kind string, pattern string) ! {
	if pattern.trim('/') == '' {
		return stage_error(.usage, '${kind} "${pattern}" is empty')
	}
	for part in pattern.split('/') {
		if part == '..' || part == '.' {
			return stage_error(.usage, '${kind} "${pattern}" cannot use "." or "..", patterns are relative to the backup root')
		}
	}
}
