#!/usr/bin/env bash
set -euo pipefail

# git-diff-report.sh
# Build a pretty PDF report of per-commit diffs along first-parent from A (exclusive) to B (inclusive).
# Usage:
#   git-diff-report.sh [-o output.pdf] <A> <B>
#
# Dependencies: git, delta, aha, wkhtmltopdf
#
# Notes:
# - Uses first-parent history to keep a linear narrative.
# - For merge commits, diffs against first parent (C^1).
# - For root commit (no parent), diffs against the empty tree.

usage() {
  echo "Usage: $0 [-o output.pdf] <A> <B>"
  echo "  -o, --output   Output PDF file (default: diff-report.pdf)"
  exit 1
}

# Defaults
OUTPUT="diff-report.pdf"

# Parse args
if [[ $# -lt 2 ]]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      shift
      [[ $# -gt 0 ]] || usage
      OUTPUT="$1"
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
      fi
      shift
      ;;
  esac
done

: "${A_COMMIT:?Missing A}"
: "${B_COMMIT:?Missing B}"

# Check deps
for cmd in git delta aha wkhtmltopdf; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found in PATH." >&2
    exit 2
  fi
done

# Verify commits
if ! git rev-parse --verify --quiet "$A_COMMIT^{commit}" >/dev/null; then
  echo "Error: '$A_COMMIT' is not a valid commit-ish." >&2
  exit 2
fi
if ! git rev-parse --verify --quiet "$B_COMMIT^{commit}" >/dev/null; then
  echo "Error: '$B_COMMIT' is not a valid commit-ish." >&2
  exit 2
fi

# Temp files
WORKDIR="$(mktemp -d)"
HTML="${WORKDIR}/report.html"
trap 'rm -rf "$WORKDIR"' EXIT

# HTML head
cat > "$HTML" <<'HTML'
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
	  table-layout: fixed;     /* zwei feste Spalten */
	  border-collapse: separate;
	  border-spacing: 16px 0;  /* Abstand zwischen Spalten */
	}
	.table2 td {
	  width: 50%;
	  vertical-align: top;
	}
  pre.code {
	  white-space: pre;          /* KEIN Umbruch, Whitespace bleibt 1:1 erhalten */
	  word-break: normal;        /* nicht mitten im Wort umbrechen */
	  overflow-wrap: normal;     /* keine Not-Umbrüche */
	  overflow-x: auto;          /* horizontales Scrollen erlauben */
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

# Resolve nice labels
REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"
A_ABBR="$(git rev-parse --short "$A_COMMIT")"
B_ABBR="$(git rev-parse --short "$B_COMMIT")"

cat >> "$HTML" <<HTML
<p class="meta"><strong>Repository:</strong> ${REPO_NAME}<br>
<strong>Range:</strong> ${A_COMMIT}..${B_COMMIT} (first-parent, oldest → newest)</p>
<hr class="sep">
HTML

##############################################
# INSERT: How to read diffs? (before commits)
##############################################
if [[ -f testfileold && -f testfilenew ]]; then
  {
    echo '<h2>How to read diffs?</h2>'
    echo '<p>In the toy example below, we compare <code>testfileold</code> → <code>testfilenew</code>.'
    echo 'Green lines are additions, red lines are deletions. Inline highlights mark changed words or whitespace.</p>'


	echo '<h3>The compared files</h3>'
	echo '<table class="table2"><tr>'

	echo '<td><h4>testfileold</h4>'
	printf '<pre class="code">%s</pre>\n' \
	  "$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' testfileold)"
	echo '</td>'

	echo '<td><h4>testfilenew</h4>'
	printf '<pre class="code">%s</pre>\n' \
	  "$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' testfilenew)"
	echo '</td>'

	echo '</tr></table>'

    echo '<h3>Example diff</h3>'
    echo '<div class="diff">'
    # --no-index lets us diff two paths outside git; add `|| true` so a nonzero diff exit won’t kill the script.
    git diff --no-index --no-ext-diff testfileold testfilenew \
      | delta --paging=never --wrap-max-lines=0 --true-color=always --syntax-theme="gruvbox-light" \
      | aha --line-fix || true
    echo '</div>'
    echo '<hr class="sep">'
	echo '<div class="pagebreak"></div>'
  } >> "$HTML"
fi

# Empty tree for root diffs
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# Collect commits along first-parent path (A excluded, B included), oldest -> newest
mapfile -t COMMITS < <(git rev-list --first-parent --reverse "${A_COMMIT}..${B_COMMIT}")

if [[ ${#COMMITS[@]} -eq 0 ]]; then
  echo "No commits found in ${A_COMMIT}..${B_COMMIT} (first-parent)." >&2
  cat >> "$HTML" <<HTML
<p>No commits found in the specified range.</p>
</body></html>
HTML
  wkhtmltopdf "$HTML" "$OUTPUT"
  echo "Wrote empty report to ${OUTPUT}"
  exit 0
fi

for C in "${COMMITS[@]}"; do
  C_ABBR="$(git rev-parse --short "$C")"

  # Find parent: first parent if exists, else empty tree
  if git rev-parse --verify --quiet "${C}^1" >/dev/null; then
    PARENT="${C}^1"
  else
    PARENT="${EMPTY_TREE}"
  fi

  # Commit header/meta
  AUTHOR_NAME="$(git log -1 --format=%an "$C")"
  AUTHOR_EMAIL="$(git log -1 --format=%ae "$C")"
  AUTHOR_DATE="$(git log -1 --format=%ad --date=iso-strict "$C")"

  # Commit message (subject + body)
  COMMIT_MSG="$(git log -1 --format=%B "$C")"

  # Diff with delta (ANSI color), then convert to HTML snippet
  # We set width to something large to avoid wrapped lines from delta itself.
  DIFF_HTML_SNIPPET="$WORKDIR/diff-${C_ABBR}.html"
  if ! git diff --no-ext-diff "${PARENT}" "${C}" \
      | delta \
	  		--paging=never \
			--wrap-max-lines=0 \
			--width=200 \
			--true-color=always \
			--syntax-theme="gruvbox-light" \
      | aha --line-fix > "$DIFF_HTML_SNIPPET"; then
    echo "Warning: diff for ${C_ABBR} failed; including plain text." >&2
    # Fallback: plain text without colors
    git diff --no-ext-diff "${PARENT}" "${C}" \
      | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
      | awk 'BEGIN{print "<pre class=\"diff\"><code>"} {print} END{print "</code></pre>"}' > "$DIFF_HTML_SNIPPET"
  fi

  # Write one commit block
  {
    echo "<div class=\"commit-block\">"
	echo "  <h2>Commit with Commit-Hash: ${C_ABBR}</h2>"
    echo "  <p class=\"meta\"><strong>Author:</strong> ${AUTHOR_NAME} &lt;${AUTHOR_EMAIL}&gt;<br>"
    echo "  <strong>Date:</strong> ${AUTHOR_DATE}</p>"
    echo "  <h3>Commit-Message</h3>"
    # Escape commit message for HTML
    esc_msg="$(printf '%s' "$COMMIT_MSG" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
    printf '  <div class="commit-msg">%s</div>\n' "$esc_msg"
	echo "  <h3>Changes made in this commit (diff against parent):</h3>"
    echo "  <div class=\"diff\">"
    cat "$DIFF_HTML_SNIPPET"
    echo "  </div>"
    echo "</div>"
  } >> "$HTML"
done

# Close HTML
cat >> "$HTML" <<'HTML'
</body>
</html>
HTML

# Produce PDF
wkhtmltopdf "$HTML" "$OUTPUT"

echo "✅ Wrote report to: ${OUTPUT}"
