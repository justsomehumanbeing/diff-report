#!/usr/bin/env bash

# git-diff-report.sh
# Build a pretty PDF report of per-commit diffs along first-parent from A (exclusive) to B (inclusive).
# Optional: include a demo "how to read diffs" section comparing two standalone files.
# Optional: drive the commit list via a "history plan" (like an interactive rebase todo).
#
# Usage:
#   git-diff-report.sh [-o output.pdf] [--force]
#     [--include-demo [--demo-old path --demo-new path]]
#     [--interactive [<A> [<B>]] | --history-plan-file <file> | --history-plan-stdin | <A> <B>]

readonly DEFAULT_OUTPUT_FILENAME="diff-report.pdf"
readonly EMPTY_TREE_HASH="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
readonly DELTA_THEME="gruvbox-light"
readonly DELTA_DEMO_OPTIONS=(--paging=never --wrap-max-lines=0 --true-color=always)
readonly DELTA_COMMIT_OPTIONS=(--paging=never --wrap-max-lines=0 --width=200 --true-color=always)

usage() {
	local exit_code="${1:-1}"
	echo "Usage: $0 [-o output.pdf] [--force] [--include-demo [--demo-old path --demo-new path]] [--interactive [<A> [<B>]] | <A> <B>]"
	echo "  -o, --output        Output PDF file (default: ${DEFAULT_OUTPUT_FILENAME})"
	echo "  -h, --help          Print this help message, ignore all other flags and exit"
	echo "      --force         Overwrite output file if it already exists"
	echo "      --include-demo  Include an optional demo section that explains diff colors"
	echo "      --demo-old      Path to demo old file (default: testfileold, requires --include-demo)"
	echo "      --demo-new      Path to demo new file (default: testfilenew, requires --include-demo)"
	echo "      --interactive [<A> [<B>]]"
	echo "                      Enable interactive commit-plan mode; defaults to root..HEAD"
	echo "      --history-plan-file <file>"
	echo "                      Read non-interactive history plan from file"
	echo "      --history-plan-stdin"
	echo "                      Read non-interactive history plan from stdin"
	echo "      --detailed-commit-history-file <file>"
	echo "                      Alias of --history-plan-file"
	echo "      --detailed-commit-history-stdin"
	echo "                      Alias of --history-plan-stdin"
	echo "      --html-output   Activates HTML output and specifies file to be written to."
	echo "      --html-only   	Activates HTML output and deactivates PDF output."
	echo "                      Default Output: ${DEFAULT_OUTPUT_FILENAME%.pdf}.html"
	echo "      --allow-for-interactive-clarifications"
	echo "                      Allow the script to ask follow-up questions on /dev/tty"
	echo "                      in ambiguous cases (e.g. when an argument looks like an option)."
	echo ""
	echo "Range semantics:"
	echo "  - A must be an ancestor of B."
	echo "  - A must be on B's first-parent chain."
	echo "  - Commits are collected from A..B on first-parent history"
	echo "    (A excluded, B included, oldest → newest)."
	echo ""
	echo "History plan format (like git rebase --todo):"
	echo "  - Lines: '<action> <sha> [%annotation] [# message]'"
	echo "  - Valid actions: pick, drop, squash, bundle"
	echo "  - Comments (# ...) and blank lines are ignored"
	echo "  - Bundle runs: first bundle line must include '%SECTION NAME'"
	echo ""
	echo "Rendering modes:"
	echo "  - Color HTML diff mode: requires delta + aha"
	echo "  - Plain HTML diff mode: used when delta and/or aha are missing"
	echo "  - PDF output mode: requires wkhtmltopdf"
	echo "  - HTML-only mode: used when wkhtmltopdf is missing"
	exit "$exit_code"
}

# Escape a single argument for HTML (safe for embedding in attributes/text).
html_escape_arg() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Escape stdin stream for HTML.
html_escape_stream() {
	sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Declare a global CONFIG array to place user-centric config variables in
declare -A CONFIG=()

# Dependency flags (set by check_dependencies)
HAS_DELTA=false
HAS_AHA=false
HAS_WKHTMLTOPDF=false
# Plan flags (set by parse_history_plan_records)
PLAN_HAS_DROP=false
PLAN_HAS_SQUASH=false
PLAN_HAS_BUNDLE=false

prevent_overwrites() {
	# Guardrails for accidental destructive writes.
	REPO_TOPLEVEL="$(git rev-parse --show-toplevel)"
	if [[ "$1" == "$REPO_TOPLEVEL"/* ]]; then
		OUTPUT_REL_TO_REPO="${1#"$REPO_TOPLEVEL"/}"
		if git ls-files --error-unmatch -- "$OUTPUT_REL_TO_REPO" >/dev/null 2>&1; then
			echo "Warning: output target is a tracked file in this repository: $1" >&2
			echo "Refusing to overwrite tracked files. Choose a different output path." >&2
			exit 2
		fi
	fi

	if [[ -e "$1" && "${CONFIG[force_overwrite]}" -ne 1 ]]; then
		echo "Warning: output file already exists: $1" >&2
		echo "Refusing to overwrite without --force." >&2
		exit 2
	fi

	echo "Output target (absolute): $1"
}

parse_args() {
	# LOADING DEFAULTS
	#
	# standard flags
	CONFIG[output]="$DEFAULT_OUTPUT_FILENAME"
	CONFIG[output_abs]=""
	CONFIG[force_overwrite]=0
	CONFIG[include_demo]=false
	CONFIG[demo_old]="testfileold"
	CONFIG[demo_new]="testfilenew"
	CONFIG[a_commit]=""
	CONFIG[b_commit]=""
	CONFIG[html_only]=0
	CONFIG[html_output]="${DEFAULT_OUTPUT_FILENAME%.pdf}.html"
	CONFIG[html_output_requested]=0
	CONFIG[allow_for_interactive_clarifications]=0
	# 
	# history plan controls
	CONFIG[interactive_mode]=0
	CONFIG[history_plan_source]="" # "", interactive, file, stdin
	CONFIG[history_plan_file]=""
	CONFIG[history_plan_content]=""
	CONFIG[history_plan_parsed_tsv]=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
			# OUTPUT
		-o | --output)
			shift
			[[ $# -gt 0 ]] || usage
			CONFIG[output]="$1"
			shift
			;;
			# HELP
		-h | --help)
			usage 0
			;;
		--allow-for-interactive-clarifications)
			CONFIG[allow_for_interactive_clarifications]=1
			shift
			;;
			# FORCE
		-f | --force)
			CONFIG[force_overwrite]=1
			shift
			;;
			# DEMO
		--include-demo)
			CONFIG[include_demo]=true
			shift
			;;
		--demo-old)
			shift
			[[ $# -gt 0 ]] || usage
			CONFIG[demo_old]="$1"
			shift
			;;
		--demo-new)
			shift
			[[ $# -gt 0 ]] || usage
			CONFIG[demo_new]="$1"
			shift
			;;
			# INTERACTIVE
		--interactive)
			if [[ -n "${CONFIG[history_plan_source]}" && "${CONFIG[history_plan_source]}" != "interactive" ]]; then
				echo "Error: --interactive cannot be combined with --history-plan-*" >&2
				usage
			fi
			CONFIG[history_plan_source]="interactive"
			CONFIG[interactive_mode]=1
			shift

			# Optional inline A and B after --interactive
			if [[ $# -gt 0 && "$1" != -* ]]; then
				if [[ -n "${CONFIG[a_commit]:-}" ]]; then
					echo "Error: duplicate A commit provided (positional and --interactive)." >&2
					usage
				fi
				CONFIG[a_commit]="$1"
				shift
				if [[ $# -gt 0 && "$1" != -* ]]; then
					if [[ -n "${CONFIG[b_commit]:-}" ]]; then
						echo "Error: duplicate B commit provided (positional and --interactive)." >&2
						usage
					fi
					CONFIG[b_commit]="$1"
					shift
				fi
			fi
			;;
			# DETAILED HISTORY
		--history-plan-file | --detailed-commit-history-file)
			if [[ -n "${CONFIG[history_plan_source]}" && "${CONFIG[history_plan_source]}" != "file" ]]; then
				echo "Error: choose at most one history plan source (interactive, file, or stdin)." >&2
				usage
			fi
			CONFIG[history_plan_source]="file"
			shift
			[[ $# -gt 0 ]] || usage
			CONFIG[history_plan_file]="$1"
			shift
			;;

		--history-plan-stdin | --detailed-commit-history-stdin)
			if [[ -n "${CONFIG[history_plan_source]}" && "${CONFIG[history_plan_source]}" != "stdin" ]]; then
				echo "Error: choose at most one history plan source (interactive, file, or stdin)." >&2
				usage
			fi
			CONFIG[history_plan_source]="stdin"
			shift
			;;
		--html-only)
			CONFIG[html_only]=1
			shift
			;;
		--html-output)
			CONFIG[html_output_requested]=1
			shift
			[[ $# -gt 0 ]] || usage

			if [[ "$1" == -* ]]; then
				# Ambiguous: looks like an option.
				if [[ "${CONFIG[allow_for_interactive_clarifications]}" -ne 1 ]]; then
					echo "Error: requested HTML output '$1' looks like an option." >&2
					echo "Hint: pass --allow-for-interactive-clarifications to confirm interactively," >&2
					echo "      or use a non-ambiguous path like './$1'." >&2
					usage
				fi

				read -r -p "Requested HTML output '$1' looks like an option. Use it as filename? [y/N] " ans < /dev/tty || ans=""
				case "$ans" in
					y|Y|yes|YES)
						CONFIG[html_output]="$1"
						shift
						;;
					*)
						usage
						;;
				esac
			else
				CONFIG[html_output]="$1"
				shift
			fi
			;;
		-*)
			echo "Unknown option: $1" >&2
			echo "Try '$0 --help' for usage." >&2
			usage
			;;
		*)
			if [[ -z "${CONFIG[a_commit]:-}" ]]; then
				CONFIG[a_commit]="$1"
			elif [[ -z "${CONFIG[b_commit]:-}" ]]; then
				CONFIG[b_commit]="$1"
			else
				echo "Too many positional arguments." >&2
				usage
			fi
			shift
			;;
		esac
	done

	if [[ "${CONFIG[interactive_mode]}" -eq 1 ]]; then
		if [[ -z "${CONFIG[b_commit]:-}" ]]; then
			CONFIG[b_commit]="HEAD"
		fi
		if [[ -z "${CONFIG[a_commit]:-}" ]]; then
			CONFIG[a_commit]="$(git rev-list --first-parent "${CONFIG[b_commit]}" | tail -n 1)"
		fi
	fi

	if [[ "${CONFIG[history_plan_source]}" == "file" || "${CONFIG[history_plan_source]}" == "stdin" ]]; then
		if [[ -z "${CONFIG[b_commit]:-}" ]]; then
			CONFIG[b_commit]="HEAD"
		fi
		if [[ -z "${CONFIG[a_commit]:-}" ]]; then
			CONFIG[a_commit]="$(git rev-list --first-parent "${CONFIG[b_commit]}" | tail -n 1)"
		fi
	fi

	: "${CONFIG[a_commit]:?Missing A}"
	: "${CONFIG[b_commit]:?Missing B}"

	case "${CONFIG[history_plan_source]}" in
	file)
		if [[ ! -f "${CONFIG[history_plan_file]}" ]]; then
			echo "Error: history plan file not found: ${CONFIG[history_plan_file]}" >&2
			exit 2
		fi
		CONFIG[history_plan_content]="$(cat "${CONFIG[history_plan_file]}")"
		;;
	stdin)
		CONFIG[history_plan_content]="$(cat)"
		;;
	interactive | "") ;;
	*)
		echo "fatal error, unknown history plan source: ${CONFIG[history_plan_source]}" >&2
		exit 1
		;;
	esac

	# demo args validation
	if [[ "${CONFIG[include_demo]}" != true && ("${CONFIG[demo_old]}" != "testfileold" || "${CONFIG[demo_new]}" != "testfilenew") ]]; then
		echo "Error: --demo-old/--demo-new require --include-demo." >&2
		usage
	fi

	# Normalize output path once so all write-sites use the same target.
	if command -v realpath >/dev/null 2>&1; then
		CONFIG[output_abs]="$(realpath -m "${CONFIG[output]}")"
	else
		CONFIG[output_abs]="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${CONFIG[output]}")"
	fi

	prevent_overwrites "${CONFIG[output_abs]}"

}

check_dependencies() {
	if ! command -v git >/dev/null 2>&1; then
		echo "Error: required dependency 'git' not found in PATH." >&2
		exit 2
	fi

	command -v delta >/dev/null 2>&1 && HAS_DELTA=true
	command -v aha >/dev/null 2>&1 && HAS_AHA=true
	command -v wkhtmltopdf >/dev/null 2>&1 && HAS_WKHTMLTOPDF=true

	if [[ "$HAS_DELTA" == true && "$HAS_AHA" == true ]]; then
		echo "[git-diff-report] Diff rendering mode: color-html (delta + aha)"
	else
		echo "[git-diff-report] Diff rendering mode: plain-html (delta/aha unavailable)"
	fi

	if [[ "$HAS_WKHTMLTOPDF" == true ]]; then
		echo "[git-diff-report] Output mode: pdf (wkhtmltopdf)"
	else
		echo "[git-diff-report] Output mode: html-only (wkhtmltopdf unavailable)"
	fi
}

validate_commits() {
	if ! git rev-parse --verify --quiet "${CONFIG[a_commit]}^{commit}" >/dev/null; then
		echo "Error: '${CONFIG[a_commit]}' is not a valid commit-ish." >&2
		exit 2
	fi
	if ! git rev-parse --verify --quiet "${CONFIG[b_commit]}^{commit}" >/dev/null; then
		echo "Error: '${CONFIG[b_commit]}' is not a valid commit-ish." >&2
		exit 2
	fi

	if ! git merge-base --is-ancestor "${CONFIG[a_commit]}" "${CONFIG[b_commit]}"; then
		echo "Error: expected A to be an ancestor of B, but got A='${CONFIG[a_commit]}' and B='${CONFIG[b_commit]}'." >&2
		echo "Hint: swap commits if they were provided in reverse order: $0 [-o output.pdf] ${CONFIG[b_commit]} ${CONFIG[a_commit]}" >&2
		exit 2
	fi

	local a_resolved
	a_resolved="$(git rev-parse "${CONFIG[a_commit]}^{commit}")"
	if ! grep -Fxq "$a_resolved" < <(git rev-list --first-parent "${CONFIG[b_commit]}"); then
		echo "Error: first-parent path of B ('${CONFIG[b_commit]}') does not include A ('${CONFIG[a_commit]}')." >&2
		echo "Hint: choose an A commit from B's first-parent history (or swap commits if reversed)." >&2
		exit 2
	fi
}

validate_demo_files() {
	if [[ "${CONFIG[include_demo]}" == true ]]; then
		if [[ ! -f "${CONFIG[demo_old]}" ]]; then
			echo "Error: demo old file not found: ${CONFIG[demo_old]}" >&2
			exit 2
		fi
		if [[ ! -f "${CONFIG[demo_new]}" ]]; then
			echo "Error: demo new file not found: ${CONFIG[demo_new]}" >&2
			exit 2
		fi
	fi
}

synthesize_default_history_plan() {
	if [[ -n "${CONFIG[history_plan_source]}" ]]; then
		return 0
	fi

	local commits sha subject
	mapfile -t commits < <(git rev-list --first-parent --reverse "${CONFIG[a_commit]}..${CONFIG[b_commit]}")
	CONFIG[history_plan_content]=""
	for sha in "${commits[@]}"; do
		subject="$(git show -s --format='%s' "$sha")"
		HISTORY_PLAN_CONTENT+="pick ${sha} # ${subject}"$'\n'
	done
}

interactive_edit_history_plan() {
	[[ "${CONFIG[interactive_mode]}" -eq 1 ]] || return 0

	local editor
	editor="${EDITOR:-vi}"

	local tmp
	tmp="$(mktemp)"
	trap 'rm -f "'$tmp'"' RETURN

	{
		echo "# Reorder and edit commits to shape this report."
		echo "#"
		echo "# Allowed actions: pick, drop, squash, bundle"
		echo "#   pick <hash>                     include commit with full diff"
		echo "#   drop <hash> %reason            omit commit diff, show drop marker and reason"
		echo "#   squash <hash>                  combine contiguous squash commits into one diff"
		echo "#   bundle <hash> %SECTION NAME    wrap contiguous bundle commits in section markers"
		echo "#"
		echo "# Syntax notes:"
		echo "#   - %reason is valid for drop"
		echo "#   - %SECTION is required on the first commit of each bundle run"
		echo "#   - optional '# message' text is ignored by the parser"
		echo "#"
		echo "# Warning: 'drop' skips rendering that commit's diff and can hide changes."
		echo "# Range: ${CONFIG[a_commit]}..${CONFIG[b_commit]} (first-parent)."
		echo ""
		printf '%s' "${CONFIG[history_plan_content]}"
	} >"$tmp"

	while true; do
		"$editor" "$tmp"
		CONFIG[history_plan_content]="$(cat "$tmp")"

		if (parse_history_plan_records) >/dev/null 2>"$tmp.err"; then
			break
		fi

		echo "Error: invalid interactive history plan." >&2
		cat "$tmp.err" >&2

		if [[ -t 0 && -t 1 ]]; then
			printf "Re-open editor to fix the plan? [Y/n]: " >&2
			local retry
			IFS= read -r retry || retry=""
			if [[ "$retry" =~ ^[Nn]$ ]]; then
				echo "Aborted due to invalid interactive history plan. Fix the file and rerun with --history-plan-file." >&2
				exit 2
			fi
		else
			echo "Cannot prompt for retry in non-interactive shell. Re-run with --history-plan-file after fixing the plan." >&2
			exit 2
		fi
	done

	rm -f "$tmp.err"
}

history_plan_parse_error() {
	local line_no="$1"
	local line_content="$2"
	local message="$3"
	echo "Error: history plan line ${line_no}: ${message}" >&2
	echo "  Offending line: ${line_content}" >&2
	exit 2
}

parse_history_plan_records() {
	# Produces machine-friendly TSV rows:
	# action<TAB>resolved_sha<TAB>reason<TAB>section_name<TAB>display_message
	local -a range_commits
	mapfile -t range_commits < <(git rev-list --first-parent --reverse "${CONFIG[a_commit]}..${CONFIG[b_commit]}")

	local -A range_index=()
	local idx sha
	for idx in "${!range_commits[@]}"; do
		sha="${range_commits[$idx]}"
		range_index["$sha"]="$idx"
	done

	local line_no=0
	local last_index=-1
	local last_action=""
	local current_bundle_section=""
	local rows=""
	local -A seen_commits=()
	local line raw action short_sha tail resolved_sha annotation message reason section_name

	PLAN_HAS_DROP=false
	PLAN_HAS_SQUASH=false
	PLAN_HAS_BUNDLE=false

	while IFS= read -r line || [[ -n "$line" ]]; do
		line_no=$((line_no + 1))
		raw="$line"

		if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
			continue
		fi

		if [[ ! "$line" =~ ^[[:space:]]*([[:alpha:]]+)[[:space:]]+([0-9a-fA-F]{7,40})([[:space:]].*)?$ ]]; then
			history_plan_parse_error "$line_no" "$raw" "expected '<action> <hash> [%annotation] [# message]'"
		fi

		action="${BASH_REMATCH[1]}"
		short_sha="${BASH_REMATCH[2]}"
		tail="${BASH_REMATCH[3]}"

		case "$action" in
		pick | drop | squash | bundle) ;;
		*) history_plan_parse_error "$line_no" "$raw" "invalid action '${action}' (expected pick/drop/squash/bundle)" ;;
		esac

		case "$action" in
		drop) PLAN_HAS_DROP=true ;;
		squash) PLAN_HAS_SQUASH=true ;;
		bundle) PLAN_HAS_BUNDLE=true ;;
		esac

		if ! resolved_sha="$(git rev-parse --verify --quiet "${short_sha}^{commit}")"; then
			history_plan_parse_error "$line_no" "$raw" "invalid commit hash '${short_sha}'"
		fi
		if [[ -z "${range_index[$resolved_sha]+x}" ]]; then
			history_plan_parse_error "$line_no" "$raw" "commit '${short_sha}' not in ${CONFIG[a_commit]}..${CONFIG[b_commit]} first-parent range"
		fi
		if [[ -n "${seen_commits[$resolved_sha]+x}" ]]; then
			history_plan_parse_error "$line_no" "$raw" "commit '${short_sha}' appears more than once"
		fi
		if ((range_index[$resolved_sha] <= last_index)); then
			history_plan_parse_error "$line_no" "$raw" "commit order does not match ${CONFIG[a_commit]}..${CONFIG[b_commit]} first-parent order"
		fi
		seen_commits["$resolved_sha"]=1
		last_index="${range_index[$resolved_sha]}"

		tail="${tail:-}"
		tail="${tail#${tail%%[![:space:]]*}}"
		annotation=""
		message=""
		if [[ -n "$tail" ]]; then
			if [[ "$tail" =~ ^%([^#]*[^[:space:]#]|[^#[:space:]])[[:space:]]*(#(.*))?$ ]]; then
				annotation="${BASH_REMATCH[1]}"
				message="${BASH_REMATCH[3]}"
			elif [[ "$tail" =~ ^#[[:space:]]*(.*)$ ]]; then
				message="${BASH_REMATCH[1]}"
			else
				history_plan_parse_error "$line_no" "$raw" "could not parse annotation/message segment '${tail}'"
			fi
		fi

		reason=""
		section_name=""
		case "$action" in
		drop)
			reason="$annotation"
			last_action="$action"
			current_bundle_section=""
			;;
		bundle)
			if [[ "$last_action" != "bundle" ]]; then
				if [[ -z "$annotation" ]]; then
					history_plan_parse_error "$line_no" "$raw" "first commit in a bundle run must include %SECTION"
				fi
				current_bundle_section="$annotation"
			elif [[ -n "$annotation" ]]; then
				current_bundle_section="$annotation"
			fi
			section_name="$current_bundle_section"
			last_action="$action"
			;;
		pick | squash)
			if [[ -n "$annotation" ]]; then
				history_plan_parse_error "$line_no" "$raw" "annotation '%${annotation}' is only valid for drop/bundle"
			fi
			last_action="$action"
			current_bundle_section=""
			;;
		esac

		rows+="${action}"$'\t'"${resolved_sha}"$'\t'"${reason}"$'\t'"${section_name}"$'\t'"${message}"$'\n'
	done <<<"${CONFIG[history_plan_content]}"

	CONFIG[history_plan_parsed_tsv]="$rows"
}

history_plan_to_commit_list() {
	# Writes one SHA per line to stdout (excluding drop actions).
	local action sha _reason _section _message
	while IFS=$'	' read -r action sha _reason _section _message; do
		[[ -n "$action" ]] || continue
		if [[ "$action" != "drop" ]]; then
			echo "$sha"
		fi
	done <<<"${CONFIG[history_plan_parsed_tsv]}"
}

render_html_header() {
	local html_path="$1"
	local repo_name
	repo_name="$(basename "$(git rev-parse --show-toplevel)")"

	cat >"$html_path" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Git Diff Report</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  body { background: #ffffff; color:#111; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace; line-height: 1.4; margin: 2rem; }
  h1, h2, h3, h4 { font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif; }
  .meta { color: #555; margin-bottom: 0.75rem; }
  .commit-block { page-break-after: always; margin-bottom: 2rem; }
  .commit-msg { white-space: pre-wrap; background: #f6f8fa; border: 1px solid #eaecef; padding: 1rem; border-radius: 8px; }
  .pagebreak { page-break-after: always; }
  .diff { border: 1px solid #eaecef; border-radius: 8px; overflow: hidden; }
  hr.sep { margin: 2rem 0; border: none; border-top: 1px solid #ddd; }
  pre { margin: 0; padding: 1rem; }
  .table2 { width: 100%; table-layout: fixed; border-collapse: separate; border-spacing: 16px 0; }
  .table2 td { width: 50%; vertical-align: top; }
  .banner {
    border-radius: 8px;
    border: 2px solid #b42318;
    background: #fef3f2;
    color: #7a271a;
    padding: 1rem;
    margin: 0 0 1rem 0;
    font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;
  }
  pre.code {
    white-space: pre;
    word-break: normal;
    overflow-wrap: normal;
    overflow-x: auto;
    overflow-y: hidden;
    background: #f6f8fa;
    border: 1px solid #eaecef;
    border-radius: 8px;
    padding: 1rem;
  }
</style>
</head>
<body>
<h1>Git Diff Report</h1>
HTML

	cat >>"$html_path" <<HTML
<p class="meta"><strong>Repository:</strong> $(html_escape_arg "$repo_name")<br>
<strong>Range:</strong> $(html_escape_arg "${CONFIG[a_commit]}")..$(html_escape_arg "${CONFIG[b_commit]}") (first-parent, oldest → newest)</p>
HTML

	if [[ "${PLAN_HAS_DROP}" == true ]]; then
		cat >>"$html_path" <<'HTML'
<div class="banner">
  <strong>Important review warning:</strong> Some commits are configured as <code>drop</code>. Diffs into and out of those commits are intentionally omitted in this report. Reviewers must explicitly trust those hidden transitions.
</div>
HTML
	fi

	cat >>"$html_path" <<HTML
<hr class="sep">
HTML
}

render_demo_section() {
	local html_path="$1"
	[[ "${CONFIG[include_demo]}" == true ]] || return 0

	local esc_old esc_new
	esc_old="$(html_escape_arg "${CONFIG[demo_old]}")"
	esc_new="$(html_escape_arg "${CONFIG[demo_new]}")"

	{
		echo '<h2>How to read diffs?</h2>'
		echo "<p>In the toy example below, we compare <code>${esc_old}</code> → <code>${esc_new}</code>."
		echo 'Green lines are additions, red lines are deletions. Inline highlights mark changed words or whitespace.</p>'

		echo '<h3>The compared files</h3>'
		echo '<table class="table2"><tr>'

		echo "<td><h4>${esc_old}</h4>"
		printf '<pre class="code">%s</pre>\n' "$(html_escape_arg "$(cat "${CONFIG[demo_old]}")")"
		echo '</td>'

		echo "<td><h4>${esc_new}</h4>"
		printf '<pre class="code">%s</pre>\n' "$(html_escape_arg "$(cat "${CONFIG[demo_new]}")")"
		echo '</td>'

		echo '</tr></table>'

		echo '<h3>Example diff</h3>'
		echo '<div class="diff">'
		if [[ "$HAS_DELTA" == true && "$HAS_AHA" == true ]]; then
			git diff --no-index --no-ext-diff "${CONFIG[demo_old]}" "${CONFIG[demo_new]}" |
				delta "${DELTA_DEMO_OPTIONS[@]}" --syntax-theme="$DELTA_THEME" |
				aha --line-fix || true
		else
			git diff --no-color --no-index --no-ext-diff "${CONFIG[demo_old]}" "${CONFIG[demo_new]}" |
				html_escape_stream |
				awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' || true
		fi
		echo '</div>'
		echo '<hr class="sep">'
		echo '<div class="pagebreak"></div>'
	} >>"$html_path"
}

render_commit_block() {
	local html_path="$1"
	local commit_sha="$2"
	local workdir="$3"

	local commit_abbr parent diff_html_snippet
	commit_abbr="$(git rev-parse --short "$commit_sha")"

	if git rev-parse --verify --quiet "${commit_sha}^1" >/dev/null; then
		parent="${commit_sha}^1"
	else
		parent="$EMPTY_TREE_HASH"
	fi

	local author_name author_email author_date commit_msg
	{
		IFS= read -r -d '' author_name
		IFS= read -r -d '' author_email
		IFS= read -r -d '' author_date
		IFS= read -r -d '' commit_msg
	} < <(git log -1 --date=iso-strict --format='%an%x00%ae%x00%ad%x00%B%x00' "$commit_sha")

	diff_html_snippet="$workdir/diff-${commit_abbr}.html"

	if [[ "$HAS_DELTA" == true && "$HAS_AHA" == true ]]; then
		if ! git diff --no-ext-diff "${parent}" "${commit_sha}" |
			delta "${DELTA_COMMIT_OPTIONS[@]}" --syntax-theme="$DELTA_THEME" |
			aha --line-fix >"$diff_html_snippet"; then
			echo "Warning: diff for ${commit_abbr} failed; including plain text." >&2
			git diff --no-ext-diff "${parent}" "${commit_sha}" |
				html_escape_stream |
				awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' >"$diff_html_snippet"
		fi
	else
		git diff --no-ext-diff "${parent}" "${commit_sha}" |
			html_escape_stream |
			awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' >"$diff_html_snippet"
	fi

	{
		echo '<div class="commit-block">'
		echo "  <h2>Commit: $(html_escape_arg "$commit_abbr")</h2>"
		echo "  <p class=\"meta\"><strong>Author:</strong> $(html_escape_arg "$author_name") &lt;$(html_escape_arg "$author_email")&gt;<br>"
		echo "  <strong>Date:</strong> $(html_escape_arg "$author_date")</p>"
		echo '  <h3>Commit message</h3>'
		printf '  <div class="commit-msg">%s</div>\n' "$(html_escape_arg "$commit_msg")"
		echo '  <h3>Changes (diff against parent)</h3>'
		echo '  <div class="diff">'
		cat "$diff_html_snippet"
		echo '  </div>'
		echo '</div>'
	} >>"$html_path"
}

render_drop_block() {
	local html_path="$1"
	local commit_sha="$2"
	local reason="$3"

	local commit_abbr author_name author_email author_date commit_msg
	commit_abbr="$(git rev-parse --short "$commit_sha")"

	{
		IFS= read -r -d '' author_name
		IFS= read -r -d '' author_email
		IFS= read -r -d '' author_date
		IFS= read -r -d '' commit_msg
	} < <(git log -1 --date=iso-strict --format='%an%x00%ae%x00%ad%x00%B%x00' "$commit_sha")

	{
		echo '<div class="commit-block">'
		echo "  <h2>Commit: $(html_escape_arg "$commit_abbr")</h2>"
		echo "  <p class=\"meta\"><strong>Author:</strong> $(html_escape_arg "$author_name") &lt;$(html_escape_arg "$author_email")&gt;<br>"
		echo "  <strong>Date:</strong> $(html_escape_arg "$author_date")</p>"
		echo '  <h3>Commit message</h3>'
		printf '  <div class="commit-msg">%s</div>\n' "$(html_escape_arg "$commit_msg")"
		echo '  <h3>Diff status</h3>'
		if [[ -n "$reason" ]]; then
			printf '  <div class="commit-msg"><strong>Drop reason:</strong> %s</div>\n' "$(html_escape_arg "$reason")"
		else
			echo '  <div class="commit-msg"><strong>Drop reason:</strong> no reason provided</div>'
		fi
		echo '  <div class="commit-msg"><strong>Omission notice:</strong> Diffs into and out of this commit are intentionally omitted. Reviewers must trust this hidden transition.</div>'
		echo '</div>'
	} >>"$html_path"
}

render_squash_block() {
	local html_path="$1"
	local workdir="$2"
	shift 2
	local -a squash_commits=("$@")

	[[ ${#squash_commits[@]} -gt 0 ]] || return 0

	local first_commit last_commit parent diff_html_snippet first_abbr last_abbr
	first_commit="${squash_commits[0]}"
	last_commit="${squash_commits[${#squash_commits[@]}-1]}"
	first_abbr="$(git rev-parse --short "$first_commit")"
	last_abbr="$(git rev-parse --short "$last_commit")"

	if git rev-parse --verify --quiet "${first_commit}^1" >/dev/null; then
		parent="${first_commit}^1"
	else
		parent="$EMPTY_TREE_HASH"
	fi

	diff_html_snippet="$workdir/diff-squash-${first_abbr}-${last_abbr}.html"
	if [[ "$HAS_DELTA" == true && "$HAS_AHA" == true ]]; then
		if ! git diff --no-ext-diff "${parent}" "${last_commit}" |
			delta "${DELTA_COMMIT_OPTIONS[@]}" --syntax-theme="$DELTA_THEME" |
			aha --line-fix >"$diff_html_snippet"; then
			echo "Warning: squash diff for ${first_abbr}..${last_abbr} failed; including plain text." >&2
			git diff --no-ext-diff "${parent}" "${last_commit}" |
				html_escape_stream |
				awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' >"$diff_html_snippet"
		fi
	else
		git diff --no-ext-diff "${parent}" "${last_commit}" |
			html_escape_stream |
			awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' >"$diff_html_snippet"
	fi

	{
		echo '<div class="commit-block">'
		echo "  <h2>Squashed commits: $(html_escape_arg "$first_abbr")..$(html_escape_arg "$last_abbr")</h2>"
		echo '  <p class="meta"><strong>Combined diff:</strong> parent(first commit) → last commit in squash run</p>'
		echo '  <div class="commit-msg"><strong>Why grouped:</strong> These commits are grouped for readability. <strong>Scope change:</strong> this report shows one combined diff from the parent of the first squashed commit to the last squashed commit, so intermediate commit-to-commit transitions are not shown separately.</div>'
		echo '  <h3>Included commits</h3>'
	} >>"$html_path"

	local commit_sha commit_abbr author_name author_email author_date commit_msg
	for commit_sha in "${squash_commits[@]}"; do
		commit_abbr="$(git rev-parse --short "$commit_sha")"
		{
			IFS= read -r -d '' author_name
			IFS= read -r -d '' author_email
			IFS= read -r -d '' author_date
			IFS= read -r -d '' commit_msg
		} < <(git log -1 --date=iso-strict --format='%an%x00%ae%x00%ad%x00%B%x00' "$commit_sha")

		{
			echo "  <h4>Commit: $(html_escape_arg "$commit_abbr")</h4>"
			echo "  <p class=\"meta\"><strong>Author:</strong> $(html_escape_arg "$author_name") &lt;$(html_escape_arg "$author_email")&gt;<br>"
			echo "  <strong>Date:</strong> $(html_escape_arg "$author_date")</p>"
			printf '  <div class="commit-msg">%s</div>\n' "$(html_escape_arg "$commit_msg")"
		} >>"$html_path"
	done

	{
		echo '  <h3>Changes (single unified diff for squash run)</h3>'
		echo '  <div class="diff">'
		cat "$diff_html_snippet"
		echo '  </div>'
		echo '</div>'
	} >>"$html_path"
}

render_bundle_boundary() {
	local html_path="$1"
	local section_name="$2"
	local boundary_type="$3"
	local label

	if [[ "$boundary_type" == "begin" ]]; then
		label="BEGINNING OF SECTION ${section_name}"
	else
		label="END OF SECTION ${section_name}"
	fi

	{
		echo '<div class="commit-block">'
		echo "  <h2>$(html_escape_arg "$label")</h2>"
		if [[ "$boundary_type" == "begin" ]]; then
			echo '  <div class="commit-msg"><strong>Why grouped:</strong> These commits are bundled for readability. <strong>Scope change:</strong> there is no diff-scope reduction here—each bundled commit still shows its own diff against its parent.</div>'
		fi
		echo '</div>'
	} >>"$html_path"
}

emit_drop_cli_warning() {
	if [[ "${PLAN_HAS_DROP}" == true ]]; then
		echo "Some commits are configured as drop; diffs into/out of those commits are intentionally omitted. Reviewers must trust these hidden transitions." >&2
	fi
}

generate_diff_html() {
	local html_path="$1"
	local workdir="$2"

	local -a commits
	mapfile -t commits < <(git rev-list --first-parent --reverse "${CONFIG[a_commit]}..${CONFIG[b_commit]}")

	if [[ ${#commits[@]} -eq 0 ]]; then
		echo "No commits found (after applying history plan, if any)." >&2
		cat >>"$html_path" <<'HTML'
<p>No commits found in the specified range.</p>
</body></html>
HTML
		return 0
	fi

	if [[ -z "${CONFIG[history_plan_parsed_tsv]}" ]]; then
		local c
		for c in "${commits[@]}"; do
			render_commit_block "$html_path" "$c" "$workdir"
		done
	else
		local -a plan_actions=() plan_shas=() plan_reasons=() plan_sections=()
		local action sha reason section _message
		while IFS=$'\t' read -r action sha reason section _message; do
			[[ -n "$action" ]] || continue
			plan_actions+=("$action")
			plan_shas+=("$sha")
			plan_reasons+=("$reason")
			plan_sections+=("$section")
		done <<<"${CONFIG[history_plan_parsed_tsv]}"

		local i run_end
		i=0
		while ((i < ${#plan_actions[@]})); do
			action="${plan_actions[$i]}"
			sha="${plan_shas[$i]}"
			reason="${plan_reasons[$i]}"
			section="${plan_sections[$i]}"

			case "$action" in
			pick)
				render_commit_block "$html_path" "$sha" "$workdir"
				i=$((i + 1))
				;;
			drop)
				render_drop_block "$html_path" "$sha" "$reason"
				i=$((i + 1))
				;;
			squash)
				run_end=$i
				while ((run_end + 1 < ${#plan_actions[@]})) && [[ "${plan_actions[$((run_end + 1))]}" == "squash" ]]; do
					run_end=$((run_end + 1))
				done
				local -a squash_commits=()
				while ((i <= run_end)); do
					squash_commits+=("${plan_shas[$i]}")
					i=$((i + 1))
				done
				render_squash_block "$html_path" "$workdir" "${squash_commits[@]}"
				;;
			bundle)
				run_end=$i
				while ((run_end + 1 < ${#plan_actions[@]})) && [[ "${plan_actions[$((run_end + 1))]}" == "bundle" ]]; do
					run_end=$((run_end + 1))
				done
				render_bundle_boundary "$html_path" "$section" "begin"
				while ((i <= run_end)); do
					render_commit_block "$html_path" "${plan_shas[$i]}" "$workdir"
					i=$((i + 1))
				done
				render_bundle_boundary "$html_path" "$section" "end"
				;;
			esac
		done
	fi

	cat >>"$html_path" <<'HTML'
</body>
</html>
HTML
}


resolve_html_output_path() {
	local html_out
	if [[ "${CONFIG[html_output_requested]}" -eq 1 ]]; then
		case "${CONFIG[html_output]}" in
			/*)
				html_out="${CONFIG[html_output]}"
				;;
			*)
				html_out="$(dirname -- "${CONFIG[output_abs]}")/${CONFIG[html_output]}"
				;;
		esac
	else
		html_out="${CONFIG[output_abs]%.pdf}.html"
	fi
	printf '%s\n' "$html_out"
}

generate_output() {
	local workdir html should_generate_pdf should_generate_html
	workdir="$(mktemp -d)"
	html="${workdir}/report.html"
	trap 'rm -rf "'"$workdir"'"' EXIT

	render_html_header "$html"
	render_demo_section "$html"
	generate_diff_html "$html" "$workdir"

	if [[ "$HAS_WKHTMLTOPDF" == true && ${CONFIG[html_only]} -ne 1 ]]; then
		should_generate_pdf=1
	else
		should_generate_pdf=0
	fi

	if [[ ${CONFIG[html_only]} -eq 1 || ${CONFIG[html_output_requested]} -eq 1 || "$HAS_WKHTMLTOPDF" != true ]]; then
		should_generate_html=1
	else
		should_generate_html=0
	fi

	if [[ "$should_generate_pdf" -eq 1 ]]; then
		prevent_overwrites "${CONFIG[output_abs]}"
		wkhtmltopdf "$html" "${CONFIG[output_abs]}"
		echo "✅ Wrote report to: ${CONFIG[output_abs]}"
	fi

	if [[ "$should_generate_html" -eq 1 ]]; then
		local html_out
		html_out="$(resolve_html_output_path)"
		prevent_overwrites "$html_out"
		cp "$html" "$html_out"

		if [[ "$HAS_WKHTMLTOPDF" != true && ${CONFIG[html_only]} -ne 1 ]]; then
			# only report fallback if HTML was not requested by --html-only
			echo "⚠️ wkhtmltopdf not found. Wrote HTML report instead: ${html_out}"
			echo "   Convert later with: wkhtmltopdf ${html_out} ${CONFIG[output]}"
		else
			echo "✅ Wrote HTML report to: ${html_out}"
		fi
	fi

}

main() {
	set -euo pipefail

	parse_args "$@"
	check_dependencies
	validate_commits

	synthesize_default_history_plan
	interactive_edit_history_plan
	if [[ -n "${CONFIG[history_plan_content]}" ]]; then
		parse_history_plan_records
	fi
	emit_drop_cli_warning

	validate_demo_files

	generate_output

}

main "$@"
