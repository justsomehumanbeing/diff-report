#!/usr/bin/env bash

# git-diff-report.sh
# Build a pretty PDF report of per-commit diffs along first-parent from A (exclusive) to B (inclusive).
# Optional: include a demo "how to read diffs" section comparing two standalone files.
# Usage:
#   git-diff-report.sh [-o output.pdf] [--include-demo [--demo-old path --demo-new path]] <A> <B>

readonly DEFAULT_OUTPUT_FILENAME="diff-report.pdf"
readonly EMPTY_TREE_HASH="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
readonly DELTA_THEME="gruvbox-light"
readonly DELTA_DEMO_OPTIONS=(--paging=never --wrap-max-lines=0 --true-color=always)
readonly DELTA_COMMIT_OPTIONS=(--paging=never --wrap-max-lines=0 --width=200 --true-color=always)

usage() {
  local exit_code="${1:-1}"
  echo "Usage: $0 [-o output.pdf] [--force] [--include-demo [--demo-old path --demo-new path]] [--interactive [<A> [<B>]] | <A> <B>]"
  echo "  -o, --output        Output PDF file (default: ${DEFAULT_OUTPUT_FILENAME})"
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
  echo ""
  echo "Range semantics:"
  echo "  - A must be an ancestor of B."
  echo "  - A must be on B's first-parent chain."
  echo "  - Commits are collected from A..B on first-parent history"
  echo "    (A excluded, B included, oldest → newest)."
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

# Defaults
OUTPUT="$DEFAULT_OUTPUT_FILENAME"
FORCE_OVERWRITE=0
INCLUDE_DEMO=false
DEMO_OLD="testfileold"
DEMO_NEW="testfilenew"
A_COMMIT=""
B_COMMIT=""
INTERACTIVE_MODE=0
HISTORY_PLAN_SOURCE=""
HISTORY_PLAN_FILE=""
HISTORY_PLAN_CONTENT=""

# Dependency flags (set by check_dependencies)
HAS_DELTA=false
HAS_AHA=false
HAS_WKHTMLTOPDF=false

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
	
	if [[ "$2" -eq 1 ]]; then
		FILE="$1"
	elif [[ "$2" -eq 0 ]]; then
		FILE="${1%.pdf}.html"
	else
		echo "fatal error, unknown internal option" >&2
		exit 1
	fi
	

	if [[ -e "$1" && "$FORCE_OVERWRITE" -ne 1 ]]; then
	  echo "Warning: output file already exists: $1" >&2
	  echo "Refusing to overwrite without --force." >&2
	  exit 2
	fi

	echo "Output target (absolute): $1"
}

parse_args() {
  OUTPUT="$DEFAULT_OUTPUT_FILENAME"
  INCLUDE_DEMO=false
  DEMO_OLD="testfileold"
  DEMO_NEW="testfilenew"
  A_COMMIT=""
  B_COMMIT=""
  INTERACTIVE_MODE=0
  HISTORY_PLAN_SOURCE=""
  HISTORY_PLAN_FILE=""
  HISTORY_PLAN_CONTENT=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o|--output)
        shift
        [[ $# -gt 0 ]] || usage
        OUTPUT="$1"
        shift
        ;;
	-f|--force)
		FORCE_OVERWRITE=1
		shift
		;;
      --include-demo)
        INCLUDE_DEMO=true
        shift
        ;;
      --demo-old)
        shift
        [[ $# -gt 0 ]] || usage
        DEMO_OLD="$1"
        shift
        ;;
      --demo-new)
        shift
        [[ $# -gt 0 ]] || usage
        DEMO_NEW="$1"
        shift
        ;;
      --interactive)
        if [[ -n "$HISTORY_PLAN_SOURCE" && "$HISTORY_PLAN_SOURCE" != "interactive" ]]; then
          echo "Error: interactive mode cannot be combined with another history plan source." >&2
          usage
        fi
        HISTORY_PLAN_SOURCE="interactive"
        INTERACTIVE_MODE=1
        shift
        if [[ $# -gt 0 && "$1" != -* ]]; then
          if [[ -n "${A_COMMIT:-}" ]]; then
            echo "Error: duplicate A commit provided (positional and --interactive)." >&2
            usage
          fi
          A_COMMIT="$1"
          shift
          if [[ $# -gt 0 && "$1" != -* ]]; then
            if [[ -n "${B_COMMIT:-}" ]]; then
              echo "Error: duplicate B commit provided (positional and --interactive)." >&2
              usage
            fi
            B_COMMIT="$1"
            shift
          fi
        fi
        ;;
      --history-plan-file|--detailed-commit-history-file)
        if [[ -n "$HISTORY_PLAN_SOURCE" && "$HISTORY_PLAN_SOURCE" != "file" ]]; then
          echo "Error: choose at most one history plan source (interactive, file, or stdin)." >&2
          usage
        fi
        HISTORY_PLAN_SOURCE="file"
        shift
        [[ $# -gt 0 ]] || usage
        HISTORY_PLAN_FILE="$1"
        shift
        ;;
      --history-plan-stdin|--detailed-commit-history-stdin)
        if [[ -n "$HISTORY_PLAN_SOURCE" && "$HISTORY_PLAN_SOURCE" != "stdin" ]]; then
          echo "Error: choose at most one history plan source (interactive, file, or stdin)." >&2
          usage
        fi
        HISTORY_PLAN_SOURCE="stdin"
        shift
        ;;
      -h|--help)
        usage 0
        ;;
      -*)
        echo "Unknown option: $1" >&2
        echo "Try '$0 --help' for usage." >&2
        usage
        ;;
      *)
        if [[ -z "${A_COMMIT:-}" ]]; then
          A_COMMIT="$1"
        elif [[ -z "${B_COMMIT:-}" ]]; then
          B_COMMIT="$1"
        else
          echo "Too many positional arguments." >&2
          usage
        fi
        shift
        ;;
    esac
  done

  if [[ "$INTERACTIVE_MODE" -eq 1 ]]; then
    if [[ -z "${B_COMMIT:-}" ]]; then
      B_COMMIT="HEAD"
    fi
    if [[ -z "${A_COMMIT:-}" ]]; then
      A_COMMIT="$(git rev-list --max-parents=0 "$B_COMMIT" | tail -n 1)"
    fi
  fi

  : "${A_COMMIT:?Missing A}"
  : "${B_COMMIT:?Missing B}"

  case "$HISTORY_PLAN_SOURCE" in
    file)
      if [[ ! -f "$HISTORY_PLAN_FILE" ]]; then
        echo "Error: history plan file not found: $HISTORY_PLAN_FILE" >&2
        exit 2
      fi
      HISTORY_PLAN_CONTENT="$(cat "$HISTORY_PLAN_FILE")"
      ;;
    stdin)
      HISTORY_PLAN_CONTENT="$(cat)"
      ;;
    interactive|"")
      ;;
    *)
      echo "fatal error, unknown history plan source: $HISTORY_PLAN_SOURCE" >&2
      exit 1
      ;;
  esac

  # demo args validation
  if [[ "$INCLUDE_DEMO" != true && ( "$DEMO_OLD" != "testfileold" || "$DEMO_NEW" != "testfilenew" ) ]]; then
    echo "Error: --demo-old/--demo-new require --include-demo." >&2
    usage
  fi

	# Normalize output path once so all write-sites use the same target.
	if command -v realpath >/dev/null 2>&1; then
	  OUTPUT_ABS="$(realpath -m "$OUTPUT")"
	else
	  OUTPUT_ABS="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$OUTPUT")"
	fi

	prevent_overwrites "$OUTPUT_ABS" 0

}

synthesize_default_history_plan() {
  if [[ -n "$HISTORY_PLAN_SOURCE" ]]; then
    return 0
  fi

  local commits sha subject
  mapfile -t commits < <(git rev-list --first-parent --reverse "${A_COMMIT}..${B_COMMIT}")
  HISTORY_PLAN_CONTENT=""
  for sha in "${commits[@]}"; do
    subject="$(git show -s --format='%s' "$sha")"
    HISTORY_PLAN_CONTENT+="pick ${sha} ${subject}"$'\n'
  done
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
  if ! git rev-parse --verify --quiet "$A_COMMIT^{commit}" >/dev/null; then
    echo "Error: '$A_COMMIT' is not a valid commit-ish." >&2
    exit 2
  fi
  if ! git rev-parse --verify --quiet "$B_COMMIT^{commit}" >/dev/null; then
    echo "Error: '$B_COMMIT' is not a valid commit-ish." >&2
    exit 2
  fi

  if ! git merge-base --is-ancestor "$A_COMMIT" "$B_COMMIT"; then
    echo "Error: expected A to be an ancestor of B, but got A='$A_COMMIT' and B='$B_COMMIT'." >&2
    echo "Hint: swap commits if they were provided in reverse order: $0 [-o output.pdf] $B_COMMIT $A_COMMIT" >&2
    exit 2
  fi

  local a_resolved
  a_resolved="$(git rev-parse "$A_COMMIT^{commit}")"
  if ! git rev-list --first-parent "$B_COMMIT" | grep -Fxq "$a_resolved"; then
    echo "Error: first-parent path of B ('$B_COMMIT') does not include A ('$A_COMMIT')." >&2
    echo "Hint: choose an A commit from B's first-parent history (or swap commits if reversed)." >&2
    exit 2
  fi
}

validate_demo_files() {
  if [[ "$INCLUDE_DEMO" == true ]]; then
    if [[ ! -f "$DEMO_OLD" ]]; then
      echo "Error: demo old file not found: $DEMO_OLD" >&2
      exit 2
    fi
    if [[ ! -f "$DEMO_NEW" ]]; then
      echo "Error: demo new file not found: $DEMO_NEW" >&2
      exit 2
    fi
  fi
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
<strong>Range:</strong> $(html_escape_arg "$A_COMMIT")..$(html_escape_arg "$B_COMMIT") (first-parent, oldest → newest)</p>
<hr class="sep">
HTML
}

render_demo_section() {
  local html_path="$1"
  [[ "$INCLUDE_DEMO" == true ]] || return 0

  local esc_old esc_new
  esc_old="$(html_escape_arg "$DEMO_OLD")"
  esc_new="$(html_escape_arg "$DEMO_NEW")"

  {
    echo '<h2>How to read diffs?</h2>'
    echo "<p>In the toy example below, we compare <code>${esc_old}</code> → <code>${esc_new}</code>."
    echo 'Green lines are additions, red lines are deletions. Inline highlights mark changed words or whitespace.</p>'

    echo '<h3>The compared files</h3>'
    echo '<table class="table2"><tr>'

    echo "<td><h4>${esc_old}</h4>"
    printf '<pre class="code">%s</pre>\n' "$(html_escape_arg "$(cat "$DEMO_OLD")")"
    echo '</td>'

    echo "<td><h4>${esc_new}</h4>"
    printf '<pre class="code">%s</pre>\n' "$(html_escape_arg "$(cat "$DEMO_NEW")")"
    echo '</td>'

    echo '</tr></table>'

    echo '<h3>Example diff</h3>'
    echo '<div class="diff">'
    if [[ "$HAS_DELTA" == true && "$HAS_AHA" == true ]]; then
      git diff --no-index --no-ext-diff "$DEMO_OLD" "$DEMO_NEW" \
        | delta "${DELTA_DEMO_OPTIONS[@]}" --syntax-theme="$DELTA_THEME" \
        | aha --line-fix || true
    else
      git diff --no-color --no-index --no-ext-diff "$DEMO_OLD" "$DEMO_NEW" \
        | html_escape_stream \
        | awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' || true
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
    if ! git diff --no-ext-diff "${parent}" "${commit_sha}" \
        | delta "${DELTA_COMMIT_OPTIONS[@]}" --syntax-theme="$DELTA_THEME" \
        | aha --line-fix >"$diff_html_snippet"; then
      echo "Warning: diff for ${commit_abbr} failed; including plain text." >&2
      git diff --no-ext-diff "${parent}" "${commit_sha}" \
        | html_escape_stream \
        | awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' >"$diff_html_snippet"
    fi
  else
    git diff --no-ext-diff "${parent}" "${commit_sha}" \
      | html_escape_stream \
      | awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' >"$diff_html_snippet"
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

generate_diff_html() {
  local html_path="$1"
  local workdir="$2"

  mapfile -t commits < <(git rev-list --first-parent --reverse "${A_COMMIT}..${B_COMMIT}")
  if [[ ${#commits[@]} -eq 0 ]]; then
    echo "No commits found in ${A_COMMIT}..${B_COMMIT} (first-parent)." >&2
    cat >>"$html_path" <<'HTML'
<p>No commits found in the specified range.</p>
</body></html>
HTML
    return 0
  fi

  local c
  for c in "${commits[@]}"; do
    render_commit_block "$html_path" "$c" "$workdir"
  done

  cat >>"$html_path" <<'HTML'
</body>
</html>
HTML
}

main() {
  set -euo pipefail

  parse_args "$@"
  check_dependencies
  validate_commits
  synthesize_default_history_plan
  validate_demo_files

  local workdir html
  workdir="$(mktemp -d)"
  html="${workdir}/report.html"
  trap 'rm -rf "'"$workdir"'"' EXIT

  render_html_header "$html"
  render_demo_section "$html"
  generate_diff_html "$html" "$workdir"

  if [[ "$HAS_WKHTMLTOPDF" == true ]]; then
    wkhtmltopdf "$html" "$OUTPUT_ABS"
    echo "✅ Wrote report to: ${OUTPUT_ABS}"
  else
    local html_out
    html_out="${OUTPUT_ABS%.pdf}.html"
	prevent_overwrites "$html_out" 1
    cp "$html" "$html_out"
    echo "⚠️ wkhtmltopdf not found. Wrote HTML report instead: ${html_out}"
    echo "   Convert later with: wkhtmltopdf ${html_out} ${OUTPUT}"
  fi
}

main "$@"
