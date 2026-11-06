#!/usr/bin/env python3
"""llmux - pack a directory into one LLM-ready file, and apply LLM edits back.

Single file, no required dependencies (Python 3.8+).
Optional: `pip install tiktoken` for exact token counts (else a fast estimate).
"""
import datetime
import difflib
import fnmatch
import os
import re
import shutil
import sys
import time
from collections import Counter, deque

VERSION = "0.1.0"

# ----------------------------------------------------------------- defaults --
DEF_DEPTH = 5               # 0 = unlimited, 1 = only files in the dir itself
DEF_FILE_MAX = 50 * 1024    # per file
DEF_TOTAL_MAX = 1024 * 1024 # whole output
DEF_MAX_SCAN = 20000        # entries visited before we give up (safety)
DEF_MAX_TIME = 20.0         # seconds spent scanning before we give up (safety)

SKIP_DIRS = {
    ".git", ".hg", ".svn", "node_modules", "bower_components", "vendor",
    "__pycache__", ".venv", "venv", "env", ".env", ".tox", ".nox",
    ".mypy_cache", ".pytest_cache", ".ruff_cache", ".cache", ".gradle",
    ".idea", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache",
    "dist", "build", "out", "target", "coverage", ".terraform",
    ".llmux-backup", "site-packages", ".cargo", ".rustup", ".npm", ".nvm",
    "Library", "AppData", ".local", ".vscode-server", ".DS_Store",
}
SKIP_FILES = {
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
    "Cargo.lock", "poetry.lock", "Pipfile.lock", "composer.lock",
    "Gemfile.lock", "go.sum", "uv.lock", ".DS_Store", "Thumbs.db",
}
SKIP_GLOBS = ["*.min.js", "*.min.css", "*.map", "*.lock", "llmux-*.xml",
              "llmux-*.md", "llmux-*.txt"]
SECRET_GLOBS = [".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx",
                "id_rsa*", "id_ed25519*", "id_ecdsa*", "*.keystore",
                ".npmrc", ".pypirc", ".netrc", "credentials*", "*.kdbx"]
BINARY_EXT = set("""
png jpg jpeg gif bmp ico webp tiff tif psd svgz heic avif raw
mp3 wav flac ogg m4a aac mp4 mkv mov avi webm wmv flv
zip tar gz tgz bz2 xz 7z rar zst jar war ear whl egg
exe dll so dylib bin o a lib obj class pyc pyo pyd wasm
pdf doc docx xls xlsx ppt pptx odt ods odp epub
ttf otf woff woff2 eot sqlite sqlite3 db mdb dat iso img dmg
npy npz pkl pickle pt pth onnx h5 safetensors ckpt parquet
""".split())

# ------------------------------------------------------------------- colors --
def _color_ok():
    if os.environ.get("NO_COLOR") or "--no-color" in sys.argv:
        return False
    if not hasattr(sys.stderr, "isatty") or not sys.stderr.isatty():
        return False
    if os.name == "nt":
        os.system("")  # turns on ANSI escape codes in Windows terminals
    return True

COLOR = _color_ok()

def _c(code):
    return lambda s: f"\033[{code}m{s}\033[0m" if COLOR else str(s)

bold, dim, red, green, yellow, blue, cyan, magenta = (
    _c("1"), _c("2"), _c("31"), _c("32"), _c("33"), _c("34"), _c("36"), _c("35"))

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

def say(*a):
    print(*a, file=sys.stderr)

def die(msg, hint=None, code=2):
    say(red("✗ ") + msg)
    if hint:
        say(dim("  hint: ") + hint)
    sys.exit(code)

# ------------------------------------------------------------------ helpers --
def parse_size(s):
    m = re.fullmatch(r"\s*([\d.]+)\s*([kmg]?)i?b?\s*", str(s).lower())
    if not m:
        die(f"bad size '{s}'", "use e.g. 50k, 1m, 2mb, 4096")
    n = float(m.group(1)) * {"": 1, "k": 1024, "m": 1024**2, "g": 1024**3}[m.group(2)]
    return int(n)

def parse_count(s):
    m = re.fullmatch(r"\s*([\d.]+)\s*([km]?)\s*", str(s).lower())
    if not m:
        die(f"bad number '{s}'", "use e.g. 128k, 200000, 1m")
    return int(float(m.group(1)) * {"": 1, "k": 1000, "m": 1000000}[m.group(2)])

def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024

def htok(n):
    return f"{n/1000:.1f}k" if n >= 1000 else str(n)

# ------------------------------------------------------------ token counter --
_ENC = None
_ENC_NAME = None

def _load_encoder():
    global _ENC, _ENC_NAME
    if _ENC_NAME is not None:
        return
    _ENC_NAME = "estimate"
    if os.environ.get("LLMUX_NO_TIKTOKEN"):
        return
    try:
        import tiktoken
        _ENC = tiktoken.get_encoding("o200k_base")
        _ENC_NAME = "tiktoken o200k_base"
    except Exception:
        pass

_NON_ASCII = re.compile(r"[^\x00-\x7f]")

def count_tokens(text):
    _load_encoder()
    if _ENC is not None:
        return len(_ENC.encode(text, disallowed_special=()))
    # estimate: ASCII bytes / 4.2 (within ~1% of o200k on 1.5k real code files),
    # non-ASCII chars ~0.8 token each (CJK, emoji, accents)
    na = len(_NON_ASCII.findall(text))
    return int((len(text) - na) / 4.2 + na * 0.8 + 0.5)

# ---------------------------------------------------------------- gitignore --
def glob_to_regex(pat):
    i, out = 0, ""
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**/", i):
            out += "(?:.*/)?"; i += 3; continue
        if pat.startswith("/**", i) and i + 3 == len(pat):
            out += "/.*"; i += 3; continue
        if pat.startswith("**", i):
            out += ".*"; i += 2; continue
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        elif c == "[":
            j = pat.find("]", i + 1)
            if j == -1:
                out += re.escape(c)
            else:
                body = pat[i + 1:j].replace("\\", "\\\\")
                if body.startswith("!"):
                    body = "^" + body[1:]
                out += f"[{body}]"; i = j
        else:
            out += re.escape(c)
        i += 1
    return out

class IgnoreRules:
    """Rules from one .gitignore, relative to its folder."""
    def __init__(self, base, lines):
        self.base = base
        self.rules = []
        for raw in lines:
            line = raw.rstrip("\n").rstrip()
            if not line or line.startswith("#"):
                continue
            neg = line.startswith("!")
            if neg:
                line = line[1:]
            dir_only = line.endswith("/")
            line = line.rstrip("/")
            if not line:
                continue
            anchored = "/" in line
            line = line.lstrip("/")
            rx = glob_to_regex(line)
            rx = ("^" if anchored else "^(?:.*/)?") + rx + "$"
            self.rules.append((re.compile(rx), neg, dir_only))

    def check(self, relpath, is_dir):
        """None = no opinion, True = ignored, False = re-included."""
        result = None
        for rx, neg, dir_only in self.rules:
            if dir_only and not is_dir:
                continue
            if rx.match(relpath):
                result = not neg
        return result

def is_ignored(stack, abspath, is_dir):
    result = None
    for rules in stack:
        rel = os.path.relpath(abspath, rules.base).replace(os.sep, "/")
        r = rules.check(rel, is_dir)
        if r is not None:
            result = r
    return bool(result)

def match_any(globs, relpath):
    name = relpath.rsplit("/", 1)[-1]
    for g in globs:
        if fnmatch.fnmatch(relpath, g) or fnmatch.fnmatch(name, g):
            return True
        if g.endswith("/") and (relpath + "/").startswith(g):
            return True
    return False

# --------------------------------------------------------------------- scan --
PACK_MARK = re.compile(r'^<llmux version=|generated: .* by llmux \d', re.M)

def looks_binary(path):
    try:
        with open(path, "rb") as f:
            chunk = f.read(8192)
    except OSError:
        return True
    if b"\x00" in chunk:
        return True
    if not chunk:
        return False
    ctrl = sum(1 for b in chunk if b < 9 or (13 < b < 32))
    return ctrl / len(chunk) > 0.10

def danger_root(root):
    root = os.path.realpath(root)
    home = os.path.realpath(os.path.expanduser("~"))
    if root == home:
        return "your home folder"
    if os.path.dirname(root) == root:
        return "a filesystem root"
    if root in ("/usr", "/etc", "/var", "/opt", "/Users", "/home",
                "C:\\Windows", "C:\\Users", "C:\\Program Files"):
        return "a system folder"
    return None

class Scan:
    def __init__(self):
        self.files = []          # (rel, abs, size, text, tokens)
        self.skipped = Counter()
        self.skipped_big = []    # (rel, size)
        self.secrets = []
        self.total_bytes = 0
        self.total_tokens = 0
        self.visited = 0
        self.stop_reason = None
        self.depth_hit = False

def scan(root, o):
    """Breadth-first walk: shallow files first, so the important top-level
    stuff fits before limits kick in. Stops early on any budget."""
    s = Scan()
    t0 = time.time()
    cap_bytes = o.total_max * (o.max_parts if o.split else 1)
    cap_tokens = o.max_tokens * (o.max_parts if o.split else 1) if o.max_tokens else 0
    queue = deque([(root, 1, [])])
    while queue:
        d, depth, stack = queue.popleft()
        if not o.no_gitignore:
            gi = os.path.join(d, ".gitignore")
            if os.path.isfile(gi):
                try:
                    with open(gi, encoding="utf-8-sig", errors="replace") as f:
                        stack = stack + [IgnoreRules(d, f.readlines())]
                except OSError:
                    pass
        try:
            entries = sorted(os.scandir(d), key=lambda e: (not e.is_file(), e.name.lower()))
        except OSError:
            s.skipped["unreadable dir"] += 1
            continue
        for e in entries:
            s.visited += 1
            if s.visited > o.max_scan:
                s.stop_reason = f"looked at {o.max_scan} entries (--max-scan)"
                return s
            if time.time() - t0 > o.max_time:
                s.stop_reason = f"scanning took over {o.max_time:.0f}s (--max-time)"
                return s
            rel = os.path.relpath(e.path, root).replace(os.sep, "/")
            try:
                is_dir = e.is_dir(follow_symlinks=False)
                is_file = e.is_file(follow_symlinks=False)
            except OSError:
                continue
            if e.is_symlink():
                s.skipped["symlink"] += 1
                continue
            if is_dir:
                if e.name in SKIP_DIRS and not match_any(o.include, rel + "/"):
                    s.skipped["junk dir"] += 1; continue
                if not o.hidden and e.name.startswith(".") and e.name not in (".github",):
                    s.skipped["hidden"] += 1; continue
                if match_any(o.exclude, rel) or match_any(o.exclude, rel + "/"):
                    s.skipped["excluded"] += 1; continue
                if stack and is_ignored(stack, e.path, True):
                    s.skipped["gitignore"] += 1; continue
                if o.depth == 0 or depth < o.depth:
                    queue.append((e.path, depth + 1, stack))
                else:
                    s.depth_hit = True
                    s.skipped["too deep"] += 1
                continue
            if not is_file:
                continue
            name = e.name
            if os.path.abspath(e.path) == o.out_abs:
                continue
            if o.include and not match_any(o.include, rel):
                s.skipped["not included"] += 1; continue
            if match_any(o.exclude, rel):
                s.skipped["excluded"] += 1; continue
            if not o.allow_secrets and match_any(SECRET_GLOBS, rel):
                s.secrets.append(rel); s.skipped["secret"] += 1; continue
            if name in SKIP_FILES or match_any(SKIP_GLOBS, rel):
                s.skipped["lock/min/generated"] += 1; continue
            if not o.hidden and name.startswith(".") and name not in (
                    ".gitignore", ".editorconfig", ".dockerignore", ".gitattributes"):
                s.skipped["hidden"] += 1; continue
            if stack and is_ignored(stack, e.path, False):
                s.skipped["gitignore"] += 1; continue
            ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
            if ext in BINARY_EXT:
                s.skipped["binary"] += 1; continue
            try:
                size = e.stat().st_size
            except OSError:
                continue
            if size > o.file_max:
                s.skipped["too big (-s)"] += 1
                s.skipped_big.append((rel, size)); continue
            if size == 0:
                s.skipped["empty"] += 1; continue
            if looks_binary(e.path):
                s.skipped["binary"] += 1; continue
            try:
                with open(e.path, "rb") as f:
                    raw = f.read()
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                s.skipped["not utf-8"] += 1; continue
            except OSError:
                s.skipped["unreadable"] += 1; continue
            text = text.lstrip("﻿").replace("\r\n", "\n")
            if PACK_MARK.search(text[:600]):
                s.skipped["old llmux output"] += 1; continue
            nbytes = len(text.encode("utf-8"))
            toks = count_tokens(text)
            if s.total_bytes + nbytes > cap_bytes or (cap_tokens and s.total_tokens + toks > cap_tokens):
                which = "token" if cap_tokens and s.total_tokens + toks > cap_tokens else "size"
                s.stop_reason = f"output {which} limit reached"
                s.skipped["over total limit"] += 1
                return s   # stop: no point scanning more
            s.files.append((rel, e.path, nbytes, text, toks))
            s.total_bytes += nbytes
            s.total_tokens += toks
    return s

# ------------------------------------------------------------------- render --
def build_tree(paths):
    tree = {}
    for p in paths:
        node = tree
        for part in p.split("/"):
            node = node.setdefault(part, {})
    lines = []
    def walk(node, prefix):
        items = sorted(node.items(), key=lambda kv: (not kv[1], kv[0].lower()))
        for i, (name, child) in enumerate(items):
            last = i == len(items) - 1
            lines.append(prefix + ("└── " if last else "├── ") + name + ("/" if child else ""))
            if child:
                walk(child, prefix + ("    " if last else "│   "))
    walk(tree, "")
    return "\n".join(lines)

EDIT_GUIDE = """When you change code, reply ONLY with edit blocks in this exact format
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
- Do not use line numbers or unified diffs."""

def fence_for(text):
    longest = max((len(m) for m in re.findall(r"`{3,}", text)), default=2)
    return "`" * max(3, longest + 1)

def render(fmt, root_name, files, s, o, part=None, parts=None):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    tree = build_tree([f[0] for f in files])
    nbytes = sum(f[2] for f in files)
    ntok = sum(f[4] for f in files)
    info = [f"project: {root_name}", f"generated: {now} by llmux {VERSION}",
            f"files: {len(files)}", f"size: {human(nbytes)}",
            f"tokens: {ntok} ({_ENC_NAME})"]
    if part:
        info.append(f"part: {part} of {parts}")
    if s.stop_reason:
        info.append(f"NOTE: incomplete - {s.stop_reason}")
    out = []
    if fmt == "xml":
        out.append(f'<llmux version="{VERSION}" project="{root_name}">')
        if not o.no_header:
            out.append("<summary>\n" + "\n".join(info) + "\n</summary>")
            if not o.no_instructions:
                out.append("<instructions>\n" + EDIT_GUIDE + "\n</instructions>")
            if not o.no_tree:
                out.append("<directory_structure>\n" + tree + "\n</directory_structure>")
        out.append("<files>")
        for rel, _, size, text, toks in files:
            out.append(f'<file path="{rel}" tokens="{toks}">\n{text.rstrip(chr(10))}\n</file>')
        out.append("</files>\n</llmux>")
    elif fmt == "md":
        out.append(f"# {root_name}\n")
        if not o.no_header:
            out.append("## Summary\n\n" + "\n".join("- " + i for i in info) + "\n")
            if not o.no_instructions:
                out.append("## How to reply with edits\n\n```text\n" + EDIT_GUIDE + "\n```\n")
            if not o.no_tree:
                out.append("## Directory structure\n\n```text\n" + tree + "\n```\n")
        out.append("## Files\n")
        for rel, _, size, text, toks in files:
            ext = rel.rsplit(".", 1)[-1] if "." in rel.rsplit("/", 1)[-1] else ""
            fe = fence_for(text)
            out.append(f"### File: {rel}\n\n{fe}{ext}\n{text.rstrip(chr(10))}\n{fe}\n")
    else:
        bar = "=" * 64
        out.append(f"{bar}\n{root_name}\n{bar}")
        if not o.no_header:
            out.append("SUMMARY\n" + "\n".join(info) + "\n")
            if not o.no_instructions:
                out.append("HOW TO REPLY WITH EDITS\n" + EDIT_GUIDE + "\n")
            if not o.no_tree:
                out.append("DIRECTORY STRUCTURE\n" + tree + "\n")
        for rel, _, size, text, toks in files:
            out.append(f"===== FILE: {rel} =====\n{text.rstrip(chr(10))}\n===== END FILE =====\n")
    return "\n".join(out) + "\n"

# --------------------------------------------------------------------- pack --
class Opts:
    pass

def cmd_pack(args):
    o = Opts()
    o.fmt, o.out, o.depth = "xml", None, DEF_DEPTH
    o.file_max, o.total_max, o.max_tokens = DEF_FILE_MAX, DEF_TOTAL_MAX, 0
    o.include, o.exclude = [], []
    o.no_tree = o.no_header = o.no_instructions = o.no_gitignore = False
    o.hidden = o.force = o.dry = o.stdout = o.split = o.allow_secrets = False
    o.max_parts, o.max_scan, o.max_time = 10, DEF_MAX_SCAN, DEF_MAX_TIME
    target = None
    it = iter(args)
    def val(flag):
        try:
            return next(it)
        except StopIteration:
            die(f"{flag} needs a value", f"see: llmux --help")
    for a in it:
        if a in ("-f", "--format"):
            o.fmt = val(a).lower().replace("markdown", "md").replace("text", "txt").replace("plain", "txt")
            if o.fmt not in ("xml", "md", "txt"):
                die(f"unknown format '{o.fmt}'", "use xml, md or txt")
        elif a in ("-o", "--output"): o.out = val(a)
        elif a in ("-d", "--depth"):
            v = val(a)
            if not v.isdigit():
                die(f"bad depth '{v}'", "0 = unlimited, 1 = this folder only, 5 = default")
            o.depth = int(v)
        elif a in ("-s", "--max-file-size"): o.file_max = parse_size(val(a))
        elif a in ("-m", "--max-size"): o.total_max = parse_size(val(a))
        elif a in ("-t", "--max-tokens"): o.max_tokens = parse_count(val(a))
        elif a in ("-i", "--include"): o.include += [g.strip() for g in val(a).split(",") if g.strip()]
        elif a in ("-x", "--exclude"): o.exclude += [g.strip() for g in val(a).split(",") if g.strip()]
        elif a == "--no-tree": o.no_tree = True
        elif a == "--no-header": o.no_header = True
        elif a == "--no-instructions": o.no_instructions = True
        elif a == "--no-gitignore": o.no_gitignore = True
        elif a in ("-a", "--hidden"): o.hidden = True
        elif a == "--allow-secrets": o.allow_secrets = True
        elif a == "--force": o.force = True
        elif a in ("-n", "--dry-run"): o.dry = True
        elif a in ("-c", "--stdout"): o.stdout = True
        elif a == "--split": o.split = True
        elif a == "--max-parts": o.max_parts = parse_count(val(a))
        elif a == "--max-scan": o.max_scan = parse_count(val(a))
        elif a == "--max-time": o.max_time = float(val(a))
        elif a == "--no-color": pass
        elif a.startswith("-") and a != "-":
            die(f"unknown flag '{a}'", "see: llmux --help")
        elif target is None:
            target = a
        else:
            die(f"only one folder at a time (got '{target}' and '{a}')")
    target = os.path.expanduser(target or ".")
    if not os.path.isdir(target):
        die(f"'{target}' is not a folder")
    root = os.path.realpath(target)
    root_name = os.path.basename(root) or root
    danger = danger_root(root)
    if danger and not o.force:
        die(f"'{root}' is {danger}. Packing it is almost always a mistake.",
            "cd into a project folder, or add --force if you really mean it")
    if not o.out:
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        safe = re.sub(r"[^\w.-]+", "_", root_name)
        o.out = f"llmux-{safe}-{stamp}.{o.fmt}"
    o.out_abs = os.path.abspath(o.out)

    say(cyan("◆ llmux") + dim(f" {VERSION}") + "  packing " + bold(root))
    depth_txt = "unlimited" if o.depth == 0 else ("this folder only" if o.depth == 1 else str(o.depth))
    lim = f"depth {depth_txt} · file ≤ {human(o.file_max)} · total ≤ {human(o.total_max)}"
    if o.max_tokens:
        lim += f" · ≤ {htok(o.max_tokens)} tokens"
    say(dim("  " + lim))

    s = scan(root, o)
    files = s.files

    # split into parts if asked
    parts = [files]
    if o.split:
        parts, cur, cb, ct = [], [], 0, 0
        for f in files:
            if cur and (cb + f[2] > o.total_max or (o.max_tokens and ct + f[4] > o.max_tokens)):
                parts.append(cur); cur, cb, ct = [], 0, 0
            cur.append(f); cb += f[2]; ct += f[4]
        if cur:
            parts.append(cur)

    print_report(s, o)
    if not files:
        die("nothing to pack", "check the folder, or loosen -s / -d / -i / -x", code=1)
    if o.dry:
        say(yellow("  dry run - nothing written"))
        return 0

    written = []
    for idx, pf in enumerate(parts, 1):
        p, n = (idx, len(parts)) if len(parts) > 1 else (None, None)
        text = render(o.fmt, root_name, pf, s, o, p, n)
        if o.stdout:
            sys.stdout.write(text)
            continue
        path = o.out
        if n:
            stem, ext = os.path.splitext(o.out)
            path = f"{stem}.part{idx}{ext}"
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        written.append((path, len(text.encode("utf-8"))))
    for path, size in written:
        say(green("✓ wrote ") + bold(path) + dim(f"  ({human(size)})"))
    if written:
        say(dim("  next: paste it into your LLM. Save its reply, then: ") + cyan(f"llmux apply reply.txt"))
    return 0

def print_report(s, o):
    say("")
    say(f"  {bold('files')}   {green(len(s.files))}")
    say(f"  {bold('size')}    {human(s.total_bytes)}")
    say(f"  {bold('tokens')}  {htok(s.total_tokens)} {dim('(' + (_ENC_NAME or 'estimate') + ')')}")
    if s.files:
        top = sorted(s.files, key=lambda f: -f[4])[:5]
        say(dim("  biggest:"))
        for rel, _, size, _, toks in top:
            pct = 100 * toks / max(1, s.total_tokens)
            say(f"    {htok(toks):>7} {dim(f'{pct:4.1f}%')}  {rel}")
    if s.skipped:
        say(dim("  skipped: ") + dim(", ".join(f"{k} {v}" for k, v in s.skipped.most_common())))
    if s.skipped_big:
        names = ", ".join(f"{r} ({human(z)})" for r, z in sorted(s.skipped_big, key=lambda x: -x[1])[:4])
        say(yellow("  ! too big, left out: ") + names + dim("  → raise with -s 200k"))
    if s.secrets:
        say(yellow("  ! secrets left out: ") + ", ".join(s.secrets[:5]) + dim("  (--allow-secrets to include)"))
    if s.depth_hit:
        say(dim("  some folders were deeper than -d; use -d 0 for unlimited"))
    if s.stop_reason:
        say(yellow("  ! stopped early: ") + s.stop_reason)
        say(dim("    output is partial. Narrow it with -i 'src/**' or -x 'docs/', or raise -m / -t / --split"))
    say("")

# -------------------------------------------------------------------- apply --
FILE_RE = re.compile(r"^[\s>*#`_-]*(FILE|DELETE)\s*:\s*[`*_\"']*(.+?)[`*_\"']*\s*$")
S_START = re.compile(r"^\s*<{5,9}\s*SEARCH\s*$")
S_MID = re.compile(r"^\s*={5,9}\s*$")
S_END = re.compile(r"^\s*>{5,9}\s*REPLACE\s*$")
F_START = re.compile(r"^\s*<{5,9}\s*FULL\s*$")
F_END = re.compile(r"^\s*>{5,9}\s*END\s*$")

def parse_edits(text):
    """Returns list of ops: ('edit', path, search, replace) / ('full', path, body) / ('delete', path)."""
    lines = text.replace("\r\n", "\n").split("\n")
    ops, path, i = [], None, 0
    while i < len(lines):
        ln = lines[i]
        m = FILE_RE.match(ln)
        if m:
            kind, p = m.group(1).upper(), m.group(2).strip()
            if kind == "DELETE":
                ops.append(("delete", p, i + 1))
            else:
                path = p
            i += 1; continue
        if S_START.match(ln):
            start = i + 1
            j = i + 1; search = []
            while j < len(lines) and not S_MID.match(lines[j]):
                search.append(lines[j]); j += 1
            k = j + 1; repl = []
            while k < len(lines) and not S_END.match(lines[k]):
                repl.append(lines[k]); k += 1
            if j >= len(lines) or k >= len(lines):
                ops.append(("broken", path, start)); break
            ops.append(("edit", path, "\n".join(search), "\n".join(repl), start))
            i = k + 1; continue
        if F_START.match(ln):
            start = i + 1
            j = i + 1; body = []
            while j < len(lines) and not F_END.match(lines[j]):
                body.append(lines[j]); j += 1
            if j >= len(lines):
                ops.append(("broken", path, start)); break
            ops.append(("full", path, "\n".join(body), start))
            i = j + 1; continue
        i += 1
    return ops

def parse_pack(text):
    """A whole llmux pack (maybe edited by the LLM) → list of ('full', path, body)."""
    text = text.replace("\r\n", "\n")
    ops = []
    for m in re.finditer(r'<file path="([^"]+)"[^>]*>\n(.*?)\n</file>', text, re.S):
        ops.append(("full", m.group(1), m.group(2), 0))
    if ops:
        return ops
    for m in re.finditer(r"^===== FILE: (.+?) =====\n(.*?)\n===== END FILE =====$", text, re.S | re.M):
        ops.append(("full", m.group(1), m.group(2), 0))
    if ops:
        return ops
    for m in re.finditer(r"^### File: (.+?)\n\n(`{3,})[^\n]*\n(.*?)\n\2\s*$", text, re.S | re.M):
        ops.append(("full", m.group(1), m.group(3), 0))
    return ops

def find_block(content, search):
    """Locate search in content. Returns (start, end, how) or error string."""
    n = content.count(search)
    if n == 1:
        i = content.index(search)
        return i, i + len(search), "exact"
    if n > 1:
        return f"SEARCH matches {n} places - add more context lines"
    clines = content.split("\n")
    slines = search.split("\n")
    while slines and not slines[0].strip():
        slines = slines[1:]
    while slines and not slines[-1].strip():
        slines = slines[:-1]
    if not slines:
        return "SEARCH is only blank lines"
    for how, norm in (("trailing spaces", str.rstrip), ("indentation", str.strip)):
        target = [norm(x) for x in slines]
        hits = [i for i in range(len(clines) - len(slines) + 1)
                if [norm(x) for x in clines[i:i + len(slines)]] == target]
        if len(hits) == 1:
            i = hits[0]
            start = sum(len(x) + 1 for x in clines[:i])
            end = start + len("\n".join(clines[i:i + len(slines)]))
            return start, end, how
        if len(hits) > 1:
            return f"SEARCH matches {len(hits)} places (ignoring {how}) - add more context"
    return "SEARCH text not found in file"

def reindent(repl, found, search):
    """When we matched ignoring indentation, shift the replacement the same way."""
    def lead(s):
        for ln in s.split("\n"):
            if ln.strip():
                return ln[:len(ln) - len(ln.lstrip())]
        return ""
    have, want = lead(search), lead(found)
    if have == want:
        return repl
    out = []
    for ln in repl.split("\n"):
        if ln.startswith(have):
            ln = want + ln[len(have):]
        elif ln.strip():
            ln = want + ln.lstrip()
        out.append(ln)
    return "\n".join(out)

def safe_path(root, rel):
    rel = rel.strip().strip("`").replace("\\", "/")
    if rel.startswith("./"):
        rel = rel[2:]
    if os.path.isabs(rel) or re.match(r"^[A-Za-z]:", rel):
        return None
    full = os.path.realpath(os.path.join(root, rel))
    if full != root and not full.startswith(root.rstrip(os.sep) + os.sep):
        return None
    return full

def read_text(path):
    with open(path, "rb") as f:
        raw = f.read().decode("utf-8")
    crlf = "\r\n" in raw
    return raw.lstrip("﻿").replace("\r\n", "\n"), crlf

def show_diff(rel, old, new):
    diff = list(difflib.unified_diff(old.split("\n"), new.split("\n"),
                                     f"a/{rel}", f"b/{rel}", n=2, lineterm=""))
    shown = 0
    for ln in diff:
        if shown > 120:
            say(dim(f"    … {len(diff) - shown} more diff lines"))
            break
        if ln.startswith(("+++", "---")):
            say(bold(ln))
        elif ln.startswith("@@"):
            say(cyan(ln))
        elif ln.startswith("+"):
            say(green(ln))
        elif ln.startswith("-"):
            say(red(ln))
        else:
            say(dim(ln))
        shown += 1

def cmd_apply(args):
    src, root, dry, yes, nobak = None, ".", False, False, False
    it = iter(args)
    for a in it:
        if a in ("-n", "--dry-run"): dry = True
        elif a in ("-y", "--yes"): yes = True
        elif a in ("-C", "--dir"):
            root = next(it, None) or die("--dir needs a folder")
        elif a == "--no-backup": nobak = True
        elif a == "--no-color": pass
        elif a.startswith("-") and a != "-":
            die(f"unknown flag '{a}'", "see: llmux apply --help")
        else:
            src = a
    if not src:
        die("which file has the LLM reply?", "llmux apply reply.txt   (or '-' to read from paste/stdin)")
    if src == "-":
        if sys.stdin.isatty():
            say(dim("paste the reply, then Ctrl-D (Ctrl-Z Enter on Windows):"))
        text = sys.stdin.read()
    else:
        if not os.path.isfile(src):
            die(f"'{src}' not found")
        with open(src, encoding="utf-8", errors="replace") as f:
            text = f.read()
    root = os.path.realpath(root)

    text = text.lstrip("﻿")
    ops, mode = [], "edit blocks"
    if PACK_MARK.search(text[:600]):
        ops, mode = parse_pack(text), "files from pack"
    if not ops:
        ops, mode = parse_edits(text), "edit blocks"
    if not ops:
        ops, mode = parse_pack(text), "files from pack"
    if not ops:
        die("no edits found in that file",
            "the reply needs FILE: + <<<<<<< SEARCH / ======= / >>>>>>> REPLACE blocks, "
            "or be a full llmux pack")
    say(cyan("◆ llmux apply") + dim(f"  {len(ops)} {mode} → ") + bold(root))

    newc, oldc, crlf_of, deletes, errors = {}, {}, {}, [], []
    for op in ops:
        kind, rel, line = op[0], op[1], op[-1]
        if kind == "broken":
            errors.append((rel or "?", line, "block is not closed (missing ======= or >>>>>>> line)"))
            continue
        if not rel:
            errors.append(("?", line, "block has no FILE: line above it"))
            continue
        full = safe_path(root, rel)
        if not full:
            errors.append((rel, line, "path is outside the project - refused"))
            continue
        if full not in newc:
            if os.path.isfile(full):
                try:
                    oldc[full], crlf_of[full] = read_text(full)
                except UnicodeDecodeError:
                    errors.append((rel, line, "file is not utf-8 text")); continue
            else:
                oldc[full], crlf_of[full] = None, False
            newc[full] = oldc[full]
        cur = newc[full]
        if kind == "delete":
            if cur is None:
                errors.append((rel, line, "cannot delete - file does not exist"))
            else:
                deletes.append(full); newc[full] = None
        elif kind == "full":
            body = op[2]
            if cur is not None and body.rstrip("\n") == cur.rstrip("\n"):
                continue   # same apart from trailing newlines - leave it alone
            newc[full] = body if body.endswith("\n") else body + "\n"
        else:
            search, repl = op[2], op[3]
            if not search.strip():
                newc[full] = (cur or "") + (repl if repl.endswith("\n") else repl + "\n")
                continue
            if cur is None:
                errors.append((rel, line, "file does not exist (use FULL block to create it)"))
                continue
            r = find_block(cur, search)
            if isinstance(r, str):
                errors.append((rel, line, r)); continue
            a, b, how = r
            if how == "indentation":
                repl = reindent(repl, cur[a:b], search)
            newc[full] = cur[:a] + repl + cur[b:]
            if how != "exact":
                say(yellow(f"  ~ {rel}: matched ignoring {how}"))

    changed = [p for p in newc if newc[p] != oldc[p]]
    for p in changed:
        rel = os.path.relpath(p, root).replace(os.sep, "/")
        if newc[p] is None:
            say(red(f"\n  DELETE {rel}"))
        elif oldc[p] is None:
            say(green(f"\n  NEW {rel}") + dim(f" ({newc[p].count(chr(10))} lines)"))
        else:
            say("")
            show_diff(rel, oldc[p], newc[p])
    for rel, line, why in errors:
        say(red(f"  ✗ {rel}") + dim(f" (reply line {line}): ") + why)
    unchanged = len(newc) - len(changed)
    say("")
    say(f"  {green(str(len(changed)) + ' file(s) to change')}"
        + (dim(f", {unchanged} unchanged") if unchanged else "")
        + (red(f", {len(errors)} failed block(s)") if errors else ""))
    if not changed:
        return 1 if errors else 0
    if dry:
        say(yellow("  dry run - nothing written"))
        return 1 if errors else 0
    if not yes:
        if not sys.stdin.isatty() or src == "-":
            die("not a terminal, can't ask - re-run with -y to apply", code=1)
        ans = input(bold("  apply these changes? [y/N] ")).strip().lower()
        if ans not in ("y", "yes"):
            say(dim("  nothing changed")); return 1
    bak = None
    if not nobak:
        bak = os.path.join(root, ".llmux-backup", datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    created = [os.path.relpath(p, root).replace(os.sep, "/") for p in changed if oldc[p] is None]
    if bak:
        os.makedirs(bak, exist_ok=True)
        with open(os.path.join(bak, ".created"), "w", encoding="utf-8") as f:
            f.write("\n".join(created))
    for p in changed:
        if bak and oldc[p] is not None:
            dst = os.path.join(bak, os.path.relpath(p, root))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(p, dst)
        if newc[p] is None:
            os.remove(p); continue
        os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
        data = newc[p].replace("\n", "\r\n") if crlf_of.get(p) else newc[p]
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(data)
    say(green(f"✓ applied {len(changed)} file(s)"))
    if bak:
        say(dim(f"  backup: {os.path.relpath(bak)}   undo: ") + cyan("llmux undo"))
    return 1 if errors else 0

def cmd_undo(args):
    pos = [a for a in args if not a.startswith("-")]
    root = os.path.realpath(pos[0] if pos else ".")
    bdir = os.path.join(root, ".llmux-backup")
    if not os.path.isdir(bdir) or not os.listdir(bdir):
        die("no backups found here")
    last = sorted(os.listdir(bdir))[-1]
    src = os.path.join(bdir, last)
    n, removed = 0, 0
    marker = os.path.join(src, ".created")
    if os.path.isfile(marker):
        with open(marker, encoding="utf-8") as f:
            for rel in filter(None, f.read().split("\n")):
                p = safe_path(root, rel)
                if p and os.path.isfile(p):
                    os.remove(p); removed += 1
        os.remove(marker)
    for d, _, fs in os.walk(src):
        for f in fs:
            s = os.path.join(d, f)
            dst = os.path.join(root, os.path.relpath(s, src))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(s, dst); n += 1
    shutil.rmtree(src)
    say(green(f"✓ undo {last}: restored {n}, removed {removed} new file(s)"))
    return 0

def cmd_count(args):
    if not args:
        die("count what?", "llmux count file.txt   (or a folder: llmux . -n)")
    total = 0
    for p in args:
        if os.path.isdir(p):
            die(f"'{p}' is a folder", f"use: llmux {p} --dry-run")
        with open(p, encoding="utf-8", errors="replace") as f:
            t = f.read()
        n = count_tokens(t)
        total += n
        say(f"  {htok(n):>8}  {p}  {dim(human(len(t.encode('utf-8'))))}")
    if len(args) > 1:
        say(bold(f"  {htok(total):>8}  total"))
    say(dim(f"  ({_ENC_NAME})"))
    return 0

# --------------------------------------------------------------------- help --
def help_main():
    say(f"""{cyan(bold('llmux'))} {dim(VERSION)} - make a folder LLM paste-ready, then apply the LLM's edits back.

{bold('USAGE')}
  {cyan('llmux')} {yellow('<folder>')} [flags]       pack a folder into one file
  {cyan('llmux apply')} {yellow('<reply>')} [flags]  apply an LLM reply (edit blocks or a full pack)
  {cyan('llmux undo')}                  restore files from the last apply
  {cyan('llmux count')} {yellow('<file>...')}        count tokens

{bold('PACK FLAGS')}
  {green('-f, --format')} xml|md|txt   output format            {dim('[xml]')}
  {green('-o, --output')} FILE         output file              {dim('[llmux-<dir>-<time>.<fmt>]')}
  {green('-d, --depth')} N             0 = unlimited, 1 = this folder only {dim('[5]')}
  {green('-s, --max-file-size')} SIZE  skip files bigger than this {dim('[50k]')}
  {green('-m, --max-size')} SIZE       stop when output reaches this {dim('[1m]')}
  {green('-t, --max-tokens')} N        stop when output reaches N tokens {dim('[off]')}
  {green('-i, --include')} GLOBS       only these, e.g. "src/**,*.py"
  {green('-x, --exclude')} GLOBS       skip these, e.g. "docs/,*.test.js"
  {green('-n, --dry-run')}             show what would be packed, write nothing
  {green('-c, --stdout')}              print to stdout (pipe to clipboard)
  {green('-a, --hidden')}              include dotfiles / dot-folders
      {green('--split')}               write part1, part2… instead of stopping {dim('(max 10)')}
      {green('--no-tree')} / {green('--no-header')} / {green('--no-instructions')}
      {green('--no-gitignore')}        ignore .gitignore rules
      {green('--allow-secrets')}       include .env, keys, etc. {dim('(off by default)')}
      {green('--force')}               allow packing ~ or / {dim('(refused by default)')}
      {green('--max-scan')} N / {green('--max-time')} SEC  safety stop for huge trees {dim('[20000 / 20s]')}

{bold('APPLY FLAGS')}
  {green('-n, --dry-run')}   preview diff only     {green('-y, --yes')}  don't ask
  {green('-C, --dir')} DIR   project folder [.]     {green('--no-backup')}

{bold('EXAMPLES')}
  {dim('$')} llmux .                       {dim('# pack current folder → llmux-<name>-<time>.xml')}
  {dim('$')} llmux src -f md -d 0          {dim('# markdown, all depths')}
  {dim('$')} llmux . -t 100k -i "*.py"     {dim('# python only, max 100k tokens')}
  {dim('$')} llmux . -c | clip             {dim('# straight to clipboard (Windows)')}
  {dim('$')} llmux apply reply.txt -n      {dim('# preview LLM edits')}
  {dim('$')} llmux apply reply.txt         {dim('# apply them (backup kept)')}
""")

def main(argv):
    argv = [a for a in argv if a != "--no-color"]
    if not argv:
        help_main(); return 0
    a0 = argv[0]
    if a0 in ("-h", "--help", "help"):
        help_main(); return 0
    if a0 in ("-V", "--version", "version"):
        print(f"llmux {VERSION}"); return 0
    if a0 == "apply":
        if len(argv) > 1 and argv[1] in ("-h", "--help"):
            help_main(); return 0
        return cmd_apply(argv[1:])
    if a0 == "undo":
        return cmd_undo(argv[1:])
    if a0 == "count":
        return cmd_count(argv[1:])
    if a0 == "pack":
        argv = argv[1:]
    return cmd_pack(argv)

if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        say(red("\n✗ stopped")); sys.exit(130)
