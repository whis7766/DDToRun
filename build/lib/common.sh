# shellcheck shell=sh
# Host-side shell helpers shared by build.sh and its libraries.

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# require_cmds <cmd>... - abort when a required host tool is missing.
require_cmds() {
	for _cmd in "$@"; do
		command -v "$_cmd" >/dev/null 2>&1 || die "missing host dependency: $_cmd"
	done
}

# fetch <url> <dest> - curl with the retry policy used across the build.
fetch() {
	curl -fSL --retry 5 --retry-all-errors --connect-timeout 30 -o "$2" "$1"
}
