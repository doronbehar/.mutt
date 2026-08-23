#!/usr/bin/env bash
# md2html.sh
#
# Invoked as a <filter-entry> on the composed (markdown) body in neomutt's
# compose menu: reads the body from stdin and writes a SANITIZED version of
# it back to stdout, which neomutt uses to replace the body content in
# place. That's what keeps real local file paths out of the plain-text
# alternative that gets sent.
#
# As a side effect it also:
#   - resolves $tmpdir the way neomutt itself would (via `neomutt -Q tmpdir`,
#     falling back to $TMPDIR or /tmp)
#   - copies every locally-referenced image into that tmpdir, renamed to its
#     content hash (so neither the original filename nor its directory ever
#     appears in the outgoing mail)
#   - converts the sanitized markdown to HTML with pandoc, referencing images
#     via cid: (not data: URIs, which Gmail and most webmail strip)
#   - writes a browser-viewable preview to the constant path
#     /tmp/neomutt-preview.html (constant so your browser can find it at the
#     same place, and remember it, every time)
#   - writes /tmp/neomutt-attach-macro: a neomutt "push" command file that
#     attaches the HTML + images, groups the HTML with the (now sanitized)
#     plain-text part as multipart/alternative, and wraps everything as
#     multipart/related
#
# Install:
#   chmod +x md2html.sh
#   mkdir -p ~/.mutt && cp md2html.sh ~/.mutt/
#
# Add to your neomuttrc (silences the compose-preview pane's harmless
# complaint about non-text inline parts):
#   unset compose_show_preview
#
# neomuttrc macro. Uses <filter-entry> (not <pipe-entry>), since it needs to
# replace the body content, not just read it. <filter-entry> always asks for
# confirmation before running -- the trailing "y" answers that.
#   macro compose \Cf "<first-entry><filter-entry>~/.mutt/md2html.sh<enter>y<enter-command>source /tmp/neomutt-attach-macro<enter>" "Convert markdown to HTML, attach inline images"

set -euo pipefail

commandsFile="/tmp/neomutt-attach-macro"
previewConstPath="/tmp/neomutt-preview.html"

# --- Resolve tmpdir the same way neomutt itself would ---
tmpdir=""
if command -v neomutt >/dev/null 2>&1; then
  # Pull out whatever's between the first pair of quotes, regardless of
  # exactly how -Q formats the rest of the line (e.g. "tmpdir=..." vs
  # "set tmpdir=...", with or without spaces around "=").
  tmpdir="$(neomutt -Q tmpdir 2>/dev/null | sed -E 's/^[^"]*"([^"]*)".*/\1/')"
fi
# A value from -Q may contain a literal leading ~ (e.g. "~/.cache/mutt"),
# which does NOT get expanded automatically when it comes from a variable.
tmpdir="${tmpdir/#\~/$HOME}"

# If neomutt has its own configured (dedicated) tmpdir, our files don't need
# to stand out in it. If we fell back to the generic system tmp dir instead,
# prefix our files so they're identifiable among everyone else's.
if [ -n "$tmpdir" ]; then
  tmpdir_prefix=""
else
  tmpdir="${TMPDIR:-/tmp}"
  tmpdir_prefix="neomutt-"
fi
mkdir -p "$tmpdir"

mdFile="$(mktemp -p "$tmpdir" --suffix=.md "${tmpdir_prefix}XXXXXX")"
htmlFile="$(mktemp -p "$tmpdir" --suffix=.html "${tmpdir_prefix}XXXXXX")"

# Save the piped-in (real) markdown body to a working copy
cat - > "$mdFile"

# Collect local image paths (skip already-cid and remote http(s) images)
mapfile -t images < <(
  grep -Eo '!\[[^]]*\]\([^)]+\)' "$mdFile" \
    | sed -E 's/.*\(([^)]+)\)/\1/' \
    | grep -Ev '^(cid:|https?://)' \
    | sort -u
)

# For each local image: copy it into tmpdir under a hash-based name (hides
# the original filename/path), and rewrite its markdown reference to cid:.
declare -A cid_for_file=()
for file in "${images[@]}"; do
  id="$(md5sum "$file" | cut -d ' ' -f1)"
  ext=""
  case "$file" in
    *.*) ext=".${file##*.}" ;;
  esac
  cid_for_file["$file"]="$id"
  cp "$file" "$tmpdir/$id$ext"
  esc_file=$(printf '%s\n' "$file" | sed 's/[.[\*^$/&]/\\&/g')
  sed -i "s#($esc_file)#(cid:$id)#g" "$mdFile"
done

# Emit the sanitized markdown as this script's stdout -- <filter-entry>
# replaces the real compose body with whatever we print here. Nothing else
# in this script may write to stdout.
cat "$mdFile"

# Convert the sanitized markdown to HTML (your original pandoc flags)
pandoc \
  --standalone \
  --metadata=pagetitle=mail \
  --webtex \
  --from 'markdown+hard_line_breaks-blank_before_blockquote+ignore_line_breaks' \
  --to=html5 \
  --output="$htmlFile" \
  "$mdFile" >/dev/null

# Build the browser-viewable preview directly at its constant path: cid:
# links only resolve inside a mail client's assembled MIME message, so point
# them at your original image files instead. (Not the tmpdir copies -- those
# get unlinked after sending, which would leave the preview broken.)
cp "$htmlFile" "$previewConstPath"
for file in "${images[@]}"; do
  id="${cid_for_file[$file]}"
  abs_file="$(realpath "$file")"
  sed -i "s#cid:$id#file://$abs_file#g" "$previewConstPath"
done

# --- Build the neomutt push-command file ---
# NOTE: paths are intentionally NOT quoted here -- neomutt's attach-file
# prompt takes them literally, and a quoted path just fails to resolve.
: > "$commandsFile"
{
  echo -n "push "
  # Attach HTML, group it with the (now sanitized) plain-text body as
  # multipart/alternative
  echo -n "<attach-file>$htmlFile<enter>"
  echo -n "<toggle-disposition>"     # mark html part inline
  echo -n "<toggle-unlink>"          # delete generated html after send
  echo -n "<tag-entry><first-entry><tag-entry>"
  echo -n "<group-alternatives>"
} >> "$commandsFile"

# Attach each cid-named image copy inline with a matching Content-ID, and
# unlink it after send since it's a disposable copy, not your original file.
for file in "${images[@]}"; do
  id="${cid_for_file[$file]}"
  ext=""
  case "$file" in
    *.*) ext=".${file##*.}" ;;
  esac
  {
    echo -n "<attach-file>$tmpdir/$id$ext<enter>"
    echo -n "<toggle-disposition>"
    echo -n "<edit-content-id>^u$id<enter>"
    echo -n "<toggle-unlink>"
    echo -n "<tag-entry>"
  } >> "$commandsFile"
done

# If we attached any images, wrap alternative-group + images in multipart/related
if [ "${#images[@]}" -gt 0 ]; then
  echo -n "<first-entry><tag-entry><group-related>" >> "$commandsFile"
fi

echo >> "$commandsFile"
