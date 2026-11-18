module main

// The version and its date are set when amber is built for a release (see
// .github/workflows/ci.yml), like: v -d amber_version=v1.2.3 -d amber_date=2026-11-18
const amber_version = $d('amber_version', 'dev')
const amber_date = $d('amber_date', '')

fn version_line() string {
	return '${amber_version} ${amber_date}'.trim_space()
}
