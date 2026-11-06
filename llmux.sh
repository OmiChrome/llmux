#!/usr/bin/env bash
# llmux.sh - pack a directory into one LLM-ready file, and apply LLM edits back.
# Bash version of llmux.py: same flags, same output formats, same edit blocks.
# Needs: bash 3.2+, and the usual find/awk/sed/sort/head/wc/tr (GNU, BSD or busybox).
# Token counts are a fast estimate (~1-2% off tiktoken on real code).

VERSION="0.1.0"
set -f            # never glob-expand: we match patterns ourselves
export LC_ALL=C   # byte-wise tools, stable sort

DEF_DEPTH=5
DEF_FILE_MAX=51200
DEF_TOTAL_MAX=1048576
DEF_MAX_SCAN=20000
DEF_MAX_TIME=20

SKIP_DIRS=" .git .hg .svn node_modules bower_components vendor __pycache__ .venv venv env .env .tox .nox .mypy_cache .pytest_cache .ruff_cache .cache .gradle .idea .next .nuxt .svelte-kit .turbo .parcel-cache dist build out target coverage .terraform .llmux-backup site-packages .cargo .rustup .npm .nvm Library AppData .local .vscode-server "
SKIP_FILES=" package-lock.json yarn.lock pnpm-lock.yaml bun.lockb Cargo.lock poetry.lock Pipfile.lock composer.lock Gemfile.lock go.sum uv.lock .DS_Store Thumbs.db "
SKIP_GLOBS="*.min.js *.min.css *.map *.lock llmux-*.xml llmux-*.md llmux-*.txt"
SECRET_GLOBS=".env .env.* *.pem *.key *.p12 *.pfx id_rsa* id_ed25519* id_ecdsa* *.keystore .npmrc .pypirc .netrc credentials* *.kdbx"
KEEP_DOTFILES=" .gitignore .editorconfig .dockerignore .gitattributes "
BINARY_EXT=" png jpg jpeg gif bmp ico webp tiff tif psd svgz heic avif raw mp3 wav flac ogg m4a aac mp4 mkv mov avi webm wmv flv zip tar gz tgz bz2 xz 7z rar zst jar war ear whl egg exe dll so dylib bin o a lib obj class pyc pyo pyd wasm pdf doc docx xls xlsx ppt pptx odt ods odp epub ttf otf woff woff2 eot sqlite sqlite3 db mdb dat iso img dmg npy npz pkl pickle pt pth onnx h5 safetensors ckpt parquet "
TAB=$(printf '\t')

# ----------------------------------------------------------------- colors --
R="" B="" DIM="" RED="" GRN="" YEL="" CYN=""
use_color=1
for a in "$@"; do [ "$a" = "--no-color" ] && use_color=0; done
[ -n "${NO_COLOR:-}" ] && use_color=0
[ -t 2 ] || use_color=0
if [ $use_color = 1 ]; then
  E=$(printf '\033')
  R="$E[0m" B="$E[1m" DIM="$E[2m" RED="$E[31m" GRN="$E[32m" YEL="$E[33m" CYN="$E[36m"
fi

say() { printf '%s\n' "$*" >&2; }
die() {
  say "${RED}✗ ${R}$1"
  [ -n "${2:-}" ] && say "${DIM}  hint: ${R}$2"
  exit "${3:-2}"
}

TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT
trap 'say "${RED}✗ stopped${R}"; exit 130' INT
mk_tmp() { TMP=$(mktemp -d "${TMPDIR:-/tmp}/llmux.XXXXXX") || die "cannot make a temp folder"; }

# ---------------------------------------------------------------- helpers --
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

parse_size() {   # 50k / 1m / 2mb / 4096 -> bytes
  lower "$1" | tr -d ' ' | awk '{
    if (!match($0, /^[0-9.]+/)) exit 1
    n = substr($0, 1, RLENGTH); u = substr($0, RLENGTH + 1); sub(/i?b$/, "", u)
    m = 1; if (u == "k") m = 1024; else if (u == "m") m = 1048576
    else if (u == "g") m = 1073741824; else if (u != "") exit 1
    printf "%d", n * m }'
}
parse_count() {  # 128k / 200000 / 1m -> number
  lower "$1" | tr -d ' ' | awk '{
    if (!match($0, /^[0-9.]+/)) exit 1
    n = substr($0, 1, RLENGTH); u = substr($0, RLENGTH + 1)
    m = 1; if (u == "k") m = 1000; else if (u == "m") m = 1000000; else if (u != "") exit 1
    printf "%d", n * m }'
}
human() { awk -v n="$1" 'BEGIN { split("B KB MB GB", u, " "); i = 1
  while (n >= 1024 && i < 4) { n /= 1024; i++ }
  if (i == 1) printf "%d B", n; else printf "%.1f %s", n, u[i] }'; }
htok() { awk -v n="$1" 'BEGIN { if (n >= 1000) printf "%.1fk", n / 1000; else printf "%d", n }'; }

file_size() { wc -c < "$1" | tr -d ' '; }

tok_est() {  # file, clean byte size -> tokens (ASCII chars/4.2 + non-ASCII chars*0.8, like llmux.py)
  local nab nac
  nab=$(tr -d '\000-\177' < "$1" | wc -c | tr -d ' ')     # non-ASCII bytes
  nac=$(tr -cd '\300-\377' < "$1" | wc -c | tr -d ' ')    # non-ASCII chars (UTF-8 lead bytes)
  [ "$(head -c 3 "$1")" = "$(printf '\357\273\277')" ] && { nab=$((nab - 3)); nac=$((nac - 1)); }
  awk -v b="$2" -v nab="$nab" -v nac="$nac" 'BEGIN { printf "%d", (b - nab) / 4.2 + nac * 0.8 + 0.5 }'
}

in_list() { case "$2" in *" $1 "*) return 0;; esac; return 1; }  # word in " a b c "

match_any() {   # $1 = space-separated globs, $2 = relpath
  local rel=$2 name=${2##*/} g
  for g in $1; do
    case $rel in $g) return 0;; esac
    case $name in $g) return 0;; esac
    case $g in */) case "$rel/" in "$g"*) return 0;; esac;; esac
  done
  return 1
}

is_text() { grep -qI '' "$1" 2>/dev/null; }   # grep -I = treat binary as no match
is_utf8() { command -v iconv >/dev/null 2>&1 || return 0; iconv -f UTF-8 -t UTF-8 "$1" >/dev/null 2>&1; }
is_pack() { head -c 600 "$1" 2>/dev/null | grep -qE '^<llmux version=|generated: .* by llmux [0-9]'; }

danger_root() {
  local root=$1 home
  home=$(cd ~ 2>/dev/null && pwd -P)
  [ "$root" = "$home" ] && { echo "your home folder"; return; }
  [ "$root" = "/" ] && { echo "a filesystem root"; return; }
  case $root in
    /usr|/etc|/var|/opt|/Users|/home|/bin|/lib|/System|/c|/mnt/c|/c/Windows|/c/Users) echo "a system folder";;
  esac
}

# --------------------------------------------------------------- file list --
GI_RULES=""   # simple root .gitignore support when git is not available
load_gitignore() {
  [ -f "$1/.gitignore" ] || return
  local line d a
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in ""|"#"*|"!"*) continue;; esac
    line=$(printf '%s' "$line" | sed 's/^\xEF\xBB\xBF//; s/[[:space:]]*$//')
    d=0; a=0
    case $line in */) d=1; line=${line%/};; esac
    case $line in */*) a=1;; esac
    line=${line#/}
    [ -n "$line" ] && GI_RULES="$GI_RULES$d$a$line"$'\n'
  done < "$1/.gitignore"
}
gi_ignored() {   # $1 = relpath; uses GI_RULES
  [ -z "$GI_RULES" ] && return 1
  local rel=$1 rule d a pat comp n i
  local IFS=/
  local parts; read -r -a parts <<< "$rel"
  n=${#parts[@]}
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    d=${rule:0:1}; a=${rule:1:1}; pat=${rule:2}
    if [ "$a" = 1 ]; then
      if [ "$d" = 1 ]; then case $rel in $pat/*) return 0;; esac
      else case $rel in $pat|$pat/*) return 0;; esac; fi
    else
      i=0
      while [ $i -lt $n ]; do
        comp=${parts[$i]}
        if [ "$d" = 0 ] || [ $i -lt $((n - 1)) ]; then
          case $comp in $pat) return 0;; esac
        fi
        i=$((i + 1))
      done
    fi
  done <<< "$GI_RULES"
  return 1
}

prune_expr() {   # find(1) arguments that prune junk (+ hidden) dirs
  PRUNE=( \( -type d \( -name .git )
  local d
  for d in $SKIP_DIRS; do PRUNE+=( -o -name "$d" ); done
  [ "$hidden" = 1 ] || PRUNE+=( -o \( -name '.*' ! -name .github \) )
  PRUNE+=( \) -prune \) )
}

list_files() {   # writes sorted relpaths (shallow first) to $TMP/list
  local start=$SECONDS t="" n
  command -v timeout >/dev/null 2>&1 && t="timeout $max_time"
  USE_GIT=0
  if [ "$no_gi" = 0 ] && command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    USE_GIT=1
    $t git -c core.quotepath=off -C "$root" ls-files -co --exclude-standard 2>/dev/null | head -n "$max_scan" > "$TMP/raw"
  else
    [ "$no_gi" = 0 ] && load_gitignore "$root"
    prune_expr
    local md=(); [ "$depth" -gt 0 ] && md=( -maxdepth "$depth" )
    $t find "$root" -mindepth 1 "${md[@]}" "${PRUNE[@]}" -o \( -type f -print \) 2>/dev/null \
      | head -n "$max_scan" | sed "s#^$root/##" > "$TMP/raw"
    if [ "$depth" -gt 0 ]; then   # anything deeper? (just to tell the user)
      local d1=$((depth + 1))
      [ -n "$(find "$root" -mindepth "$d1" -maxdepth "$d1" "${PRUNE[@]}" -o \( -type f -print \) 2>/dev/null | head -n 1)" ] && DEPTH_HIT=1
    fi
  fi
  n=$(wc -l < "$TMP/raw" | tr -d ' ')
  [ "$n" -ge "$max_scan" ] && STOP="looked at $max_scan entries (--max-scan)"
  [ $((SECONDS - start)) -ge "${max_time%.*}" ] && STOP="scanning took over ${max_time%.*}s (--max-time)"
  awk '{ n = gsub("/", "/"); print n "\t" $0 }' "$TMP/raw" | sort -t "$TAB" -k1,1n -k2,2f | cut -f2- > "$TMP/list"
}

# ----------------------------------------------------------------- render --
EDIT_GUIDE='When you change code, reply ONLY with edit blocks in this exact format
(llmux applies them for the user with `llmux apply reply.txt`):

FILE: path/to/file.ext
<<<<<<< SEARCH
exact lines copied from the current file (enough to be unique)
=======
the new lines
>>>>>>> REPLACE

Rules:
- Paths are relative to the project root, exactly as shown in this file.
- SEARCH must match the current file text exactly, incl. indentation.
- Keep SEARCH short but unique. Use several blocks for several changes.
- New file or full rewrite: put the whole content between
  <<<<<<< FULL   and   >>>>>>> END   under the FILE: line.
- Empty SEARCH = append to the end (or create the file).
- Delete a file with a line:  DELETE: path/to/file.ext
- Do not use line numbers or unified diffs.'

TREE_AWK='
{ n = split($0, p, "/"); key = ""
  for (i = 1; i <= n; i++) {
    parent = key; key = (key == "" ? p[i] : key "/" p[i])
    if (!(key in seen)) { seen[key] = 1; nm[key] = p[i]; kids[parent] = kids[parent] SUBSEP key }
    if (i < n) isdir[key] = 1
  } }
function less(a, b) { if ((a in isdir) != (b in isdir)) return (a in isdir); return tolower(nm[a]) < tolower(nm[b]) }
function walk(k, prefix,   m, arr, i, j, t, c, last) {
  if (!(k in kids)) return
  m = split(substr(kids[k], 2), arr, SUBSEP)
  for (i = 2; i <= m; i++) { t = arr[i]; j = i - 1; while (j >= 1 && less(t, arr[j])) { arr[j + 1] = arr[j]; j-- } arr[j + 1] = t }
  for (i = 1; i <= m; i++) {
    c = arr[i]; last = (i == m)
    print prefix (last ? "└── " : "├── ") nm[c] ((c in isdir) ? "/" : "")
    if (c in isdir) walk(c, prefix (last ? "    " : "│   "))
  } }
END { walk("", "") }'

emit_file() {   # file text: no BOM, LF only, trailing newlines trimmed, ends with one \n
  awk 'NR == 1 { sub(/^\357\273\277/, "") } { sub(/\r$/, ""); a[NR] = $0 }
       END { n = NR; while (n > 0 && a[n] == "") n--; for (i = 1; i <= n; i++) print a[i] }' "$1"
}
md_fence() {
  grep -o '```*' "$1" 2>/dev/null | awk '{ if (length($0) > m) m = length($0) }
    END { n = (m >= 3 ? m + 1 : 3); s = ""; for (i = 0; i < n; i++) s = s "`"; print s }'
}

render() {   # $1 = first index, $2 = last index, $3 = part, $4 = parts  -> fd 3
  local a=$1 b=$2 i nb=0 nt=0 rel ext fe
  for ((i = a; i <= b; i++)); do nb=$((nb + F_SIZE[i])); nt=$((nt + F_TOK[i])); done
  for ((i = a; i <= b; i++)); do printf '%s\n' "${F_REL[i]}"; done | awk "$TREE_AWK" > "$TMP/tree"
  {
    printf 'project: %s\n' "$root_name"
    printf 'generated: %s by llmux %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$VERSION"
    printf 'files: %s\nsize: %s\ntokens: %s (estimate)\n' "$((b - a + 1))" "$(human $nb)" "$nt"
    [ -n "$3" ] && printf 'part: %s of %s\n' "$3" "$4"
    [ -n "$STOP" ] && printf 'NOTE: incomplete - %s\n' "$STOP"
  } > "$TMP/info"
  case $fmt in
  xml)
    printf '<llmux version="%s" project="%s">\n' "$VERSION" "$root_name"
    if [ "$no_header" = 0 ]; then
      printf '<summary>\n'; cat "$TMP/info"; printf '</summary>\n'
      [ "$no_instr" = 0 ] && printf '<instructions>\n%s\n</instructions>\n' "$EDIT_GUIDE"
      [ "$no_tree" = 0 ] && { printf '<directory_structure>\n'; cat "$TMP/tree"; printf '</directory_structure>\n'; }
    fi
    printf '<files>\n'
    for ((i = a; i <= b; i++)); do
      printf '<file path="%s" tokens="%s">\n' "${F_REL[i]}" "${F_TOK[i]}"
      emit_file "${F_ABS[i]}"; printf '</file>\n'
    done
    printf '</files>\n</llmux>\n' ;;
  md)
    printf '# %s\n\n' "$root_name"
    if [ "$no_header" = 0 ]; then
      printf '## Summary\n\n'; sed 's/^/- /' "$TMP/info"; printf '\n'
      [ "$no_instr" = 0 ] && printf '## How to reply with edits\n\n```text\n%s\n```\n\n' "$EDIT_GUIDE"
      [ "$no_tree" = 0 ] && { printf '## Directory structure\n\n```text\n'; cat "$TMP/tree"; printf '```\n\n'; }
    fi
    printf '## Files\n\n'
    for ((i = a; i <= b; i++)); do
      rel=${F_REL[i]}; ext=""
      case ${rel##*/} in *.*) ext=${rel##*.};; esac
      fe=$(md_fence "${F_ABS[i]}")
      printf '### File: %s\n\n%s%s\n' "$rel" "$fe" "$ext"
      emit_file "${F_ABS[i]}"; printf '%s\n\n' "$fe"
    done ;;
  txt)
    local bar="================================================================"
    printf '%s\n%s\n%s\n' "$bar" "$root_name" "$bar"
    if [ "$no_header" = 0 ]; then
      printf 'SUMMARY\n'; cat "$TMP/info"; printf '\n'
      [ "$no_instr" = 0 ] && printf 'HOW TO REPLY WITH EDITS\n%s\n\n' "$EDIT_GUIDE"
      [ "$no_tree" = 0 ] && { printf 'DIRECTORY STRUCTURE\n'; cat "$TMP/tree"; printf '\n'; }
    fi
    for ((i = a; i <= b; i++)); do
      printf '===== FILE: %s =====\n' "${F_REL[i]}"
      emit_file "${F_ABS[i]}"; printf '===== END FILE =====\n\n'
    done ;;
  esac >&3
}

# ------------------------------------------------------------------- pack --
need() { [ $# -ge 2 ] || die "$1 needs a value" "see: llmux --help"; }

cmd_pack() {
  fmt=xml out="" depth=$DEF_DEPTH file_max=$DEF_FILE_MAX total_max=$DEF_TOTAL_MAX max_tokens=0
  include="" exclude="" no_tree=0 no_header=0 no_instr=0 no_gi=0 hidden=0 force=0 dry=0
  to_stdout=0 split=0 allow_secrets=0 max_parts=10 max_scan=$DEF_MAX_SCAN max_time=$DEF_MAX_TIME
  local target=""
  while [ $# -gt 0 ]; do
    case $1 in
      -f|--format) need "$@"; fmt=$(lower "$2")
        case $fmt in markdown) fmt=md;; text|plain) fmt=txt;; esac
        case $fmt in xml|md|txt) ;; *) die "unknown format '$2'" "use xml, md or txt";; esac; shift;;
      -o|--output) need "$@"; out=$2; shift;;
      -d|--depth) need "$@"
        case $2 in ''|*[!0-9]*) die "bad depth '$2'" "0 = unlimited, 1 = this folder only, 5 = default";; esac
        depth=$2; shift;;
      -s|--max-file-size) need "$@"; file_max=$(parse_size "$2") || die "bad size '$2'" "use e.g. 50k, 1m, 2mb, 4096"; shift;;
      -m|--max-size) need "$@"; total_max=$(parse_size "$2") || die "bad size '$2'" "use e.g. 50k, 1m, 2mb, 4096"; shift;;
      -t|--max-tokens) need "$@"; max_tokens=$(parse_count "$2") || die "bad number '$2'" "use e.g. 128k, 200000"; shift;;
      -i|--include) need "$@"; include="$include $(printf '%s' "$2" | tr ',' ' ')"; shift;;
      -x|--exclude) need "$@"; exclude="$exclude $(printf '%s' "$2" | tr ',' ' ')"; shift;;
      --no-tree) no_tree=1;;
      --no-header) no_header=1;;
      --no-instructions) no_instr=1;;
      --no-gitignore) no_gi=1;;
      -a|--hidden) hidden=1;;
      --allow-secrets) allow_secrets=1;;
      --force) force=1;;
      -n|--dry-run) dry=1;;
      -c|--stdout) to_stdout=1;;
      --split) split=1;;
      --max-parts) need "$@"; max_parts=$(parse_count "$2") || die "bad number '$2'"; shift;;
      --max-scan) need "$@"; max_scan=$(parse_count "$2") || die "bad number '$2'"; shift;;
      --max-time) need "$@"; max_time=$2; shift;;
      --no-color) ;;
      -) target=-;;
      -*) die "unknown flag '$1'" "see: llmux --help";;
      *) [ -n "$target" ] && die "only one folder at a time (got '$target' and '$1')"; target=$1;;
    esac
    shift
  done
  target=${target:-.}
  case $target in "~") target=$HOME;; "~/"*) target="$HOME/${target#\~/}";; esac
  [ -d "$target" ] || die "'$target' is not a folder"
  root=$(cd "$target" && pwd -P)
  root_name=${root##*/}; [ -z "$root_name" ] && root_name=$root
  local danger; danger=$(danger_root "$root")
  if [ -n "$danger" ] && [ "$force" = 0 ]; then
    die "'$root' is $danger. Packing it is almost always a mistake." \
        "cd into a project folder, or add --force if you really mean it"
  fi
  if [ -z "$out" ]; then
    out="llmux-$(printf '%s' "$root_name" | tr -c 'A-Za-z0-9._-' '_')-$(date +%Y%m%d-%H%M%S).$fmt"
  fi
  case $out in /*) out_abs=$out;; *) out_abs="$(pwd -P)/$out";; esac

  local dtxt=$depth; [ "$depth" = 0 ] && dtxt=unlimited; [ "$depth" = 1 ] && dtxt="this folder only"
  say "${CYN}◆ llmux${R}${DIM} $VERSION (bash)${R}  packing ${B}$root${R}"
  local lim="depth $dtxt · file ≤ $(human $file_max) · total ≤ $(human $total_max)"
  [ "$max_tokens" -gt 0 ] && lim="$lim · ≤ $(htok $max_tokens) tokens"
  say "${DIM}  $lim${R}"

  mk_tmp
  STOP="" DEPTH_HIT=0 SKIPS="" BIG="" BIGN=0 SECRETS=""
  F_REL=() F_ABS=() F_SIZE=() F_TOK=()
  list_files

  local mult=1; [ "$split" = 1 ] && mult=$max_parts
  local cap_b=$((total_max * mult)) cap_t=$((max_tokens * mult))
  local tot_b=0 tot_t=0 rel abs name ext size tok parts n i comp bad
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    abs="$root/$rel"; name=${rel##*/}
    [ -f "$abs" ] || continue
    [ "$abs" = "$out_abs" ] && continue
    [ -L "$abs" ] && { SKIPS="${SKIPS}symlink"$'\n'; continue; }
    # folder parts: junk / hidden / depth (find already pruned; git did not)
    IFS=/ read -r -a parts <<< "$rel"; n=${#parts[@]}; bad=""
    for ((i = 0; i < n - 1; i++)); do
      comp=${parts[i]}
      if in_list "$comp" "$SKIP_DIRS"; then bad="junk dir"; break; fi
      if [ "$hidden" = 0 ] && [ "${comp:0:1}" = . ] && [ "$comp" != .github ]; then bad="hidden"; break; fi
    done
    if [ -z "$bad" ] && [ "$depth" -gt 0 ] && [ "$n" -gt "$depth" ]; then bad="too deep"; DEPTH_HIT=1; fi
    [ -n "$bad" ] && { SKIPS="$SKIPS$bad"$'\n'; continue; }
    if [ -n "${include// /}" ] && ! match_any "$include" "$rel"; then SKIPS="${SKIPS}not included"$'\n'; continue; fi
    if [ -n "${exclude// /}" ] && match_any "$exclude" "$rel"; then SKIPS="${SKIPS}excluded"$'\n'; continue; fi
    if [ "$allow_secrets" = 0 ] && match_any "$SECRET_GLOBS" "$rel"; then
      SKIPS="${SKIPS}secret"$'\n'; SECRETS="$SECRETS${SECRETS:+, }$rel"; continue
    fi
    if in_list "$name" "$SKIP_FILES" || match_any "$SKIP_GLOBS" "$rel"; then SKIPS="${SKIPS}lock/min/generated"$'\n'; continue; fi
    if [ "$hidden" = 0 ] && [ "${name:0:1}" = . ] && ! in_list "$name" "$KEEP_DOTFILES"; then SKIPS="${SKIPS}hidden"$'\n'; continue; fi
    if [ "$USE_GIT" = 0 ] && gi_ignored "$rel"; then SKIPS="${SKIPS}gitignore"$'\n'; continue; fi
    ext=""; case $name in *.*) ext=$(lower "${name##*.}");; esac
    if [ -n "$ext" ] && in_list "$ext" "$BINARY_EXT"; then SKIPS="${SKIPS}binary"$'\n'; continue; fi
    size=$(file_size "$abs")
    if [ "$size" -gt "$file_max" ]; then
      SKIPS="${SKIPS}too big (-s)"$'\n'
      [ $BIGN -lt 4 ] && BIG="$BIG${BIG:+, }$rel ($(human $size))"; BIGN=$((BIGN + 1)); continue
    fi
    [ "$size" -eq 0 ] && { SKIPS="${SKIPS}empty"$'\n'; continue; }
    is_text "$abs" || { SKIPS="${SKIPS}binary"$'\n'; continue; }
    is_utf8 "$abs" || { SKIPS="${SKIPS}not utf-8"$'\n'; continue; }
    is_pack "$abs" && { SKIPS="${SKIPS}old llmux output"$'\n'; continue; }
    # count what we will actually write: no CR, no BOM (same as llmux.py)
    if grep -q "$(printf '\r')" "$abs"; then size=$((size - $(tr -cd '\r' < "$abs" | wc -c))); fi
    [ "$(head -c 3 "$abs")" = "$(printf '\357\273\277')" ] && size=$((size - 3))
    tok=$(tok_est "$abs" "$size")
    if [ $((tot_b + size)) -gt "$cap_b" ] || { [ "$cap_t" -gt 0 ] && [ $((tot_t + tok)) -gt "$cap_t" ]; }; then
      if [ "$cap_t" -gt 0 ] && [ $((tot_t + tok)) -gt "$cap_t" ]; then STOP="output token limit reached"
      else STOP="output size limit reached"; fi
      SKIPS="${SKIPS}over total limit"$'\n'
      break   # stop: no point reading more
    fi
    F_REL+=("$rel"); F_ABS+=("$abs"); F_SIZE+=("$size"); F_TOK+=("$tok")
    tot_b=$((tot_b + size)); tot_t=$((tot_t + tok))
  done < "$TMP/list"

  report "$tot_b" "$tot_t"
  local count=${#F_REL[@]}
  [ "$count" -eq 0 ] && die "nothing to pack" "check the folder, or loosen -s / -d / -i / -x" 1
  [ "$dry" = 1 ] && { say "${YEL}  dry run - nothing written${R}"; return 0; }

  # split into parts
  local P_A=() P_B=() s=0 cb=0 ct=0
  if [ "$split" = 1 ]; then
    for ((i = 0; i < count; i++)); do
      if [ $i -gt $s ] && { [ $((cb + F_SIZE[i])) -gt "$total_max" ] || { [ "$max_tokens" -gt 0 ] && [ $((ct + F_TOK[i])) -gt "$max_tokens" ]; }; }; then
        P_A+=("$s"); P_B+=($((i - 1))); s=$i; cb=0; ct=0
      fi
      cb=$((cb + F_SIZE[i])); ct=$((ct + F_TOK[i]))
    done
  fi
  P_A+=("$s"); P_B+=($((count - 1)))
  local np=${#P_A[@]} path stem fext
  for ((i = 0; i < np; i++)); do
    local pn="" pt=""; [ "$np" -gt 1 ] && { pn=$((i + 1)); pt=$np; }
    if [ "$to_stdout" = 1 ]; then
      exec 3>&1
    else
      path=$out
      if [ "$np" -gt 1 ]; then stem=${out%.*}; fext=${out##*.}; path="$stem.part$((i + 1)).$fext"; fi
      exec 3>"$path" || die "cannot write '$path'"
    fi
    render "${P_A[i]}" "${P_B[i]}" "$pn" "$pt"
    exec 3>&-
    [ "$to_stdout" = 0 ] && say "${GRN}✓ wrote ${R}${B}$path${R}${DIM}  ($(human "$(file_size "$path")"))${R}"
  done
  [ "$to_stdout" = 0 ] && say "${DIM}  next: paste it into your LLM. Save its reply, then: ${R}${CYN}llmux apply reply.txt${R}"
  return 0
}

report() {
  local tb=$1 tt=$2 i count=${#F_REL[@]}
  say ""
  say "  ${B}files${R}   ${GRN}$count${R}"
  say "  ${B}size${R}    $(human "$tb")"
  say "  ${B}tokens${R}  $(htok "$tt") ${DIM}(estimate)${R}"
  if [ "$count" -gt 0 ]; then
    say "${DIM}  biggest:${R}"
    for ((i = 0; i < count; i++)); do printf '%s\t%s\n' "${F_TOK[i]}" "${F_REL[i]}"; done \
      | sort -t "$TAB" -k1,1nr | head -n 5 | while IFS="$TAB" read -r tk rl; do
          say "    $(printf '%7s' "$(htok "$tk")") ${DIM}$(awk -v a="$tk" -v b="$tt" 'BEGIN { printf "%4.1f%%", 100 * a / (b > 0 ? b : 1) }')${R}  $rl"
        done
  fi
  if [ -n "$SKIPS" ]; then
    say "${DIM}  skipped: $(printf '%s' "$SKIPS" | sort | uniq -c | sort -k1,1nr | awk '{ c = $1; $1 = ""; sub(/^ /, ""); printf "%s%s %d", (NR > 1 ? ", " : ""), $0, c }')${R}"
  fi
  [ -n "$BIG" ] && say "${YEL}  ! too big, left out: ${R}$BIG${DIM}  → raise with -s 200k${R}"
  [ -n "$SECRETS" ] && say "${YEL}  ! secrets left out: ${R}$SECRETS${DIM}  (--allow-secrets to include)${R}"
  [ "$DEPTH_HIT" = 1 ] && say "${DIM}  some folders were deeper than -d; use -d 0 for unlimited${R}"
  if [ -n "$STOP" ]; then
    say "${YEL}  ! stopped early: ${R}$STOP"
    say "${DIM}    output is partial. Narrow it with -i 'src/**' or -x 'docs/', or raise -m / -t / --split${R}"
  fi
  say ""
}

# ------------------------------------------------------------------ apply --
# Parses edit blocks into $TMP/ops/N.s (search) N.r (replace/body) + index lines
PARSE_EDITS_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function emit(kind) { n++; printf "%s", sb > (dir "/" n ".s"); close(dir "/" n ".s")
  printf "%s", rb > (dir "/" n ".r"); close(dir "/" n ".r")
  print n "\t" kind "\t" path "\t" start > (dir "/index") }
BEGIN { n = 0; st = 0; path = "" }
st == 1 { if ($0 ~ /^[ \t]*=====+[ \t]*$/) { st = 2; next } sb = (sc++ ? sb "\n" : "") $0; next }
st == 2 { if ($0 ~ /^[ \t]*>>>>>+[ \t]*REPLACE[ \t]*$/) { emit("edit"); st = 0; next } rb = (rc++ ? rb "\n" : "") $0; next }
st == 3 { if ($0 ~ /^[ \t]*>>>>>+[ \t]*END[ \t]*$/) { emit("full"); st = 0; next } rb = (rc++ ? rb "\n" : "") $0; next }
match($0, /^[ \t>*#`_-]*(FILE|DELETE)[ \t]*:/) {
  head = substr($0, 1, RSTART + RLENGTH - 1); p = trim(substr($0, RSTART + RLENGTH))
  gsub(/^[`*_"\047]+/, "", p); gsub(/[`*_"\047]+$/, "", p); p = trim(p)
  if (head ~ /DELETE/) { sb = ""; rb = ""; save = path; path = p; start = NR; emit("delete"); path = save }
  else path = p
  next }
/^[ \t]*<<<<<+[ \t]*SEARCH[ \t]*$/ { st = 1; sb = ""; rb = ""; sc = 0; rc = 0; start = NR + 1; next }
/^[ \t]*<<<<<+[ \t]*FULL[ \t]*$/ { st = 3; sb = ""; rb = ""; rc = 0; start = NR + 1; next }
END { if (st) { sb = ""; rb = ""; emit("broken") } }'

PARSE_PACK_AWK='
function emit() { n++; printf "%s", rb > (dir "/" n ".r"); close(dir "/" n ".r"); printf "" > (dir "/" n ".s"); close(dir "/" n ".s")
  print n "\tfull\t" path "\t0" > (dir "/index") }
BEGIN { n = 0; st = 0 }
st == 1 { if ($0 == "</file>") { emit(); st = 0; next } rb = (rc++ ? rb "\n" : "") $0; next }
st == 2 { if ($0 == "===== END FILE =====") { emit(); st = 0; next } rb = (rc++ ? rb "\n" : "") $0; next }
st == 3 { if ($0 ~ /^`+/) { f = $0; sub(/[^`].*$/, "", f); st = 4; rb = ""; rc = 0 } else if ($0 != "") st = 0; next }
st == 4 { t = $0; sub(/[ \t]+$/, "", t); if (t == f) { emit(); st = 0; next } rb = (rc++ ? rb "\n" : "") $0; next }
/^<file path="[^"]*"/ { path = $0; sub(/^<file path="/, "", path); sub(/".*$/, "", path); st = 1; rb = ""; rc = 0; next }
/^===== FILE: .* =====$/ { path = $0; sub(/^===== FILE: /, "", path); sub(/ =====$/, "", path); st = 2; rb = ""; rc = 0; next }
/^### File: / { path = substr($0, 11); st = 3; next }'

LOCATE_AWK='
function norm(x) { if (mode == "r") sub(/[ \t]+$/, "", x); else { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x) } return x }
FILENAME == sfile { s[++sn] = $0; next }
{ c[++cn] = $0 }
END {
  a = 1; while (a <= sn && s[a] ~ /^[ \t]*$/) a++
  b = sn; while (b >= a && s[b] ~ /^[ \t]*$/) b--
  if (a > b) { print "blank"; exit }
  L = b - a + 1; hits = 0
  for (i = a; i <= b; i++) ns[i] = norm(s[i])
  for (i = 1; i <= cn - L + 1; i++) {
    ok = 1; for (j = 0; j < L; j++) if (norm(c[i + j]) != ns[a + j]) { ok = 0; break }
    if (ok) { hits++; at = i } }
  if (hits == 1) print at, at + L - 1, s[a]; else if (hits > 1) print "multi", hits; else print "none" }'

normalize() { awk 'NR == 1 { sub(/^\357\273\277/, "") } { sub(/\r$/, ""); print }' "$1"; }
lead_ws() { printf '%s' "$1" | awk 'NR == 1 { match($0, /^[ \t]*/); printf "%s", substr($0, 1, RLENGTH) }'; }

safe_rel() {   # prints cleaned relpath or fails
  local rel=$1
  rel=${rel//\\//}; rel=${rel#./}
  case $rel in ""|/*|[A-Za-z]:*) return 1;; esac
  case "/$rel/" in */../*|*/./*) return 1;; esac
  printf '%s' "$rel"
}

P_REL=() O_EX=() W_EX=() CRLF=()
slot() {   # find/create work slot for $1 (relpath); sets SLOT; returns 1 if not utf-8
  local rel=$1 i full
  for ((i = 0; i < ${#P_REL[@]}; i++)); do [ "${P_REL[i]}" = "$rel" ] && { SLOT=$i; return 0; }; done
  SLOT=${#P_REL[@]}; full="$aroot/$rel"
  if [ -f "$full" ]; then
    is_utf8 "$full" || return 1
    P_REL+=("$rel"); O_EX+=(1); W_EX+=(1)
    if grep -q "$(printf '\r')" "$full"; then CRLF+=(1); else CRLF+=(0); fi
    normalize "$full" > "$TMP/o$SLOT"; cp "$TMP/o$SLOT" "$TMP/w$SLOT"
  else
    P_REL+=("$rel"); O_EX+=(0); W_EX+=(0); CRLF+=(0); : > "$TMP/o$SLOT"; : > "$TMP/w$SLOT"
  fi
}

show_diff() {   # $1 rel $2 old $3 new
  if command -v diff >/dev/null 2>&1; then
    diff -u "$2" "$3" | awk -v rel="$1" -v B="$B" -v R="$R" -v G="$GRN" -v Rd="$RED" -v C="$CYN" -v D="$DIM" '
      NR > 140 { more++; next }
      /^---/ { print B "--- a/" rel R; next } /^\+\+\+/ { print B "+++ b/" rel R; next }
      /^@@/ { print C $0 R; next } /^\+/ { print G $0 R; next } /^-/ { print Rd $0 R; next }
      { print D $0 R } END { if (more) print D "    … " more " more diff lines" R }' >&2
  else
    say "  ${YEL}~ $1 changed${R} ${DIM}(install diff to see a preview)${R}"
  fi
}

ERRS=""
err() { ERRS="$ERRS  ${RED}✗ $1${R}${DIM} (reply line $2): ${R}$3"$'\n'; }

cmd_apply() {
  local src="" dry=0 yes=0 nobak=0
  aroot="."
  while [ $# -gt 0 ]; do
    case $1 in
      -n|--dry-run) dry=1;;
      -y|--yes) yes=1;;
      -C|--dir) need "$@"; aroot=$2; shift;;
      --no-backup) nobak=1;;
      --no-color) ;;
      -) src=-;;
      -*) die "unknown flag '$1'" "see: llmux --help";;
      *) src=$1;;
    esac
    shift
  done
  [ -n "$src" ] || die "which file has the LLM reply?" "llmux apply reply.txt   (or '-' to read from paste/stdin)"
  mk_tmp
  if [ "$src" = - ]; then
    [ -t 0 ] && say "${DIM}paste the reply, then Ctrl-D:${R}"
    cat > "$TMP/reply"
  else
    [ -f "$src" ] || die "'$src' not found"
    cp "$src" "$TMP/reply"
  fi
  [ -d "$aroot" ] || die "'$aroot' is not a folder"
  aroot=$(cd "$aroot" && pwd -P)
  normalize "$TMP/reply" > "$TMP/r"
  mkdir -p "$TMP/ops"; : > "$TMP/ops/index"
  local mode="edit blocks"
  if is_pack "$TMP/r"; then awk -v dir="$TMP/ops" "$PARSE_PACK_AWK" "$TMP/r"; mode="files from pack"; fi
  if [ ! -s "$TMP/ops/index" ]; then awk -v dir="$TMP/ops" "$PARSE_EDITS_AWK" "$TMP/r"; mode="edit blocks"; fi
  if [ ! -s "$TMP/ops/index" ]; then awk -v dir="$TMP/ops" "$PARSE_PACK_AWK" "$TMP/r"; mode="files from pack"; fi
  [ -s "$TMP/ops/index" ] || die "no edits found in that file" \
    "the reply needs FILE: + <<<<<<< SEARCH / ======= / >>>>>>> REPLACE blocks, or be a full llmux pack"
  local nops; nops=$(wc -l < "$TMP/ops/index" | tr -d ' ')
  say "${CYN}◆ llmux apply${R}${DIM}  $nops $mode → ${R}${B}$aroot${R}"

  local n kind rel line w content search repl rest prefix loc st en first how want have
  while IFS="$TAB" read -r n kind rel line; do
    [ "$kind" = broken ] && { err "${rel:-?}" "$line" "block is not closed (missing ======= or >>>>>>> line)"; continue; }
    [ -z "$rel" ] && { err "?" "$line" "block has no FILE: line above it"; continue; }
    local clean; clean=$(safe_rel "$rel") || { err "$rel" "$line" "path is outside the project - refused"; continue; }
    rel=$clean
    slot "$rel" || { err "$rel" "$line" "file is not utf-8 text"; continue; }
    w="$TMP/w$SLOT"
    case $kind in
    delete)
      if [ "${W_EX[SLOT]}" = 0 ]; then err "$rel" "$line" "cannot delete - file does not exist"
      else W_EX[SLOT]=0; : > "$w"; fi ;;
    full)
      repl=$(cat "$TMP/ops/$n.r")
      if [ "${W_EX[SLOT]}" = 1 ] && [ "$repl" = "$(cat "$w")" ]; then continue; fi
      printf '%s\n' "$repl" > "$w"; W_EX[SLOT]=1 ;;
    edit)
      search=$(cat "$TMP/ops/$n.s"); repl=$(cat "$TMP/ops/$n.r")
      if [ -z "$(printf '%s' "$search" | tr -d ' \t\n')" ]; then
        printf '%s\n' "$repl" >> "$w"; W_EX[SLOT]=1; continue
      fi
      [ "${W_EX[SLOT]}" = 0 ] && { err "$rel" "$line" "file does not exist (use FULL block to create it)"; continue; }
      content=$(cat "$w"; printf x); content=${content%x}
      case $content in
      *"$search"*)
        rest=${content#*"$search"}
        case $rest in *"$search"*)
          err "$rel" "$line" "SEARCH matches 2+ places - add more context lines"; continue;; esac
        prefix=${content%%"$search"*}
        printf '%s' "$prefix$repl$rest" > "$w" ;;
      *)
        how=""
        for m in r s; do
          loc=$(awk -v mode=$m -v sfile="$TMP/ops/$n.s" "$LOCATE_AWK" "$TMP/ops/$n.s" "$w")
          case $loc in
            none) continue;;
            multi*) how="multi"; break;;
            blank) how="blank"; break;;
            *) how=$m; break;;
          esac
        done
        case $how in
          "") err "$rel" "$line" "SEARCH text not found in file"; continue;;
          multi) err "$rel" "$line" "SEARCH matches ${loc#multi } places (fuzzy) - add more context"; continue;;
          blank) err "$rel" "$line" "SEARCH is only blank lines"; continue;;
        esac
        st=${loc%% *}; loc=${loc#* }; en=${loc%% *}; first=${loc#* }
        cp "$TMP/ops/$n.r" "$TMP/rep"
        if [ "$how" = s ]; then
          have=$(lead_ws "$first"); want=$(lead_ws "$(sed -n "${st}p" "$w")")
          if [ "$have" != "$want" ]; then
            awk -v have="$have" -v want="$want" '{
              if (have != "" && index($0, have) == 1) $0 = want substr($0, length(have) + 1)
              else if (have == "" && $0 ~ /[^ \t]/) $0 = want $0
              else if ($0 ~ /[^ \t]/) { sub(/^[ \t]+/, ""); $0 = want $0 }
              print }' "$TMP/ops/$n.r" > "$TMP/rep"
          fi
          say "${YEL}  ~ $rel: matched ignoring indentation${R}"
        else
          say "${YEL}  ~ $rel: matched ignoring trailing spaces${R}"
        fi
        { [ "$st" -gt 1 ] && head -n $((st - 1)) "$w"
          [ -s "$TMP/rep" ] && { cat "$TMP/rep"; [ -n "$(tail -c 1 "$TMP/rep")" ] && echo; }
          tail -n +$((en + 1)) "$w"; } > "$TMP/new"
        mv "$TMP/new" "$w" ;;
      esac ;;
    esac
  done < "$TMP/ops/index"

  # what changed?
  local i changed=() ch=0 unch=0 nl
  for ((i = 0; i < ${#P_REL[@]}; i++)); do
    if [ "${O_EX[i]}" != "${W_EX[i]}" ] || { [ "${W_EX[i]}" = 1 ] && ! cmp -s "$TMP/o$i" "$TMP/w$i"; }; then
      changed+=("$i")
    else unch=$((unch + 1)); fi
  done
  for i in "${changed[@]}"; do
    if [ "${W_EX[i]}" = 0 ]; then say ""; say "${RED}  DELETE ${P_REL[i]}${R}"
    elif [ "${O_EX[i]}" = 0 ]; then nl=$(wc -l < "$TMP/w$i" | tr -d ' '); say ""; say "${GRN}  NEW ${P_REL[i]}${R}${DIM} ($nl lines)${R}"
    else say ""; show_diff "${P_REL[i]}" "$TMP/o$i" "$TMP/w$i"; fi
  done
  [ -n "$ERRS" ] && printf '%s' "$ERRS" >&2
  local nerr=0; [ -n "$ERRS" ] && nerr=$(printf '%s' "$ERRS" | grep -c .)
  ch=${#changed[@]}
  say ""
  local msg="  ${GRN}$ch file(s) to change${R}"
  [ "$unch" -gt 0 ] && msg="$msg${DIM}, $unch unchanged${R}"
  [ "$nerr" -gt 0 ] && msg="$msg${RED}, $nerr failed block(s)${R}"
  say "$msg"
  local rc=0; [ "$nerr" -gt 0 ] && rc=1
  [ "$ch" -eq 0 ] && return $rc
  [ "$dry" = 1 ] && { say "${YEL}  dry run - nothing written${R}"; return $rc; }
  if [ "$yes" = 0 ]; then
    { [ "$src" = - ] || ! [ -t 0 ]; } && die "not a terminal, can't ask - re-run with -y to apply" "" 1
    printf '%s' "${B}  apply these changes? [y/N] ${R}" >&2
    local ans; read -r ans
    case $(lower "$ans") in y|yes) ;; *) say "${DIM}  nothing changed${R}"; return 1;; esac
  fi
  local bak=""
  if [ "$nobak" = 0 ]; then
    bak="$aroot/.llmux-backup/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$bak"; : > "$bak/.created"
  fi
  local full
  for i in "${changed[@]}"; do
    full="$aroot/${P_REL[i]}"
    if [ -n "$bak" ]; then
      if [ "${O_EX[i]}" = 1 ]; then mkdir -p "$(dirname "$bak/${P_REL[i]}")"; cp -p "$full" "$bak/${P_REL[i]}"
      else printf '%s\n' "${P_REL[i]}" >> "$bak/.created"; fi
    fi
    if [ "${W_EX[i]}" = 0 ]; then rm -f "$full"; continue; fi
    mkdir -p "$(dirname "$full")"
    if [ "${CRLF[i]}" = 1 ]; then awk '{ printf "%s\r\n", $0 }' "$TMP/w$i" > "$full"
    else cat "$TMP/w$i" > "$full"; fi
  done
  say "${GRN}✓ applied $ch file(s)${R}"
  [ -n "$bak" ] && say "${DIM}  backup: ${bak#$aroot/}   undo: ${R}${CYN}llmux undo${R}"
  return $rc
}

cmd_undo() {
  local root="." a
  for a in "$@"; do case $a in -*) ;; *) root=$a;; esac; done
  root=$(cd "$root" && pwd -P) || die "bad folder"
  local bdir="$root/.llmux-backup" last src n=0 removed=0 rel
  [ -d "$bdir" ] && last=$(ls "$bdir" | sort | tail -n 1)
  [ -n "${last:-}" ] || die "no backups found here"
  src="$bdir/$last"
  if [ -f "$src/.created" ]; then
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      rel=$(safe_rel "$rel") || continue
      [ -f "$root/$rel" ] && { rm -f "$root/$rel"; removed=$((removed + 1)); }
    done < "$src/.created"
    rm -f "$src/.created"
  fi
  while IFS= read -r rel; do
    rel=${rel#./}; [ -z "$rel" ] && continue
    mkdir -p "$(dirname "$root/$rel")"; cp -p "$src/$rel" "$root/$rel"; n=$((n + 1))
  done <<< "$(cd "$src" && find . -type f)"
  rm -rf "$src"
  say "${GRN}✓ undo $last: restored $n, removed $removed new file(s)${R}"
}

cmd_count() {
  [ $# -gt 0 ] || die "count what?" "llmux count file.txt   (or a folder: llmux . -n)"
  local p total=0 t s k=0
  for p in "$@"; do
    case $p in --no-color) continue;; esac
    [ -d "$p" ] && die "'$p' is a folder" "use: llmux $p --dry-run"
    [ -f "$p" ] || die "'$p' not found"
    s=$(file_size "$p"); t=$(tok_est "$p" "$s"); total=$((total + t)); k=$((k + 1))
    say "  $(printf '%8s' "$(htok "$t")")  $p  ${DIM}$(human "$s")${R}"
  done
  [ $k -gt 1 ] && say "${B}  $(printf '%8s' "$(htok "$total")")  total${R}"
  say "${DIM}  (estimate)${R}"
}

help_main() {
  cat >&2 <<EOF
${CYN}${B}llmux${R} ${DIM}$VERSION (bash)${R} - make a folder LLM paste-ready, then apply the LLM's edits back.

${B}USAGE${R}
  ${CYN}llmux${R} ${YEL}<folder>${R} [flags]       pack a folder into one file
  ${CYN}llmux apply${R} ${YEL}<reply>${R} [flags]  apply an LLM reply (edit blocks or a full pack)
  ${CYN}llmux undo${R}                  restore files from the last apply
  ${CYN}llmux count${R} ${YEL}<file>...${R}        count tokens (estimate)

${B}PACK FLAGS${R}
  ${GRN}-f, --format${R} xml|md|txt   output format            ${DIM}[xml]${R}
  ${GRN}-o, --output${R} FILE         output file              ${DIM}[llmux-<dir>-<time>.<fmt>]${R}
  ${GRN}-d, --depth${R} N             0 = unlimited, 1 = this folder only ${DIM}[5]${R}
  ${GRN}-s, --max-file-size${R} SIZE  skip files bigger than this ${DIM}[50k]${R}
  ${GRN}-m, --max-size${R} SIZE       stop when output reaches this ${DIM}[1m]${R}
  ${GRN}-t, --max-tokens${R} N        stop when output reaches N tokens ${DIM}[off]${R}
  ${GRN}-i, --include${R} GLOBS       only these, e.g. "src/*,*.py"
  ${GRN}-x, --exclude${R} GLOBS       skip these, e.g. "docs/,*.test.js"
  ${GRN}-n, --dry-run${R}             show what would be packed, write nothing
  ${GRN}-c, --stdout${R}              print to stdout (pipe to pbcopy / xclip)
  ${GRN}-a, --hidden${R}              include dotfiles / dot-folders
      ${GRN}--split${R}               write part1, part2… instead of stopping ${DIM}(max 10)${R}
      ${GRN}--no-tree${R} / ${GRN}--no-header${R} / ${GRN}--no-instructions${R}
      ${GRN}--no-gitignore${R}        ignore .gitignore rules
      ${GRN}--allow-secrets${R}       include .env, keys, etc. ${DIM}(off by default)${R}
      ${GRN}--force${R}               allow packing ~ or / ${DIM}(refused by default)${R}
      ${GRN}--max-scan${R} N / ${GRN}--max-time${R} SEC  safety stop for huge trees ${DIM}[20000 / 20s]${R}

${B}APPLY FLAGS${R}
  ${GRN}-n, --dry-run${R}   preview diff only     ${GRN}-y, --yes${R}  don't ask
  ${GRN}-C, --dir${R} DIR   project folder [.]     ${GRN}--no-backup${R}

${B}EXAMPLES${R}
  ${DIM}\$${R} llmux .                       ${DIM}# pack current folder → llmux-<name>-<time>.xml${R}
  ${DIM}\$${R} llmux src -f md -d 0          ${DIM}# markdown, all depths${R}
  ${DIM}\$${R} llmux . -t 100k -i "*.py"     ${DIM}# python only, max 100k tokens${R}
  ${DIM}\$${R} llmux . -c | pbcopy           ${DIM}# straight to clipboard (macOS)${R}
  ${DIM}\$${R} llmux apply reply.txt -n      ${DIM}# preview LLM edits${R}
  ${DIM}\$${R} llmux apply reply.txt         ${DIM}# apply them (backup kept)${R}
EOF
}

main() {
  [ $# -eq 0 ] && { help_main; return 0; }
  case $1 in
    -h|--help|help) help_main;;
    -V|--version|version) echo "llmux $VERSION (bash)";;
    apply) shift; case ${1:-} in -h|--help) help_main;; *) cmd_apply "$@";; esac;;
    undo) shift; cmd_undo "$@";;
    count) shift; cmd_count "$@";;
    pack) shift; cmd_pack "$@";;
    *) cmd_pack "$@";;
  esac
}

main "$@"
