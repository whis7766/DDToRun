#!/bin/sh
# Repository hygiene checks. Run this before committing; GitHub Actions only
# builds and never runs these.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

FAIL=0
note() { printf 'FAIL  %s\n' "$*"; FAIL=1; }

# --- shell syntax ---------------------------------------------------------
for _file in build/build.sh build/setup.sh build/lib/*.sh build/rootfs/*.sh \
	build/files/app-runner-fb.sh build/files/initramfs-init scripts/check.sh; do
	sh -n "$_file" || note "$_file"
done

if command -v shellcheck >/dev/null 2>&1; then
	shellcheck -S warning -x \
		build/build.sh build/setup.sh build/lib/*.sh \
		build/rootfs/*.sh build/files/app-runner-fb.sh \
		build/files/initramfs-init scripts/check.sh || FAIL=1
fi

# --- Go -------------------------------------------------------------------
if command -v gofmt >/dev/null 2>&1; then
	_unformatted=$(gofmt -l build/vendor)
	[ -z "$_unformatted" ] || note "gofmt needed: $_unformatted"
fi

if command -v go >/dev/null 2>&1; then
	# The runner is a single file with no external dependencies.
	( cd build/vendor && GO111MODULE=off go vet app-runner.go ) || FAIL=1
fi

# --- Python ---------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
	python3 -m py_compile .github/pve/pve-e2e.py || note ".github/pve/pve-e2e.py"
fi

[ "$FAIL" -eq 0 ] && echo "checks passed"
exit "$FAIL"
