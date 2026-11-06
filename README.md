# llmux

Make any folder **LLM paste-ready** in one file — then **apply the LLM's edits back**.

Like repomix / gitingest / yek, but a single file you can drop anywhere, plus a reverse step.

```bash
llmux .                 # → llmux-<folder>-<time>.xml
llmux apply reply.txt   # put the LLM's changes into your files
```

## Pick the one your system has

Each is one file, no install, no dependencies. Same flags, same output, same edit format —
a pack made by one can be applied by any other.

| file         | runs on                                   | how to run |
|--------------|-------------------------------------------|------------|
| `llmux.py`   | Python 3.8+ (anywhere)                    | `python3 llmux.py .` |
| `llmux.sh`   | bash 3.2+ (Linux, macOS, WSL, Git Bash)   | `bash llmux.sh .` |
| `llmux.ps1`  | Windows PowerShell 5.1 / PowerShell 7     | `powershell -ExecutionPolicy Bypass -File llmux.ps1 .` |
| `llmux.cmd`  | cmd.exe launcher                          | `llmux .` — uses Python if found, else PowerShell |

Put the folder on your `PATH` (or alias one file to `llmux`).

Tokens: `llmux.py` uses `tiktoken` if installed (`pip install tiktoken`, exact o200k counts).
Otherwise — and always in bash/PowerShell — a built-in estimate is used: **within ~1–2% of
tiktoken** on real code (checked on 1,500+ files).

## Pack

```
llmux <folder> [flags]
  -f xml|md|txt      format                         [xml]
  -o FILE            output file                    [llmux-<dir>-<time>.<fmt>]
  -d N               depth: 0 = unlimited, 1 = this folder only   [5]
  -s SIZE            skip files bigger than this    [50k]
  -m SIZE            stop when output reaches this  [1m]
  -t N               stop when output reaches N tokens  [off]
  -i / -x GLOBS      include / exclude, e.g. "src/*,*.py"
  -n                 dry run: show what would be packed
  -c                 print to stdout (pipe to clipboard)
  -a                 include dotfiles / dot-folders
  --split            write part1, part2… instead of stopping
```

The output starts with a summary, edit instructions for the LLM, and the directory tree.
Run `llmux` with no arguments for the full colored help.

### Skipped automatically

- binary files (null-byte check + extension list), images, archives
- `.git`, `node_modules`, `venv`, `dist`, `build`, caches…
- lock files, `*.min.js`, source maps
- `.gitignore` rules
- **secrets**: `.env`, `*.pem`, `*.key`, `id_rsa`… (`--allow-secrets` to include)
- older llmux outputs

### Safety stops (ran it in the wrong folder?)

- refuses `~`, `/`, `C:\` and system folders unless `--force`
- shallow files go in first (breadth-first)
- **stops scanning** as soon as the size/token limit is hit — no wasted work
- hard caps: 20 000 entries or 20 s of scanning (`--max-scan`, `--max-time`)
- tells you what was left out and how to change it

## Apply (reverse)

Paste the pack into Claude/ChatGPT. It is told to reply with edit blocks:

```
FILE: src/app.py
<<<<<<< SEARCH
def hello():
    print("hi")
=======
def hello(name):
    print(f"hi {name}")
>>>>>>> REPLACE
```

Also: `<<<<<<< FULL … >>>>>>> END` for new or rewritten files, and `DELETE: path`.

```bash
llmux apply reply.txt -n     # colored diff preview only
llmux apply reply.txt        # asks y/N, keeps a backup
llmux apply - -y             # paste from stdin
llmux undo                   # roll back the last apply
```

- No line numbers needed (LLMs get them wrong). Matches exactly, then ignoring trailing spaces, then ignoring indentation.
- Blocks that don't match are reported with the reply line number; the rest still apply.
- Paths outside the project are refused.
- Keeps CRLF/LF line endings.
- Also accepts a **whole edited pack** (llmux xml/md/txt, or a repomix xml) and writes back only the files that changed.

## Small differences between versions

- **bash**: uses `git ls-files` for ignore rules inside a git repo; outside git it reads only the
  top-level `.gitignore` (no `!` rules). Needs `diff` for the apply preview. Slower (~2 s for 200 files).
- **PowerShell**: the diff preview is llmux's own (no external tools).
- All versions write the same pack; bash may order files slightly differently.

## Tested

On a real repo (flask + junk: node_modules, `.env`, 7-level-deep file, binary blob, 400 KB random text):

|                  | repomix 1.18 | llmux |
|------------------|--------------|-------|
| output           | 1.6 MB, 559k tokens | 964 KB, 226k tokens |
| 400 KB junk file | included     | skipped (-s) |
| `.env` secret    | skipped      | skipped |
| time             | ~0.3 s       | ~0.3 s (py) |

Cross-checks: bash and PowerShell packs are byte-identical to the Python one (same files, same
per-file tokens); packs from each version — and repomix xml — round-trip through every other
version's `apply`.

## License

MIT
