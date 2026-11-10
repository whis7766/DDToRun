#!/bin/sh
# Repository hygiene checks. Run this before committing; GitHub Actions only
# builds the images and never runs these.
#
#   sh scripts/check.sh
#
# Static analysis (shellcheck, go vet) runs when those tools are installed and is
# skipped otherwise, so this works on a bare box.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

FAIL=0
note() {
	printf 'FAIL  %s\n' "$*"
	FAIL=1
}

SHELL_FILES="build/build.sh build/setup.sh build/lib/*.sh build/rootfs/*.sh
build/files/*.sh build/files/*.openrc build/files/initramfs-init scripts/check.sh"

# --- shell ----------------------------------------------------------------
for _file in $SHELL_FILES; do
	sh -n "$_file" || note "$_file"
done

if command -v shellcheck >/dev/null 2>&1; then
	# -s sh keeps the openrc scripts out of the unknown-interpreter branch.
	shellcheck -s sh -S warning -x $SHELL_FILES || FAIL=1
else
	echo "note  shellcheck not installed - syntax only"
fi

# --- Go -------------------------------------------------------------------
if command -v gofmt >/dev/null 2>&1; then
	_unformatted=$(gofmt -l build/vendor)
	[ -z "$_unformatted" ] || note "gofmt needed: $_unformatted"
fi

if command -v go >/dev/null 2>&1; then
	# The runner is a single file with no external dependencies.
	(cd build/vendor && GO111MODULE=off go vet app-runner.go) || FAIL=1
else
	echo "note  go not installed - skipped vet"
fi

# --- Python ---------------------------------------------------------------
# ast.parse instead of py_compile: same syntax check, no __pycache__ left behind.
if command -v python3 >/dev/null 2>&1; then
	for _file in .github/pve/*.py scripts/*.py; do
		python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$_file" ||
			note "$_file"
	done
else
	echo "note  python3 not installed - skipped"
fi

[ "$FAIL" -eq 0 ] && echo "checks passed"
exit "$FAIL"
