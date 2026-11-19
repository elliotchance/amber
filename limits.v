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
// or "unlimited". Units are base 10 (1K is 1000 bytes), like disk sizes. KiB
// and the other base 2 units aren't accepted, so a size can't be off by 10%.
fn parse_max_size(s string) !i64 {
	if s == 'unlimited' {
		return unlimited
	}
	invalid := stage_error(.usage, 'invalid max size "${s}", use a size like 500G (base 10, 1K is 1000 bytes) or "unlimited"')
	if s.to_upper().ends_with('IB') {
		return invalid
	}
	mut number := s.to_upper().trim_right('B')
	mut multiplier := i64(1)
	if number.len > 0 {
		match number[number.len - 1] {
			`K` { multiplier = kb }
			`M` { multiplier = mb }
			`G` { multiplier = gb }
			`T` { multiplier = tb }
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

// format_max_size is a max size the way --max-size takes it: the largest unit
// it's a whole number of (like "500G"), or bytes.
fn format_max_size(n i64) string {
	if n == unlimited {
		return 'unlimited'
	}
	for unit, multiplier in {
		'T': tb
		'G': gb
		'M': mb
		'K': kb
	} {
		if n >= multiplier && n % multiplier == 0 {
			return '${n / multiplier}${unit}'
		}
	}
	return '${n}'
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
