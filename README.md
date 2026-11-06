# llmux

Make any folder **LLM paste-ready** in one file — then **apply the LLM's edits back**.

Like repomix / gitingest / yek, but a single file you can drop anywhere, plus a reverse step.

```bash
python3 llmux.py .                 # → llmux-<folder>-<time>.xml
python3 llmux.py apply reply.txt   # put the LLM's changes into your files
```

No install, no dependencies (Python 3.8+). Optional: `pip install tiktoken` for exact token counts
(without it, a built-in estimate is used — within ~1–2% on real code).

## Pack

```
llmux <folder> [flags]
  -f xml|md|txt      format                         [xml]
  -o FILE            output file                    [llmux-<dir>-<time>.<fmt>]
  -d N               depth: 0 = unlimited, 1 = this folder only   [5]
  -s SIZE            skip files bigger than this    [50k]
  -m SIZE            stop when output reaches this  [1m]
  -t N               stop when output reaches N tokens  [off]
  -i / -x GLOBS      include / exclude, e.g. "src/**,*.py"
  -n                 dry run: show what would be packed
  -c                 print to stdout (pipe to clipboard)
  --split            write part1, part2… instead of stopping
```

The output starts with a summary, edit instructions for the LLM, and the directory tree.

### Skipped automatically

- binary files (null-byte check + extension list), images, archives
- `.git`, `node_modules`, `venv`, `dist`, `build`, caches…
- lock files, `*.min.js`, source maps
- `.gitignore` rules
- **secrets**: `.env`, `*.pem`, `*.key`, `id_rsa`… (`--allow-secrets` to include)
- older llmux outputs

### Safety stops (ran it in the wrong folder?)

- refuses `~`, `/`, drive roots and system folders unless `--force`
- walks breadth-first, so top-level files go in first
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

## Tested

On a real repo (flask + junk: node_modules, `.env`, 7-level-deep file, binary blob, 400 KB random text):

|                  | repomix 1.18 | llmux |
|------------------|--------------|-------|
| output           | 1.6 MB, 559k tokens | 964 KB, 226k tokens |
| 400 KB junk file | included     | skipped (-s) |
| `.env` secret    | skipped      | skipped |
| time             | ~0.3 s       | ~0.3 s |

## License

MIT
