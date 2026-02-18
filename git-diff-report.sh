#!/usr/bin/env bash

# git-diff-report.sh
# Build a pretty PDF report of per-commit diffs along first-parent from A (exclusive) to B (inclusive).
# Optional: include a demo "how to read diffs" section comparing two standalone files.
# Usage:
#   git-diff-report.sh [-o output.pdf] [--include-demo [--demo-old path --demo-new path]] <A> <B>
#
# Dependencies: git, delta, aha, wkhtmltopdf

readonly DEFAULT_OUTPUT_FILENAME="diff-report.pdf"
readonly EMPTY_TREE_HASH="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
readonly DELTA_THEME="gruvbox-light"
readonly DELTA_DEMO_OPTIONS=(--paging=never --wrap-max-lines=0 --true-color=always)
readonly DELTA_COMMIT_OPTIONS=(--paging=never --wrap-max-lines=0 --width=200 --true-color=always)

usage() {
  echo "Usage: $0 [-o output.pdf] [--include-demo [--demo-old path --demo-new path]] <A> <B>"
  echo "  -o, --output        Output PDF file (default: diff-report.pdf)"
  echo "      --include-demo  Include an optional demo section that explains diff colors"
  echo "      --demo-old      Path to demo old file (default: testfileold, requires --include-demo)"
  echo "      --demo-new      Path to demo new file (default: testfilenew, requires --include-demo)"
  echo ""
  echo "Range semantics:"
  echo "  - A must be an ancestor of B."
  echo "  - A must be on B's first-parent chain."
  echo "  - Commits are collected from A..B on first-parent history"
  echo "    (A excluded, B included, oldest to newest)."
  echo ""
  echo "By default, output only reflects git commit history in the selected range."
  echo "The demo section is opt-in and is not derived from commit history."
  exit 1
}

# html_escape <text>
# Input: raw text as $1. Output: escaped HTML text on stdout.
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Defaults
OUTPUT="$DEFAULT_OUTPUT_FILENAME"
INCLUDE_DEMO=false
DEMO_OLD="testfileold"
DEMO_NEW="testfilenew"
A_COMMIT=""
B_COMMIT=""

# parse_args "$@"
# Input: CLI args. Output: sets A_COMMIT, B_COMMIT, OUTPUT, INCLUDE_DEMO, DEMO_OLD, DEMO_NEW globals.
parse_args() {
  OUTPUT="$DEFAULT_OUTPUT_FILENAME"
  A_COMMIT=""
  B_COMMIT=""
  INCLUDE_DEMO=false
  DEMO_OLD="testfileold"
  DEMO_NEW="testfilenew"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      shift
      [[ $# -gt 0 ]] || usage
      OUTPUT="$1"
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
      DEMO_OLD_SET=true
      shift
      ;;
    --demo-new)
      shift
      [[ $# -gt 0 ]] || usage
      DEMO_NEW="$1"
      DEMO_NEW_SET=true
      shift
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      ;;
    *)
      # positional
      if [[ -z "${A_COMMIT:-}" ]]; then
        A_COMMIT="$1"
      elif [[ -z "${B_COMMIT:-}" ]]; then
        B_COMMIT="$1"
      else
        echo "Too many positional arguments."
        usage
        ;;
      *)
        # positional
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

  : "${A_COMMIT:?Missing A}"
  : "${B_COMMIT:?Missing B}"

  # demo args validation (from the other branch)
  if [[ "$INCLUDE_DEMO" != true && ( "$DEMO_OLD" != "testfileold" || "$DEMO_NEW" != "testfilenew" ) ]]; then
    echo "Error: --demo-old/--demo-new require --include-demo." >&2
    usage
  fi
}

# check_dependencies
# Input: none. Output: exits non-zero if required tools are unavailable.
check_dependencies() {
  for cmd in git delta aha wkhtmltopdf; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: '$cmd' not found in PATH." >&2
      exit 2
    fi
  done
}

# validate_commits
# Input: A_COMMIT/B_COMMIT globals. Output: exits non-zero on invalid/unsupported range.
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

# validate_demo_files
# Input: INCLUDE_DEMO, DEMO_OLD, DEMO_NEW globals.
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

# render_html_header <html_path>
# Input: output HTML path. Output: writes document header and range metadata.
render_html_header() {
  local html_path="$1"
  local repo_name
  repo_name="$(basename "$(git rev-parse --show-toplevel)")"

  cat > "$html_path" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Git Diff Report</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  body { background: #ffffff; color:#111; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace; line-height: 1.4; margin: 2rem; }
  h1, h2, h3 { font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif; }
  .meta { color: #555; margin-bottom: 0.75rem; }
  .commit-block { page-break-after: always; margin-bottom: 2rem; }
  .commit-msg { white-space: pre-wrap; background: #f6f8fa; border: 1px solid #eaecef; padding: 1rem; border-radius: 8px; }
  .pagebreak { page-break-after: always; }
  .diff { border: 1px solid #eaecef; border-radius: 8px; overflow: hidden; }
  hr.sep { margin: 2rem 0; border: none; border-top: 1px solid #ddd; }
  /* Make aha output blend in */
  pre { margin: 0; padding: 1rem; }

  .table2 {
    width: 100%;
    table-layout: fixed;
    border-collapse: separate;
    border-spacing: 16px 0;
  }
  .table2 td {
    width: 50%;
    vertical-align: top;
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
    font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  }
  code { white-space: pre-wrap; }
</style>
</head>
<body>
<h1>Git Diff Report</h1>
HTML

  cat >> "$html_path" <<HTML
<p class="meta"><strong>Repository:</strong> ${repo_name}<br>
<strong>Range:</strong> ${A_COMMIT}..${B_COMMIT} (first-parent, oldest → newest)</p>
<hr class="sep">
HTML
}

# render_demo_section <html_path>
# Input: output HTML path. Output: appends demo diff section if enabled.
render_demo_section() {
  local html_path="$1"

  [[ "$INCLUDE_DEMO" == true ]] || return 0

  local esc_old esc_new
  esc_old="$(html_escape "$DEMO_OLD")"
  esc_new="$(html_escape "$DEMO_NEW")"

  {
    echo '<h2>How to read diffs?</h2>'
    echo "<p>In the toy example below, we compare <code>${esc_old}</code> → <code>${esc_new}</code>."
    echo 'Green lines are additions, red lines are deletions. Inline highlights mark changed words or whitespace.</p>'

    echo '<h3>The compared files</h3>'
    echo '<table class="table2"><tr>'

    echo "<td><h4>${esc_old}</h4>"
    printf '<pre class="code">%s</pre>\n' "$(html_escape "$(cat "$DEMO_OLD")")"
    echo '</td>'

    echo "<td><h4>${esc_new}</h4>"
    printf '<pre class="code">%s</pre>\n' "$(html_escape "$(cat "$DEMO_NEW")")"
    echo '</td>'

    echo '</tr></table>'

    echo '<h3>Example diff</h3>'
    echo '<div class="diff">'
    # --no-index lets us diff two paths outside git; `|| true` so nonzero diff exit won’t kill the script.
    git diff --no-index --no-ext-diff "$DEMO_OLD" "$DEMO_NEW" \
      | delta "${DELTA_DEMO_OPTIONS[@]}" --syntax-theme="$DELTA_THEME" \
      | aha --line-fix || true
    echo '</div>'
    echo '<hr class="sep">'
    echo '<div class="pagebreak"></div>'
  } >> "$html_path"
}

# render_commit_block <html_path> <commit_sha> <workdir>
# Input: target HTML path + commit ID + temporary directory. Output: appends one commit block.
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
  if ! git diff --no-ext-diff "${parent}" "${commit_sha}" \
      | delta "${DELTA_COMMIT_OPTIONS[@]}" --syntax-theme="$DELTA_THEME" \
      | aha --line-fix > "$diff_html_snippet"; then
    echo "Warning: diff for ${commit_abbr} failed; including plain text." >&2
    git diff --no-ext-diff "${parent}" "${commit_sha}" \
      | html_escape "$(cat)" \
      | awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' > "$diff_html_snippet"
  fi

  {
    echo '<div class="commit-block">'
    echo "  <h2>Commit with Commit-Hash: ${commit_abbr}</h2>"
    echo "  <p class=\"meta\"><strong>Author:</strong> $(html_escape "$author_name") &lt;$(html_escape "$author_email")&gt;<br>"
    echo "  <strong>Date:</strong> ${author_date}</p>"
    echo '  <h3>Commit-Message</h3>'
    printf '  <div class="commit-msg">%s</div>\n' "$(html_escape "$commit_msg")"
    echo '  <h3>Changes made in this commit (diff against parent):</h3>'
    echo '  <div class="diff">'
    cat "$diff_html_snippet"
    echo '  </div>'
    echo '</div>'
  } >> "$html_path"
}

# generate_diff_html <html_path> <workdir>
# Input: target HTML path + temporary directory. Output: appends commit sections and closes document.
generate_diff_html() {
  local html_path="$1"
  local workdir="$2"

  mapfile -t commits < <(git rev-list --first-parent --reverse "${A_COMMIT}..${B_COMMIT}")
  if [[ ${#commits[@]} -eq 0 ]]; then
    echo "No commits found in ${A_COMMIT}..${B_COMMIT} (first-parent)." >&2
    cat >> "$html_path" <<'HTML'
<p>No commits found in the specified range.</p>
</body></html>
HTML
    return 0
  fi

  local c
  for c in "${commits[@]}"; do
    render_commit_block "$html_path" "$c" "$workdir"
  done

  cat >> "$html_path" <<'HTML'
</body>
</html>
HTML
}

main() {
  set -euo pipefail

  parse_args "$@"
  check_dependencies
  validate_commits
  validate_demo_files

  WORKDIR="$(mktemp -d)"
  HTML="${WORKDIR}/report.html"
  trap 'rm -rf "$WORKDIR"' EXIT

  render_html_header "$HTML"
  render_demo_section "$HTML"
  generate_diff_html "$HTML" "$WORKDIR"

  wkhtmltopdf "$HTML" "$OUTPUT"
  echo "✅ Wrote report to: ${OUTPUT}"
}

main "$@"
