#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
script_path="${repo_root}/git-diff-report.sh"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "${tmp_repo}"' EXIT

cd "$tmp_repo"
git init -q
git config user.name "Test User"
git config user.email "test@example.com"

printf 'one\n' > file.txt
git add file.txt
git commit -q -m "first"

printf 'two\n' >> file.txt
git add file.txt
git commit -q -m "second"

printf 'three\n' >> file.txt
git add file.txt
git commit -q -m "third"

source "$script_path"

parse_args --interactive

if [[ "${CONFIG[b_commit]}" != "HEAD" ]]; then
	echo "expected interactive default b_commit=HEAD, got '${CONFIG[b_commit]}'" >&2
	exit 1
fi

expected_a="$(git rev-list --first-parent "${CONFIG[b_commit]}" | tail -n 1)"
if [[ "${CONFIG[a_commit]}" != "$expected_a" ]]; then
	echo "expected interactive default a_commit oldest first-parent of b_commit" >&2
	echo "expected: $expected_a" >&2
	echo "actual:   ${CONFIG[a_commit]}" >&2
	exit 1
fi

synthesize_default_history_plan

if ! grep -qE '^pick [0-9a-f]{40}( |$)' <<<"${CONFIG[history_plan_content]}"; then
	echo "expected synthesized history plan to contain at least one pick line" >&2
	exit 1
fi

mapfile -t actual_shas < <(sed -nE 's/^pick ([0-9a-f]{40}).*/\1/p' <<<"${CONFIG[history_plan_content]}")
mapfile -t expected_shas < <(git rev-list --first-parent --reverse "${CONFIG[a_commit]}..${CONFIG[b_commit]}")

if [[ "${#actual_shas[@]}" -eq 0 ]]; then
	echo "expected at least one commit in synthesized history plan" >&2
	exit 1
fi

if [[ "${#actual_shas[@]}" -ne "${#expected_shas[@]}" ]]; then
	echo "expected ${#expected_shas[@]} commits in plan, got ${#actual_shas[@]}" >&2
	exit 1
fi

for i in "${!expected_shas[@]}"; do
	if [[ "${actual_shas[$i]}" != "${expected_shas[$i]}" ]]; then
		echo "commit ordering/content mismatch at index $i" >&2
		echo "expected ${expected_shas[$i]} got ${actual_shas[$i]}" >&2
		exit 1
	fi
done

echo "interactive default history plan regression test passed"
