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

printf 'base\n' > file.txt
git add file.txt
git commit -q -m "base"
base_sha="$(git rev-parse HEAD)"

printf 'one\n' >> file.txt
git add file.txt
git commit -q -m "one"
sha1="$(git rev-parse HEAD)"

printf 'two\n' >> file.txt
git add file.txt
git commit -q -m "two"
sha2="$(git rev-parse HEAD)"

printf 'three\n' >> file.txt
git add file.txt
git commit -q -m "three"
sha3="$(git rev-parse HEAD)"

source "$script_path"

parse_args "$base_sha" "$sha3"
validate_commits

# 1) bundle <sha> % BUNDLE ... # message -> section title comes from %...
CONFIG[history_plan_content]="bundle ${sha1} % BUNDLE nrntn wabba # Handle optional ..."
parse_history_plan_records
row="$(printf '%s' "${CONFIG[history_plan_parsed_tsv]}" | sed -n '1p')"
action="$(printf '%s\n' "$row" | awk -F'\t' '{print $1}')"
section_name="$(printf '%s\n' "$row" | awk -F'\t' '{print $4}')"
display_message="$(printf '%s\n' "$row" | awk -F'\t' '{print $5}')"
if [[ "$action" != "bundle" ]]; then
	echo "expected bundle action, got '${action}'" >&2
	exit 1
fi
if [[ "$section_name" != "BUNDLE nrntn wabba" ]]; then
	echo "expected section name from % annotation, got '${section_name}'" >&2
	exit 1
fi
if [[ "$display_message" != "Handle optional ..." ]]; then
	echo "expected parsed display message after #, got '${display_message}'" >&2
	exit 1
fi

# 2) bundle without %... on first line -> parse error
CONFIG[history_plan_content]="bundle ${sha1} # only comment"
if (parse_history_plan_records) >/tmp/test-plan.out 2>/tmp/test-plan.err; then
	echo "expected parse_history_plan_records to fail when first bundle line has no %SECTION" >&2
	exit 1
fi
if ! grep -q "first commit in a bundle run must include %SECTION" /tmp/test-plan.err; then
	echo "missing expected parse error for absent first %SECTION" >&2
	cat /tmp/test-plan.err >&2
	exit 1
fi

# 3) continuation with only # message inherits prior section title
CONFIG[history_plan_content]="bundle ${sha1} % Primary Section # start
bundle ${sha2} # continuation only"
parse_history_plan_records
mapfile -t rows < <(printf '%s' "${CONFIG[history_plan_parsed_tsv]}" | sed '/^$/d')
sec1="$(printf '%s\n' "${rows[0]}" | awk -F'\t' '{print $4}')"
sec2="$(printf '%s\n' "${rows[1]}" | awk -F'\t' '{print $4}')"
msg2="$(printf '%s\n' "${rows[1]}" | awk -F'\t' '{print $5}')"
if [[ "$sec1" != "Primary Section" || "$sec2" != "Primary Section" ]]; then
	echo "expected continuation bundle line to inherit previous section title" >&2
	echo "sec1='${sec1}' sec2='${sec2}'" >&2
	exit 1
fi
if [[ "$msg2" != "continuation only" ]]; then
	echo "expected continuation message parsed from # text, got '${msg2}'" >&2
	exit 1
fi

# 4) whitespace variants around % and before # are normalized for section title
CONFIG[history_plan_content]="bundle ${sha1}      %    Spaced   Section    Name      #   msg with leading spaces"
parse_history_plan_records
row="$(printf '%s' "${CONFIG[history_plan_parsed_tsv]}" | sed -n '1p')"
spaced_section="$(printf '%s\n' "$row" | awk -F'\t' '{print $4}')"
spaced_msg="$(printf '%s\n' "$row" | awk -F'\t' '{print $5}')"
if [[ "$spaced_section" != "Spaced   Section    Name" ]]; then
	echo "expected trimmed section title from % annotation, got '${spaced_section}'" >&2
	exit 1
fi
if [[ "$spaced_msg" != "msg with leading spaces" ]]; then
	echo "expected trimmed message text after #, got '${spaced_msg}'" >&2
	exit 1
fi

# 5) boundary marker should use parsed %SECTION title, not # message text
CONFIG[history_plan_content]="bundle ${sha1} % Actual Section # This is only comment text
bundle ${sha2} # still only comment
pick ${sha3}"
parse_history_plan_records
workdir="$(mktemp -d)"
trap 'rm -rf "${tmp_repo}" "${workdir}"' EXIT
html_path="${workdir}/report.html"
render_html_header "$html_path"
generate_diff_html "$html_path" "$workdir"

if ! grep -q "BEGINNING OF SECTION Actual Section" "$html_path"; then
	echo "expected BEGINNING OF SECTION marker to include parsed %SECTION title" >&2
	exit 1
fi
if grep -q "BEGINNING OF SECTION This is only comment text" "$html_path"; then
	echo "section marker incorrectly derived from comment text" >&2
	exit 1
fi

echo "history plan bundle section parsing regression test passed"
