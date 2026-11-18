module main

import os
import time

struct LsEntry {
mut:
	name     string
	size     i64
	modified i64
}

// ls lists each path as it was at as_of (microseconds since the UNIX epoch).
// A file is listed by itself. A folder lists the files and folders directly in
// it, where a folder's size is the total of everything under it and its
// modified time is the latest of them.
fn ls(db_path string, paths []string, as_of i64) ![]string {
	mut db := open_database(db_path)!
	defer {
		db.close()
	}

	mut lines := []string{}
	for i, arg in paths {
		path := os.abs_path(arg).trim_right('/')
		versions := latest_versions(mut db, path, as_of)!

		if v := versions[path] {
			if !v.deleted {
				lines << ls_line(LsEntry{ name: arg, size: v.size, modified: v.modified })
				continue
			}
		}

		mut entries := map[string]LsEntry{}
		for p, v in versions {
			if v.deleted || p == path {
				continue
			}
			rel := p[path.len + 1..]
			name := if rel.contains('/') { rel.all_before('/') + '/' } else { rel }
			mut e := entries[name] or {
				LsEntry{
					name: name
				}
			}
			e.size += v.size
			if v.modified > e.modified {
				e.modified = v.modified
			}
			entries[name] = e
		}
		if entries.len == 0 {
			return error('${arg}: not in the backup')
		}

		if paths.len > 1 {
			if i > 0 {
				lines << ''
			}
			lines << '${path}:'
		}
		mut names := entries.keys()
		names.sort()
		for name in names {
			lines << ls_line(entries[name])
		}
	}
	return lines
}

fn ls_line(e LsEntry) string {
	return '${e.size:12}  ${us_to_time(e.modified).local().format_ss()}  ${e.name}'
}

// parse_local_time parses "YYYY-MM-DD", "YYYY-MM-DD HH:MM" or
// "YYYY-MM-DD HH:MM:SS" in the local time zone. A date by itself means the end
// of that day.
fn parse_local_time(s string) !i64 {
	full := match s.len {
		10 { s + ' 23:59:59' }
		16 { s + ':59' }
		19 { s }
		else { return error('invalid time "${s}", use YYYY-MM-DD [HH:MM[:SS]]') }
	}
	t := time.parse(full) or { return error('invalid time "${s}", use YYYY-MM-DD [HH:MM[:SS]]') }
	return local_to_unix(t) * 1_000_000 + 999_999
}
