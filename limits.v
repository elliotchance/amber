module main

import strconv

// parse_max_versions parses a number of previous versions, or "unlimited".
fn parse_max_versions(s string) !i64 {
	if s == 'unlimited' {
		return unlimited
	}
	n := strconv.atoi(s) or { return stage_error(.usage, 'invalid max versions "${s}", use a number or "unlimited"') }
	if n < 0 {
		return stage_error(.usage, 'invalid max versions "${s}", use a number or "unlimited"')
	}
	return n
}

// parse_min_versions parses a number of previous versions, or "unlimited".
fn parse_min_versions(s string) !i64 {
	return parse_max_versions(s) or {
		return stage_error(.usage, err.msg().replace('max versions', 'min versions'))
	}
}

// parse_max_size parses a size like "500G", "1.5T", "200MB" or "1048576" (bytes),
// or "unlimited". Units are powers of 1024.
fn parse_max_size(s string) !i64 {
	if s == 'unlimited' {
		return unlimited
	}
	invalid := stage_error(.usage, 'invalid max size "${s}", use a size like 500G or "unlimited"')
	mut number := s.to_upper().trim_right('B').trim_right('I')
	mut multiplier := i64(1)
	if number.len > 0 {
		match number[number.len - 1] {
			`K` { multiplier = i64(1) << 10 }
			`M` { multiplier = i64(1) << 20 }
			`G` { multiplier = i64(1) << 30 }
			`T` { multiplier = i64(1) << 40 }
			else {}
		}
		if multiplier > 1 {
			number = number[..number.len - 1]
		}
	}
	if number == '' || !number.contains_only('0123456789.') || number.count('.') > 1 {
		return invalid
	}
	return i64(strconv.atof64(number) or { return invalid } * f64(multiplier))
}

// check_versions checks min_versions isn't more than max_versions.
fn check_versions(min_versions i64, max_versions i64) ! {
	if min_versions != unlimited && max_versions != unlimited && min_versions > max_versions {
		return stage_error(.usage, "min versions (${min_versions}) can't be more than max versions (${max_versions})")
	}
}

fn format_max_versions(n i64) string {
	return if n == unlimited { 'unlimited' } else { '${n}' }
}

fn format_max_size(n i64) string {
	return if n == unlimited { 'unlimited' } else { human_size(n) }
}

// parse_keep_deleted parses a number of days, or "forever".
fn parse_keep_deleted(s string) !i64 {
	if s == 'forever' {
		return unlimited
	}
	n := strconv.atoi(s) or {
		return stage_error(.usage, 'invalid keep deleted "${s}", use a number of days or "forever"')
	}
	if n < 0 {
		return stage_error(.usage, 'invalid keep deleted "${s}", use a number of days or "forever"')
	}
	return n
}

fn format_keep_deleted(days i64) string {
	return match days {
		unlimited { 'forever' }
		1 { '1 day' }
		else { '${days} days' }
	}
}
