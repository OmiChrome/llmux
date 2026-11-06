# llmux.ps1 - pack a directory into one LLM-ready file, and apply LLM edits back.
# PowerShell version of llmux.py: same flags, same output formats, same edit blocks.
# Works on Windows PowerShell 5.1 and PowerShell 7+ (Windows / macOS / Linux). No modules needed.
# Token counts are a fast estimate (~1-2% off tiktoken on real code).
#
# Run:  powershell -ExecutionPolicy Bypass -File llmux.ps1 .      (or: pwsh llmux.ps1 .)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
$VERSION = '0.1.0'

$DEF_DEPTH = 5; $DEF_FILE_MAX = 51200; $DEF_TOTAL_MAX = 1048576; $DEF_MAX_SCAN = 20000; $DEF_MAX_TIME = 20.0

$SKIP_DIRS = @('.git','.hg','.svn','node_modules','bower_components','vendor','__pycache__','.venv','venv','env','.env','.tox','.nox',
  '.mypy_cache','.pytest_cache','.ruff_cache','.cache','.gradle','.idea','.next','.nuxt','.svelte-kit','.turbo','.parcel-cache',
  'dist','build','out','target','coverage','.terraform','.llmux-backup','site-packages','.cargo','.rustup','.npm','.nvm',
  'Library','AppData','.local','.vscode-server','.DS_Store')
$SKIP_FILES = @('package-lock.json','yarn.lock','pnpm-lock.yaml','bun.lockb','Cargo.lock','poetry.lock','Pipfile.lock',
  'composer.lock','Gemfile.lock','go.sum','uv.lock','.DS_Store','Thumbs.db')
$SKIP_GLOBS = @('*.min.js','*.min.css','*.map','*.lock','llmux-*.xml','llmux-*.md','llmux-*.txt')
$SECRET_GLOBS = @('.env','.env.*','*.pem','*.key','*.p12','*.pfx','id_rsa*','id_ed25519*','id_ecdsa*','*.keystore',
  '.npmrc','.pypirc','.netrc','credentials*','*.kdbx')
$KEEP_DOTFILES = @('.gitignore','.editorconfig','.dockerignore','.gitattributes')
$BINARY_EXT = @('png','jpg','jpeg','gif','bmp','ico','webp','tiff','tif','psd','svgz','heic','avif','raw',
  'mp3','wav','flac','ogg','m4a','aac','mp4','mkv','mov','avi','webm','wmv','flv',
  'zip','tar','gz','tgz','bz2','xz','7z','rar','zst','jar','war','ear','whl','egg',
  'exe','dll','so','dylib','bin','o','a','lib','obj','class','pyc','pyo','pyd','wasm',
  'pdf','doc','docx','xls','xlsx','ppt','pptx','odt','ods','odp','epub',
  'ttf','otf','woff','woff2','eot','sqlite','sqlite3','db','mdb','dat','iso','img','dmg',
  'npy','npz','pkl','pickle','pt','pth','onnx','h5','safetensors','ckpt','parquet')

$UTF8 = New-Object System.Text.UTF8Encoding($false)
$UTF8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$NL = "`n"

# ------------------------------------------------------------------ args --
$argv = New-Object System.Collections.Generic.List[string]
foreach ($a in $args) { if ($a -is [array]) { $argv.Add(($a -join ',')) } else { $argv.Add([string]$a) } }

# ---------------------------------------------------------------- colors --
$script:COLOR = $true
if ($env:NO_COLOR -or $argv.Contains('--no-color')) { $script:COLOR = $false }
try { if ([Console]::IsErrorRedirected) { $script:COLOR = $false } } catch { }
$null = $argv.Remove('--no-color')
try { [Console]::OutputEncoding = $UTF8 } catch { }
$ESC = [char]27
function C($code, $s) { if ($script:COLOR) { "$ESC[$($code)m$s$ESC[0m" } else { "$s" } }
function Bold($s) { C 1 $s }; function Dim($s) { C 2 $s }; function Red($s) { C 31 $s }
function Green($s) { C 32 $s }; function Yellow($s) { C 33 $s }; function Cyan($s) { C 36 $s }

function Say([string]$s = '') { [Console]::Error.WriteLine($s) }
function Die([string]$msg, [string]$hint = '', [int]$code = 2) {
  Say ((Red '✗ ') + $msg)
  if ($hint) { Say ((Dim '  hint: ') + $hint) }
  exit $code
}

# --------------------------------------------------------------- helpers --
function Parse-Size([string]$s) {
  $m = [regex]::Match($s.ToLower(), '^\s*([\d.]+)\s*([kmg]?)i?b?\s*$')
  if (-not $m.Success) { Die "bad size '$s'" 'use e.g. 50k, 1m, 2mb, 4096' }
  $mult = @{ '' = 1; 'k' = 1024; 'm' = 1048576; 'g' = 1073741824 }[$m.Groups[2].Value]
  [long]([double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) * $mult)
}
function Parse-Count([string]$s) {
  $m = [regex]::Match($s.ToLower(), '^\s*([\d.]+)\s*([km]?)\s*$')
  if (-not $m.Success) { Die "bad number '$s'" 'use e.g. 128k, 200000, 1m' }
  $mult = @{ '' = 1; 'k' = 1000; 'm' = 1000000 }[$m.Groups[2].Value]
  [long]([double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) * $mult)
}
function Full-Path([string]$p) {   # absolute path from user input (handles ~, C:\, relative)
  if ($p -eq '~' -or $p.StartsWith('~/') -or $p.StartsWith('~\')) { $p = $HOME + $p.Substring(1) }
  if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-Location).ProviderPath $p }
  [IO.Path]::GetFullPath($p)
}
function Human([double]$n) {
  $u = 'B', 'KB', 'MB', 'GB'; $i = 0
  while ($n -ge 1024 -and $i -lt 3) { $n /= 1024; $i++ }
  if ($i -eq 0) { '{0:0} B' -f $n } else { [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0} {1}', $n, $u[$i]) }
}
function HTok([long]$n) {
  if ($n -ge 1000) { [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}k', $n / 1000.0) } else { "$n" }
}
$NON_ASCII = New-Object regex '[^\x00-\x7f]'
function Count-Tokens([string]$text) {
  $na = $NON_ASCII.Matches($text).Count
  [long][math]::Floor(($text.Length - $na) / 4.2 + $na * 0.8 + 0.5)
}

# ------------------------------------------------------------- gitignore --
function GlobToRegex([string]$pat) {
  $sb = New-Object System.Text.StringBuilder; $i = 0
  while ($i -lt $pat.Length) {
    $c = $pat[$i]
    if ($pat.Substring($i).StartsWith('**/')) { [void]$sb.Append('(?:.*/)?'); $i += 3; continue }
    if ($pat.Substring($i) -eq '/**') { [void]$sb.Append('/.*'); $i += 3; continue }
    if ($pat.Substring($i).StartsWith('**')) { [void]$sb.Append('.*'); $i += 2; continue }
    if ($c -eq '*') { [void]$sb.Append('[^/]*') }
    elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
    elseif ($c -eq '[') {
      $j = $pat.IndexOf(']', $i + 1)
      if ($j -lt 0) { [void]$sb.Append('\[') }
      else {
        $body = $pat.Substring($i + 1, $j - $i - 1).Replace('\', '\\')
        if ($body.StartsWith('!')) { $body = '^' + $body.Substring(1) }
        [void]$sb.Append("[$body]"); $i = $j
      }
    }
    else { [void]$sb.Append([regex]::Escape([string]$c)) }
    $i++
  }
  $sb.ToString()
}
function New-IgnoreRules([string]$base, [string[]]$lines) {
  $rules = New-Object System.Collections.Generic.List[object]
  foreach ($raw in $lines) {
    $line = $raw.TrimEnd()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $neg = $line.StartsWith('!'); if ($neg) { $line = $line.Substring(1) }
    $dirOnly = $line.EndsWith('/'); $line = $line.TrimEnd('/')
    if (-not $line) { continue }
    $anch = $line.Contains('/'); $line = $line.TrimStart('/')
    $rx = (& { if ($anch) { '^' } else { '^(?:.*/)?' } }) + (GlobToRegex $line) + '$'
    $rules.Add([pscustomobject]@{ Rx = (New-Object regex $rx); Neg = $neg; DirOnly = $dirOnly })
  }
  [pscustomobject]@{ Base = $base; Rules = $rules }
}
function RelPath([string]$from, [string]$to) {
  $f = $from.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if ($to.StartsWith($f, [StringComparison]::OrdinalIgnoreCase)) { return $to.Substring($f.Length).Replace('\', '/') }
  $to.Replace('\', '/')
}
function Is-Ignored($stack, [string]$abs, [bool]$isDir) {
  $result = $null
  foreach ($r in $stack) {
    $rel = RelPath $r.Base $abs
    foreach ($rule in $r.Rules) {
      if ($rule.DirOnly -and -not $isDir) { continue }
      if ($rule.Rx.IsMatch($rel)) { $result = -not $rule.Neg }
    }
  }
  [bool]$result
}
function Match-Any($globs, [string]$rel) {
  $name = $rel.Substring($rel.LastIndexOf('/') + 1)
  foreach ($g in $globs) {
    if ($rel -like $g -or $name -like $g) { return $true }
    if ($g.EndsWith('/') -and ($rel + '/').StartsWith($g)) { return $true }
  }
  $false
}

# ------------------------------------------------------------------ scan --
$PACK_MARK = New-Object regex '^<llmux version=|generated: .* by llmux \d', 'Multiline'

function Looks-Binary([string]$path) {
  try {
    $fs = [IO.File]::OpenRead($path)
    try { $buf = New-Object byte[] 8192; $n = $fs.Read($buf, 0, 8192) } finally { $fs.Close() }
  } catch { return $true }
  if ($n -eq 0) { return $false }
  $ctrl = 0
  for ($i = 0; $i -lt $n; $i++) {
    $b = $buf[$i]
    if ($b -eq 0) { return $true }
    if ($b -lt 9 -or ($b -gt 13 -and $b -lt 32)) { $ctrl++ }
  }
  ($ctrl / $n) -gt 0.10
}
function Danger-Root([string]$root) {
  $home_ = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile')).TrimEnd('\', '/')
  if (-not $home_) { $home_ = $HOME }
  $r = $root.TrimEnd('\', '/')
  if ($r -eq $home_) { return 'your home folder' }
  if ([IO.Path]::GetPathRoot($root).TrimEnd('\', '/') -eq $r) { return 'a filesystem root' }
  $sys = @('/usr', '/etc', '/var', '/opt', '/Users', '/home', 'C:\Windows', 'C:\Users', 'C:\Program Files', 'C:\Program Files (x86)')
  foreach ($s in $sys) { if ($r -eq $s) { return 'a system folder' } }
  $null
}

function Do-Scan($root, $o) {
  $s = [pscustomobject]@{ Files = (New-Object System.Collections.Generic.List[object]); Skipped = @{}; Big = (New-Object System.Collections.Generic.List[object])
    Secrets = (New-Object System.Collections.Generic.List[string]); Bytes = 0L; Tokens = 0L; Visited = 0; Stop = $null; DepthHit = $false }
  $skip = { param($why) if ($s.Skipped.ContainsKey($why)) { $s.Skipped[$why]++ } else { $s.Skipped[$why] = 1 } }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $mult = 1; if ($o.Split) { $mult = $o.MaxParts }
  $capB = $o.TotalMax * $mult; $capT = $o.MaxTokens * $mult
  $q = New-Object System.Collections.Queue
  $q.Enqueue(@($root, 1, @()))
  while ($q.Count -gt 0) {
    $item = $q.Dequeue(); $d = $item[0]; $depth = $item[1]; $stack = $item[2]
    if (-not $o.NoGitignore) {
      $gi = Join-Path $d '.gitignore'
      if ([IO.File]::Exists($gi)) {
        try { $stack = @($stack) + @(New-IgnoreRules $d ([IO.File]::ReadAllLines($gi, $UTF8))) } catch { }
      }
    }
    try {
      $entries = @((New-Object IO.DirectoryInfo $d).GetFileSystemInfos() |
        Sort-Object @{ e = { $_ -is [IO.DirectoryInfo] } }, @{ e = { $_.Name.ToLowerInvariant() } })
    } catch { & $skip 'unreadable dir'; continue }
    foreach ($e in $entries) {
      $s.Visited++
      if ($s.Visited -gt $o.MaxScan) { $s.Stop = "looked at $($o.MaxScan) entries (--max-scan)"; return $s }
      if ($sw.Elapsed.TotalSeconds -gt $o.MaxTime) { $s.Stop = "scanning took over $([int]$o.MaxTime)s (--max-time)"; return $s }
      $rel = RelPath $root $e.FullName
      if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { & $skip 'symlink'; continue }
      $name = $e.Name
      if ($e -is [IO.DirectoryInfo]) {
        if (($SKIP_DIRS -ccontains $name) -and -not (Match-Any $o.Include ($rel + '/'))) { & $skip 'junk dir'; continue }
        if (-not $o.Hidden -and $name.StartsWith('.') -and $name -ne '.github') { & $skip 'hidden'; continue }
        if ((Match-Any $o.Exclude $rel) -or (Match-Any $o.Exclude ($rel + '/'))) { & $skip 'excluded'; continue }
        if ($stack.Count -and (Is-Ignored $stack $e.FullName $true)) { & $skip 'gitignore'; continue }
        if ($o.Depth -eq 0 -or $depth -lt $o.Depth) { $q.Enqueue(@($e.FullName, ($depth + 1), $stack)) }
        else { $s.DepthHit = $true; & $skip 'too deep' }
        continue
      }
      if ($e.FullName -eq $o.OutAbs) { continue }
      if ($o.Include.Count -and -not (Match-Any $o.Include $rel)) { & $skip 'not included'; continue }
      if (Match-Any $o.Exclude $rel) { & $skip 'excluded'; continue }
      if (-not $o.AllowSecrets -and (Match-Any $SECRET_GLOBS $rel)) { $s.Secrets.Add($rel); & $skip 'secret'; continue }
      if (($SKIP_FILES -ccontains $name) -or (Match-Any $SKIP_GLOBS $rel)) { & $skip 'lock/min/generated'; continue }
      if (-not $o.Hidden -and $name.StartsWith('.') -and -not ($KEEP_DOTFILES -contains $name)) { & $skip 'hidden'; continue }
      if ($stack.Count -and (Is-Ignored $stack $e.FullName $false)) { & $skip 'gitignore'; continue }
      $ext = ''; if ($name.Contains('.')) { $ext = $name.Substring($name.LastIndexOf('.') + 1).ToLowerInvariant() }
      if ($BINARY_EXT -contains $ext) { & $skip 'binary'; continue }
      $size = $e.Length
      if ($size -gt $o.FileMax) { & $skip 'too big (-s)'; $s.Big.Add(@($rel, $size)); continue }
      if ($size -eq 0) { & $skip 'empty'; continue }
      if (Looks-Binary $e.FullName) { & $skip 'binary'; continue }
      try { $text = $UTF8Strict.GetString([IO.File]::ReadAllBytes($e.FullName)) }
      catch [System.Text.DecoderFallbackException] { & $skip 'not utf-8'; continue }
      catch { & $skip 'unreadable'; continue }
      $text = $text.TrimStart([char]0xFEFF).Replace("`r`n", "`n")
      if ($PACK_MARK.IsMatch($text.Substring(0, [math]::Min(600, $text.Length)))) { & $skip 'old llmux output'; continue }
      $nb = $UTF8.GetByteCount($text); $tk = Count-Tokens $text
      if ($s.Bytes + $nb -gt $capB -or ($capT -and $s.Tokens + $tk -gt $capT)) {
        if ($capT -and $s.Tokens + $tk -gt $capT) { $s.Stop = 'output token limit reached' } else { $s.Stop = 'output size limit reached' }
        & $skip 'over total limit'
        return $s
      }
      $s.Files.Add([pscustomobject]@{ Rel = $rel; Size = $nb; Text = $text; Tokens = $tk })
      $s.Bytes += $nb; $s.Tokens += $tk
    }
  }
  $s
}

# ---------------------------------------------------------------- render --
function Build-Tree($paths) {
  $tree = @{}
  foreach ($p in $paths) {
    $node = $tree
    foreach ($part in $p.Split('/')) { if (-not $node.ContainsKey($part)) { $node[$part] = @{} }; $node = $node[$part] }
  }
  $lines = New-Object System.Collections.Generic.List[string]
  $walk = $null
  $walk = {
    param($node, $prefix)
    $items = @($node.GetEnumerator() | Sort-Object @{ e = { $_.Value.Count -eq 0 } }, @{ e = { $_.Key.ToLowerInvariant() } })
    for ($i = 0; $i -lt $items.Count; $i++) {
      $last = ($i -eq $items.Count - 1); $kv = $items[$i]; $isDir = $kv.Value.Count -gt 0
      $lines.Add($prefix + $(if ($last) { '└── ' } else { '├── ' }) + $kv.Key + $(if ($isDir) { '/' } else { '' }))
      if ($isDir) { & $walk $kv.Value ($prefix + $(if ($last) { '    ' } else { '│   ' })) }
    }
  }
  & $walk $tree ''
  $lines -join $NL
}

$EDIT_GUIDE = @'
When you change code, reply ONLY with edit blocks in this exact format
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
- Do not use line numbers or unified diffs.
'@.Replace("`r`n", "`n").TrimEnd("`n")

function Fence-For([string]$text) {
  $longest = 2
  foreach ($m in [regex]::Matches($text, '`{3,}')) { if ($m.Length -gt $longest) { $longest = $m.Length } }
  '`' * [math]::Max(3, $longest + 1)
}

function Render($fmt, $rootName, $files, $s, $o, $part, $parts) {
  $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $tree = Build-Tree ($files | ForEach-Object { $_.Rel })
  $nb = 0L; $nt = 0L; foreach ($f in $files) { $nb += $f.Size; $nt += $f.Tokens }
  $info = New-Object System.Collections.Generic.List[string]
  $info.Add("project: $rootName"); $info.Add("generated: $now by llmux $VERSION"); $info.Add("files: $($files.Count)")
  $info.Add("size: $(Human $nb)"); $info.Add("tokens: $nt (estimate)")
  if ($part) { $info.Add("part: $part of $parts") }
  if ($s.Stop) { $info.Add("NOTE: incomplete - $($s.Stop)") }
  $out = New-Object System.Collections.Generic.List[string]
  if ($fmt -eq 'xml') {
    $out.Add("<llmux version=`"$VERSION`" project=`"$rootName`">")
    if (-not $o.NoHeader) {
      $out.Add("<summary>`n" + ($info -join $NL) + "`n</summary>")
      if (-not $o.NoInstructions) { $out.Add("<instructions>`n$EDIT_GUIDE`n</instructions>") }
      if (-not $o.NoTree) { $out.Add("<directory_structure>`n$tree`n</directory_structure>") }
    }
    $out.Add('<files>')
    foreach ($f in $files) { $out.Add("<file path=`"$($f.Rel)`" tokens=`"$($f.Tokens)`">`n$($f.Text.TrimEnd("`n"))`n</file>") }
    $out.Add("</files>`n</llmux>")
  } elseif ($fmt -eq 'md') {
    $out.Add("# $rootName`n")
    if (-not $o.NoHeader) {
      $out.Add("## Summary`n`n" + (($info | ForEach-Object { "- $_" }) -join $NL) + "`n")
      if (-not $o.NoInstructions) { $out.Add("## How to reply with edits`n`n``````text`n$EDIT_GUIDE`n```````n") }
      if (-not $o.NoTree) { $out.Add("## Directory structure`n`n``````text`n$tree`n```````n") }
    }
    $out.Add("## Files`n")
    foreach ($f in $files) {
      $leaf = $f.Rel.Substring($f.Rel.LastIndexOf('/') + 1); $ext = ''
      if ($leaf.Contains('.')) { $ext = $f.Rel.Substring($f.Rel.LastIndexOf('.') + 1) }
      $fe = Fence-For $f.Text
      $out.Add("### File: $($f.Rel)`n`n$fe$ext`n$($f.Text.TrimEnd("`n"))`n$fe`n")
    }
  } else {
    $bar = '=' * 64
    $out.Add("$bar`n$rootName`n$bar")
    if (-not $o.NoHeader) {
      $out.Add("SUMMARY`n" + ($info -join $NL) + "`n")
      if (-not $o.NoInstructions) { $out.Add("HOW TO REPLY WITH EDITS`n$EDIT_GUIDE`n") }
      if (-not $o.NoTree) { $out.Add("DIRECTORY STRUCTURE`n$tree`n") }
    }
    foreach ($f in $files) { $out.Add("===== FILE: $($f.Rel) =====`n$($f.Text.TrimEnd("`n"))`n===== END FILE =====`n") }
  }
  ($out -join $NL) + $NL
}

# ------------------------------------------------------------------ pack --
function Cmd-Pack($a) {
  $o = [pscustomobject]@{ Fmt = 'xml'; Out = $null; Depth = $DEF_DEPTH; FileMax = $DEF_FILE_MAX; TotalMax = $DEF_TOTAL_MAX; MaxTokens = 0L
    Include = (New-Object System.Collections.Generic.List[string]); Exclude = (New-Object System.Collections.Generic.List[string])
    NoTree = $false; NoHeader = $false; NoInstructions = $false; NoGitignore = $false; Hidden = $false; Force = $false; Dry = $false
    Stdout = $false; Split = $false; AllowSecrets = $false; MaxParts = 10; MaxScan = $DEF_MAX_SCAN; MaxTime = $DEF_MAX_TIME; OutAbs = '' }
  $target = $null
  $i = 0
  $val = { param($flag) if ($script:ai + 1 -ge $a.Count) { Die "$flag needs a value" 'see: llmux --help' }; $script:ai++; $a[$script:ai] }
  $script:ai = 0
  while ($script:ai -lt $a.Count) {
    $x = $a[$script:ai]
    switch -CaseSensitive ($x) {
      { $_ -in '-f', '--format' } {
        $f = (& $val $x).ToLower()
        if ($f -eq 'markdown') { $f = 'md' } elseif ($f -in 'text', 'plain') { $f = 'txt' }
        if ($f -notin 'xml', 'md', 'txt') { Die "unknown format '$f'" 'use xml, md or txt' }
        $o.Fmt = $f; break }
      { $_ -in '-o', '--output' } { $o.Out = & $val $x; break }
      { $_ -in '-d', '--depth' } {
        $v = & $val $x
        if ($v -notmatch '^\d+$') { Die "bad depth '$v'" '0 = unlimited, 1 = this folder only, 5 = default' }
        $o.Depth = [int]$v; break }
      { $_ -in '-s', '--max-file-size' } { $o.FileMax = Parse-Size (& $val $x); break }
      { $_ -in '-m', '--max-size' } { $o.TotalMax = Parse-Size (& $val $x); break }
      { $_ -in '-t', '--max-tokens' } { $o.MaxTokens = Parse-Count (& $val $x); break }
      { $_ -in '-i', '--include' } { foreach ($g in (& $val $x).Split(',')) { if ($g.Trim()) { $o.Include.Add($g.Trim()) } }; break }
      { $_ -in '-x', '--exclude' } { foreach ($g in (& $val $x).Split(',')) { if ($g.Trim()) { $o.Exclude.Add($g.Trim()) } }; break }
      '--no-tree' { $o.NoTree = $true; break }
      '--no-header' { $o.NoHeader = $true; break }
      '--no-instructions' { $o.NoInstructions = $true; break }
      '--no-gitignore' { $o.NoGitignore = $true; break }
      { $_ -in '-a', '--hidden' } { $o.Hidden = $true; break }
      '--allow-secrets' { $o.AllowSecrets = $true; break }
      '--force' { $o.Force = $true; break }
      { $_ -in '-n', '--dry-run' } { $o.Dry = $true; break }
      { $_ -in '-c', '--stdout' } { $o.Stdout = $true; break }
      '--split' { $o.Split = $true; break }
      '--max-parts' { $o.MaxParts = Parse-Count (& $val $x); break }
      '--max-scan' { $o.MaxScan = Parse-Count (& $val $x); break }
      '--max-time' { $o.MaxTime = [double](& $val $x); break }
      default {
        if ($x.StartsWith('-') -and $x -ne '-') { Die "unknown flag '$x'" 'see: llmux --help' }
        if ($null -ne $target) { Die "only one folder at a time (got '$target' and '$x')" }
        $target = $x
      }
    }
    $script:ai++
  }
  if (-not $target) { $target = '.' }
  $full = Full-Path $target
  if (-not [IO.Directory]::Exists($full)) { Die "'$target' is not a folder" }
  $root = $full.TrimEnd('\', '/'); if (-not $root) { $root = $full }
  if ($root.EndsWith(':')) { $root += '\' }
  $rootName = Split-Path $root -Leaf; if (-not $rootName) { $rootName = $root }
  $danger = Danger-Root $root
  if ($danger -and -not $o.Force) {
    Die "'$root' is $danger. Packing it is almost always a mistake." 'cd into a project folder, or add --force if you really mean it'
  }
  if (-not $o.Out) {
    $safe = [regex]::Replace($rootName, '[^\w.-]+', '_')
    $o.Out = "llmux-$safe-$((Get-Date).ToString('yyyyMMdd-HHmmss')).$($o.Fmt)"
  }
  $o.OutAbs = Full-Path $o.Out

  Say ((Cyan '◆ llmux') + (Dim " $VERSION (powershell)") + '  packing ' + (Bold $root))
  $dt = "$($o.Depth)"; if ($o.Depth -eq 0) { $dt = 'unlimited' } elseif ($o.Depth -eq 1) { $dt = 'this folder only' }
  $lim = "depth $dt · file ≤ $(Human $o.FileMax) · total ≤ $(Human $o.TotalMax)"
  if ($o.MaxTokens) { $lim += " · ≤ $(HTok $o.MaxTokens) tokens" }
  Say (Dim "  $lim")

  $s = Do-Scan $root $o
  $files = $s.Files.ToArray()   # (not @(): PS 5.1 throws on @() of a List inside an object)
  $partsList = New-Object System.Collections.Generic.List[object]
  if ($o.Split) {
    $cur = New-Object System.Collections.Generic.List[object]; $cb = 0L; $ct = 0L
    foreach ($f in $files) {
      if ($cur.Count -and ($cb + $f.Size -gt $o.TotalMax -or ($o.MaxTokens -and $ct + $f.Tokens -gt $o.MaxTokens))) {
        $partsList.Add($cur.ToArray()); $cur = New-Object System.Collections.Generic.List[object]; $cb = 0L; $ct = 0L
      }
      $cur.Add($f); $cb += $f.Size; $ct += $f.Tokens
    }
    if ($cur.Count) { $partsList.Add($cur.ToArray()) }
  } else { $partsList.Add($files) }

  Print-Report $s
  if (-not $files.Count) { Die 'nothing to pack' 'check the folder, or loosen -s / -d / -i / -x' 1 }
  if ($o.Dry) { Say (Yellow '  dry run - nothing written'); return 0 }

  $n = $partsList.Count
  for ($k = 0; $k -lt $n; $k++) {
    $p = $null; $pn = $null; if ($n -gt 1) { $p = $k + 1; $pn = $n }
    $text = Render $o.Fmt $rootName $partsList[$k] $s $o $p $pn
    if ($o.Stdout) { [Console]::Out.Write($text); continue }
    $path = $o.OutAbs
    if ($pn) { $path = [IO.Path]::ChangeExtension($o.OutAbs, $null).TrimEnd('.') + ".part$p." + $o.Fmt }
    [IO.File]::WriteAllText($path, $text, $UTF8)
    $shown = $o.Out; if ($pn) { $shown = [IO.Path]::ChangeExtension($o.Out, $null).TrimEnd('.') + ".part$p." + $o.Fmt }
    Say ((Green '✓ wrote ') + (Bold $shown) + (Dim "  ($(Human $UTF8.GetByteCount($text)))"))
  }
  if (-not $o.Stdout) { Say ((Dim '  next: paste it into your LLM. Save its reply, then: ') + (Cyan 'llmux apply reply.txt')) }
  0
}

function Print-Report($s) {
  Say ''
  Say ("  $(Bold 'files')   $(Green $s.Files.Count)")
  Say ("  $(Bold 'size')    $(Human $s.Bytes)")
  Say ("  $(Bold 'tokens')  $(HTok $s.Tokens) $(Dim '(estimate)')")
  if ($s.Files.Count) {
    Say (Dim '  biggest:')
    foreach ($f in @($s.Files | Sort-Object Tokens -Descending | Select-Object -First 5)) {
      $pct = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0,4:0.0}%', 100.0 * $f.Tokens / [math]::Max(1, $s.Tokens))
      Say ("    {0,7} {1}  {2}" -f (HTok $f.Tokens), (Dim $pct), $f.Rel)
    }
  }
  if ($s.Skipped.Count) {
    $parts = $s.Skipped.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) $($_.Value)" }
    Say (Dim ('  skipped: ' + ($parts -join ', ')))
  }
  if ($s.Big.Count) {
    $names = ($s.Big | Sort-Object { - $_[1] } | Select-Object -First 4 | ForEach-Object { "$($_[0]) ($(Human $_[1]))" }) -join ', '
    Say ((Yellow '  ! too big, left out: ') + $names + (Dim '  → raise with -s 200k'))
  }
  if ($s.Secrets.Count) { Say ((Yellow '  ! secrets left out: ') + (($s.Secrets | Select-Object -First 5) -join ', ') + (Dim '  (--allow-secrets to include)')) }
  if ($s.DepthHit) { Say (Dim '  some folders were deeper than -d; use -d 0 for unlimited') }
  if ($s.Stop) {
    Say ((Yellow '  ! stopped early: ') + $s.Stop)
    Say (Dim "    output is partial. Narrow it with -i 'src/**' or -x 'docs/', or raise -m / -t / --split")
  }
  Say ''
}

# ----------------------------------------------------------------- apply --
$FILE_RE = New-Object regex '^[\s>*#`_-]*(FILE|DELETE)\s*:\s*[`*_"'']*(.+?)[`*_"'']*\s*$'
$S_START = New-Object regex '^\s*<{5,9}\s*SEARCH\s*$'
$S_MID = New-Object regex '^\s*={5,9}\s*$'
$S_END = New-Object regex '^\s*>{5,9}\s*REPLACE\s*$'
$F_START = New-Object regex '^\s*<{5,9}\s*FULL\s*$'
$F_END = New-Object regex '^\s*>{5,9}\s*END\s*$'

function Parse-Edits([string]$text) {
  $lines = $text.Replace("`r`n", "`n").Split("`n")
  $ops = New-Object System.Collections.Generic.List[object]; $path = $null; $i = 0
  while ($i -lt $lines.Length) {
    $ln = $lines[$i]
    $m = $FILE_RE.Match($ln)
    if ($m.Success) {
      $p = $m.Groups[2].Value.Trim()
      if ($m.Groups[1].Value.ToUpper() -eq 'DELETE') { $ops.Add([pscustomobject]@{ Kind = 'delete'; Path = $p; Line = $i + 1 }) }
      else { $path = $p }
      $i++; continue
    }
    if ($S_START.IsMatch($ln)) {
      $start = $i + 1; $j = $i + 1; $search = New-Object System.Collections.Generic.List[string]
      while ($j -lt $lines.Length -and -not $S_MID.IsMatch($lines[$j])) { $search.Add($lines[$j]); $j++ }
      $k = $j + 1; $repl = New-Object System.Collections.Generic.List[string]
      while ($k -lt $lines.Length -and -not $S_END.IsMatch($lines[$k])) { $repl.Add($lines[$k]); $k++ }
      if ($j -ge $lines.Length -or $k -ge $lines.Length) { $ops.Add([pscustomobject]@{ Kind = 'broken'; Path = $path; Line = $start }); break }
      $ops.Add([pscustomobject]@{ Kind = 'edit'; Path = $path; Search = ($search -join $NL); Replace = ($repl -join $NL); Line = $start })
      $i = $k + 1; continue
    }
    if ($F_START.IsMatch($ln)) {
      $start = $i + 1; $j = $i + 1; $body = New-Object System.Collections.Generic.List[string]
      while ($j -lt $lines.Length -and -not $F_END.IsMatch($lines[$j])) { $body.Add($lines[$j]); $j++ }
      if ($j -ge $lines.Length) { $ops.Add([pscustomobject]@{ Kind = 'broken'; Path = $path; Line = $start }); break }
      $ops.Add([pscustomobject]@{ Kind = 'full'; Path = $path; Body = ($body -join $NL); Line = $start })
      $i = $j + 1; continue
    }
    $i++
  }
  , $ops
}

function Parse-Pack([string]$text) {
  $text = $text.Replace("`r`n", "`n")
  $ops = New-Object System.Collections.Generic.List[object]
  foreach ($m in [regex]::Matches($text, '<file path="([^"]+)"[^>]*>\n(.*?)\n</file>', 'Singleline')) {
    $ops.Add([pscustomobject]@{ Kind = 'full'; Path = $m.Groups[1].Value; Body = $m.Groups[2].Value; Line = 0 }) }
  if ($ops.Count) { return , $ops }
  foreach ($m in [regex]::Matches($text, '(?sm)^===== FILE: (.+?) =====\n(.*?)\n===== END FILE =====$')) {
    $ops.Add([pscustomobject]@{ Kind = 'full'; Path = $m.Groups[1].Value; Body = $m.Groups[2].Value; Line = 0 }) }
  if ($ops.Count) { return , $ops }
  foreach ($m in [regex]::Matches($text, '(?sm)^### File: (.+?)\n\n(`{3,})[^\n]*\n(.*?)\n\2[ \t]*$')) {
    $ops.Add([pscustomobject]@{ Kind = 'full'; Path = $m.Groups[1].Value; Body = $m.Groups[3].Value; Line = 0 }) }
  , $ops
}

function Count-Occ([string]$hay, [string]$needle) {
  $n = 0; $i = 0
  while (($i = $hay.IndexOf($needle, $i, [StringComparison]::Ordinal)) -ge 0) { $n++; $i += [math]::Max(1, $needle.Length) }
  $n
}
function Find-Block([string]$content, [string]$search) {
  $n = Count-Occ $content $search
  if ($n -eq 1) { $i = $content.IndexOf($search, [StringComparison]::Ordinal); return @($i, ($i + $search.Length), 'exact') }
  if ($n -gt 1) { return "SEARCH matches $n places - add more context lines" }
  $cl = $content.Split("`n"); $sl = New-Object System.Collections.Generic.List[string]; $sl.AddRange([string[]]$search.Split("`n"))
  while ($sl.Count -and -not $sl[0].Trim()) { $sl.RemoveAt(0) }
  while ($sl.Count -and -not $sl[$sl.Count - 1].Trim()) { $sl.RemoveAt($sl.Count - 1) }
  if (-not $sl.Count) { return 'SEARCH is only blank lines' }
  foreach ($how in 'trailing spaces', 'indentation') {
    $norm = if ($how -eq 'indentation') { { param($x) $x.Trim() } } else { { param($x) $x.TrimEnd() } }
    $target = @($sl | ForEach-Object { & $norm $_ })
    $hits = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -le $cl.Length - $sl.Count; $i++) {
      $ok = $true
      for ($j = 0; $j -lt $sl.Count; $j++) { if ((& $norm $cl[$i + $j]) -cne $target[$j]) { $ok = $false; break } }
      if ($ok) { $hits.Add($i) }
    }
    if ($hits.Count -eq 1) {
      $i = $hits[0]; $start = 0
      for ($q = 0; $q -lt $i; $q++) { $start += $cl[$q].Length + 1 }
      $end = $start + ($cl[$i..($i + $sl.Count - 1)] -join $NL).Length
      return @($start, $end, $how)
    }
    if ($hits.Count -gt 1) { return "SEARCH matches $($hits.Count) places (ignoring $how) - add more context" }
  }
  'SEARCH text not found in file'
}
function Lead([string]$s) {
  foreach ($ln in $s.Split("`n")) { if ($ln.Trim()) { return $ln.Substring(0, $ln.Length - $ln.TrimStart().Length) } }
  ''
}
function Reindent([string]$repl, [string]$found, [string]$search) {
  $have = Lead $search; $want = Lead $found
  if ($have -ceq $want) { return $repl }
  $out = foreach ($ln in $repl.Split("`n")) {
    if ($have -and $ln.StartsWith($have)) { $want + $ln.Substring($have.Length) }
    elseif ($ln.Trim()) { $want + $ln.TrimStart() }
    else { $ln }
  }
  $out -join $NL
}
function Safe-Path([string]$root, [string]$rel) {
  $rel = $rel.Trim().Trim('`').Replace('\', '/')
  if ($rel.StartsWith('./')) { $rel = $rel.Substring(2) }
  if (-not $rel -or $rel.StartsWith('/') -or $rel -match '^[A-Za-z]:') { return $null }
  $full = [IO.Path]::GetFullPath((Join-Path $root $rel))
  $r = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if (-not $full.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $null }
  $full
}
function Read-Text([string]$path) {
  $raw = $UTF8Strict.GetString([IO.File]::ReadAllBytes($path))
  @($raw.TrimStart([char]0xFEFF).Replace("`r`n", "`n"), $raw.Contains("`r`n"))
}

function Show-Diff([string]$rel, [string]$old, [string]$new) {
  $a = $old.TrimEnd("`n").Split("`n"); $b = $new.TrimEnd("`n").Split("`n")
  $p = 0; while ($p -lt $a.Length -and $p -lt $b.Length -and $a[$p] -ceq $b[$p]) { $p++ }
  $sa = $a.Length; $sb = $b.Length
  while ($sa -gt $p -and $sb -gt $p -and $a[$sa - 1] -ceq $b[$sb - 1]) { $sa--; $sb-- }
  $ops = New-Object System.Collections.Generic.List[object]   # @(tag, text)
  for ($i = 0; $i -lt $p; $i++) { $ops.Add(@(' ', $a[$i])) }
  $n = $sa - $p; $m = $sb - $p
  if ($n * $m -le 250000 -and $n -gt 0 -and $m -gt 0) {
    $L = New-Object 'int[,]' ($n + 1), ($m + 1)
    for ($i = $n - 1; $i -ge 0; $i--) { for ($j = $m - 1; $j -ge 0; $j--) {
      if ($a[$p + $i] -ceq $b[$p + $j]) { $L[$i, $j] = $L[($i + 1), ($j + 1)] + 1 }
      else { $down = $L[($i + 1), $j]; $right = $L[$i, ($j + 1)]; if ($down -ge $right) { $L[$i, $j] = $down } else { $L[$i, $j] = $right } } } }
    $i = 0; $j = 0
    while ($i -lt $n -and $j -lt $m) {
      if ($a[$p + $i] -ceq $b[$p + $j]) { $ops.Add(@(' ', $a[$p + $i])); $i++; $j++ }
      elseif ($L[($i + 1), $j] -ge $L[$i, ($j + 1)]) { $ops.Add(@('-', $a[$p + $i])); $i++ }
      else { $ops.Add(@('+', $b[$p + $j])); $j++ }
    }
    while ($i -lt $n) { $ops.Add(@('-', $a[$p + $i])); $i++ }
    while ($j -lt $m) { $ops.Add(@('+', $b[$p + $j])); $j++ }
  } else {
    for ($i = $p; $i -lt $sa; $i++) { $ops.Add(@('-', $a[$i])) }
    for ($j = $p; $j -lt $sb; $j++) { $ops.Add(@('+', $b[$j])) }
  }
  for ($i = $sa; $i -lt $a.Length; $i++) { $ops.Add(@(' ', $a[$i])) }
  $show = New-Object bool[] $ops.Count
  for ($i = 0; $i -lt $ops.Count; $i++) {
    if ($ops[$i][0] -ne ' ') { for ($k = [math]::Max(0, $i - 2); $k -le [math]::Min($ops.Count - 1, $i + 2); $k++) { $show[$k] = $true } }
  }
  Say (Bold "--- a/$rel"); Say (Bold "+++ b/$rel")
  $ol = 1; $nl = 1; $prev = $false; $count = 0
  for ($i = 0; $i -lt $ops.Count; $i++) {
    $t = $ops[$i][0]; $line = $ops[$i][1]
    if ($show[$i]) {
      if (-not $prev) { Say (Cyan "@@ -$ol +$nl @@") }
      $count++
      if ($count -gt 120) { Say (Dim '    … more diff lines'); return }
      if ($t -eq '+') { Say (Green "+$line") } elseif ($t -eq '-') { Say (Red "-$line") } else { Say (Dim " $line") }
    }
    $prev = $show[$i]
    if ($t -ne '+') { $ol++ }; if ($t -ne '-') { $nl++ }
  }
}

function Cmd-Apply($a) {
  $src = $null; $root = '.'; $dry = $false; $yes = $false; $nobak = $false
  for ($i = 0; $i -lt $a.Count; $i++) {
    $x = $a[$i]
    if ($x -in '-n', '--dry-run') { $dry = $true }
    elseif ($x -in '-y', '--yes') { $yes = $true }
    elseif ($x -in '-C', '--dir') { $i++; if ($i -ge $a.Count) { Die '--dir needs a folder' }; $root = $a[$i] }
    elseif ($x -eq '--no-backup') { $nobak = $true }
    elseif ($x.StartsWith('-') -and $x -ne '-') { Die "unknown flag '$x'" 'see: llmux --help' }
    else { $src = $x }
  }
  if (-not $src) { Die 'which file has the LLM reply?' "llmux apply reply.txt   (or '-' to read from paste/stdin)" }
  if ($src -eq '-') {
    if (-not [Console]::IsInputRedirected) { Say (Dim 'paste the reply, then Ctrl-Z Enter:') }
    $text = [Console]::In.ReadToEnd()
  } else {
    $sp = Full-Path $src
    if (-not [IO.File]::Exists($sp)) { Die "'$src' not found" }
    $text = [IO.File]::ReadAllText($sp, $UTF8)
  }
  $root = (Full-Path $root).TrimEnd('\', '/')
  if (-not [IO.Directory]::Exists($root)) { Die "'$root' is not a folder" }
  $text = $text.TrimStart([char]0xFEFF)
  $ops = $null; $mode = 'edit blocks'
  if ($PACK_MARK.IsMatch($text.Substring(0, [math]::Min(600, $text.Length)))) { $ops = Parse-Pack $text; $mode = 'files from pack' }
  if (-not $ops -or -not $ops.Count) { $ops = Parse-Edits $text; $mode = 'edit blocks' }
  if (-not $ops.Count) { $ops = Parse-Pack $text; $mode = 'files from pack' }
  if (-not $ops.Count) {
    Die 'no edits found in that file' 'the reply needs FILE: + <<<<<<< SEARCH / ======= / >>>>>>> REPLACE blocks, or be a full llmux pack'
  }
  Say ((Cyan '◆ llmux apply') + (Dim "  $($ops.Count) $mode → ") + (Bold $root))

  $newc = [ordered]@{}; $oldc = @{}; $crlf = @{}; $errors = New-Object System.Collections.Generic.List[object]
  foreach ($op in $ops) {
    $rel = $op.Path; $line = $op.Line
    if ($op.Kind -eq 'broken') { $errors.Add(@($(if ($rel) { $rel } else { '?' }), $line, 'block is not closed (missing ======= or >>>>>>> line)')); continue }
    if (-not $rel) { $errors.Add(@('?', $line, 'block has no FILE: line above it')); continue }
    $full = Safe-Path $root $rel
    if (-not $full) { $errors.Add(@($rel, $line, 'path is outside the project - refused')); continue }
    if (-not $newc.Contains($full)) {
      if ([IO.File]::Exists($full)) {
        try { $rt = Read-Text $full; $oldc[$full] = $rt[0]; $crlf[$full] = $rt[1] }
        catch { $errors.Add(@($rel, $line, 'file is not utf-8 text')); continue }
      } else { $oldc[$full] = $null; $crlf[$full] = $false }
      $newc[$full] = $oldc[$full]
    }
    $cur = $newc[$full]
    if ($op.Kind -eq 'delete') {
      if ($null -eq $cur) { $errors.Add(@($rel, $line, 'cannot delete - file does not exist')) } else { $newc[$full] = $null }
    } elseif ($op.Kind -eq 'full') {
      $body = $op.Body
      if ($null -ne $cur -and $body.TrimEnd("`n") -ceq $cur.TrimEnd("`n")) { continue }
      if (-not $body.EndsWith("`n")) { $body += "`n" }
      $newc[$full] = $body
    } else {
      $search = $op.Search; $repl = $op.Replace
      if (-not $search.Trim()) {
        if (-not $repl.EndsWith("`n")) { $repl += "`n" }
        $newc[$full] = "$cur" + $repl; continue
      }
      if ($null -eq $cur) { $errors.Add(@($rel, $line, 'file does not exist (use FULL block to create it)')); continue }
      $r = Find-Block $cur $search
      if ($r -is [string]) { $errors.Add(@($rel, $line, $r)); continue }
      $st = $r[0]; $en = $r[1]; $how = $r[2]
      if ($how -eq 'indentation') { $repl = Reindent $repl $cur.Substring($st, $en - $st) $search }
      $newc[$full] = $cur.Substring(0, $st) + $repl + $cur.Substring($en)
      if ($how -ne 'exact') { Say (Yellow "  ~ ${rel}: matched ignoring $how") }
    }
  }

  $changed = @($newc.Keys | Where-Object { -not ([object]::Equals($newc[$_], $oldc[$_])) })
  foreach ($p in $changed) {
    $rel = RelPath $root $p
    if ($null -eq $newc[$p]) { Say ''; Say (Red "  DELETE $rel") }
    elseif ($null -eq $oldc[$p]) { Say ''; Say ((Green "  NEW $rel") + (Dim " ($(($newc[$p].Split("`n").Count - 1)) lines)")) }
    else { Say ''; Show-Diff $rel $oldc[$p] $newc[$p] }
  }
  foreach ($e in $errors) { Say ((Red "  ✗ $($e[0])") + (Dim " (reply line $($e[1])): ") + $e[2]) }
  $unch = $newc.Count - $changed.Count
  Say ''
  $msg = '  ' + (Green "$($changed.Count) file(s) to change")
  if ($unch) { $msg += Dim ", $unch unchanged" }
  if ($errors.Count) { $msg += Red ", $($errors.Count) failed block(s)" }
  Say $msg
  $rc = 0; if ($errors.Count) { $rc = 1 }
  if (-not $changed.Count) { return $rc }
  if ($dry) { Say (Yellow '  dry run - nothing written'); return $rc }
  if (-not $yes) {
    if ([Console]::IsInputRedirected -or $src -eq '-') { Die "not a terminal, can't ask - re-run with -y to apply" '' 1 }
    [Console]::Error.Write((Bold '  apply these changes? [y/N] '))
    $ans = [Console]::ReadLine()
    if ("$ans".Trim().ToLower() -notin 'y', 'yes') { Say (Dim '  nothing changed'); return 1 }
  }
  $bak = $null
  if (-not $nobak) {
    $bak = Join-Path (Join-Path $root '.llmux-backup') ((Get-Date).ToString('yyyyMMdd-HHmmss-ffffff'))
    [void][IO.Directory]::CreateDirectory($bak)
    $created = @($changed | Where-Object { $null -eq $oldc[$_] } | ForEach-Object { RelPath $root $_ })
    [IO.File]::WriteAllText((Join-Path $bak '.created'), ($created -join $NL), $UTF8)
  }
  foreach ($p in $changed) {
    if ($bak -and $null -ne $oldc[$p]) {
      $dst = Join-Path $bak (RelPath $root $p)
      [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
      [IO.File]::Copy($p, $dst, $true)
    }
    if ($null -eq $newc[$p]) { [IO.File]::Delete($p); continue }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p))
    $data = $newc[$p]; if ($crlf[$p]) { $data = $data.Replace("`n", "`r`n") }
    [IO.File]::WriteAllText($p, $data, $UTF8)
  }
  Say (Green "✓ applied $($changed.Count) file(s)")
  if ($bak) { Say ((Dim "  backup: $(RelPath $root $bak)   undo: ") + (Cyan 'llmux undo')) }
  $rc
}

function Cmd-Undo($a) {
  $pos = @($a | Where-Object { -not $_.StartsWith('-') })
  $root = '.'; if ($pos.Count) { $root = $pos[0] }
  $root = (Full-Path $root).TrimEnd('\', '/')
  $bdir = Join-Path $root '.llmux-backup'
  if (-not [IO.Directory]::Exists($bdir)) { Die 'no backups found here' }
  $last = @([IO.Directory]::GetDirectories($bdir) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object) | Select-Object -Last 1
  if (-not $last) { Die 'no backups found here' }
  $src = Join-Path $bdir $last; $n = 0; $removed = 0
  $marker = Join-Path $src '.created'
  if ([IO.File]::Exists($marker)) {
    foreach ($rel in [IO.File]::ReadAllText($marker, $UTF8).Split("`n")) {
      if (-not $rel.Trim()) { continue }
      $p = Safe-Path $root $rel.Trim()
      if ($p -and [IO.File]::Exists($p)) { [IO.File]::Delete($p); $removed++ }
    }
    [IO.File]::Delete($marker)
  }
  foreach ($f in [IO.Directory]::GetFiles($src, '*', 'AllDirectories')) {
    $dst = Join-Path $root (RelPath $src $f)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
    [IO.File]::Copy($f, $dst, $true); $n++
  }
  [IO.Directory]::Delete($src, $true)
  Say (Green "✓ undo ${last}: restored $n, removed $removed new file(s)")
  0
}

function Cmd-Count($a) {
  if (-not $a.Count) { Die 'count what?' 'llmux count file.txt   (or a folder: llmux . -n)' }
  $total = 0L
  foreach ($p in $a) {
    $fp = Full-Path $p
    if ([IO.Directory]::Exists($fp)) { Die "'$p' is a folder" "use: llmux $p --dry-run" }
    if (-not [IO.File]::Exists($fp)) { Die "'$p' not found" }
    $t = [IO.File]::ReadAllText($fp, $UTF8); $n = Count-Tokens $t; $total += $n
    Say ("  {0,8}  {1}  {2}" -f (HTok $n), $p, (Dim (Human $UTF8.GetByteCount($t))))
  }
  if ($a.Count -gt 1) { Say (Bold ("  {0,8}  total" -f (HTok $total))) }
  Say (Dim '  (estimate)')
  0
}

function Help-Main {
  $h = @"
$(Cyan (Bold 'llmux')) $(Dim "$VERSION (powershell)") - make a folder LLM paste-ready, then apply the LLM's edits back.

$(Bold 'USAGE')
  $(Cyan 'llmux') $(Yellow '<folder>') [flags]       pack a folder into one file
  $(Cyan 'llmux apply') $(Yellow '<reply>') [flags]  apply an LLM reply (edit blocks or a full pack)
  $(Cyan 'llmux undo')                  restore files from the last apply
  $(Cyan 'llmux count') $(Yellow '<file>...')        count tokens (estimate)

$(Bold 'PACK FLAGS')
  $(Green '-f, --format') xml|md|txt   output format            $(Dim '[xml]')
  $(Green '-o, --output') FILE         output file              $(Dim '[llmux-<dir>-<time>.<fmt>]')
  $(Green '-d, --depth') N             0 = unlimited, 1 = this folder only $(Dim '[5]')
  $(Green '-s, --max-file-size') SIZE  skip files bigger than this $(Dim '[50k]')
  $(Green '-m, --max-size') SIZE       stop when output reaches this $(Dim '[1m]')
  $(Green '-t, --max-tokens') N        stop when output reaches N tokens $(Dim '[off]')
  $(Green '-i, --include') GLOBS       only these, e.g. "src/*,*.py"
  $(Green '-x, --exclude') GLOBS       skip these, e.g. "docs/,*.test.js"
  $(Green '-n, --dry-run')             show what would be packed, write nothing
  $(Green '-c, --stdout')              print to stdout (pipe to Set-Clipboard)
  $(Green '-a, --hidden')              include dotfiles / dot-folders
      $(Green '--split')               write part1, part2… instead of stopping $(Dim '(max 10)')
      $(Green '--no-tree') / $(Green '--no-header') / $(Green '--no-instructions')
      $(Green '--no-gitignore')        ignore .gitignore rules
      $(Green '--allow-secrets')       include .env, keys, etc. $(Dim '(off by default)')
      $(Green '--force')               allow packing ~ or C:\ $(Dim '(refused by default)')
      $(Green '--max-scan') N / $(Green '--max-time') SEC  safety stop for huge trees $(Dim '[20000 / 20s]')

$(Bold 'APPLY FLAGS')
  $(Green '-n, --dry-run')   preview diff only     $(Green '-y, --yes')  don't ask
  $(Green '-C, --dir') DIR   project folder [.]     $(Green '--no-backup')

$(Bold 'EXAMPLES')
  $(Dim '>') llmux .                          $(Dim '# pack current folder → llmux-<name>-<time>.xml')
  $(Dim '>') llmux src -f md -d 0             $(Dim '# markdown, all depths')
  $(Dim '>') llmux . -t 100k -i "*.py"        $(Dim '# python only, max 100k tokens')
  $(Dim '>') llmux . -c | Set-Clipboard       $(Dim '# straight to clipboard')
  $(Dim '>') llmux apply reply.txt -n         $(Dim '# preview LLM edits')
  $(Dim '>') llmux apply reply.txt            $(Dim '# apply them (backup kept)')
"@
  Say $h
}

# ------------------------------------------------------------------ main --
$rc = 0
try {
  if ($argv.Count -eq 0) { Help-Main }
  else {
    $a0 = $argv[0]; $rest = @($argv | Select-Object -Skip 1)
    switch -CaseSensitive ($a0) {
      { $_ -in '-h', '--help', 'help' } { Help-Main; break }
      { $_ -in '-V', '--version', 'version' } { [Console]::Out.WriteLine("llmux $VERSION (powershell)"); break }
      'apply' { if ($rest.Count -and $rest[0] -in '-h', '--help') { Help-Main } else { $rc = Cmd-Apply $rest }; break }
      'undo' { $rc = Cmd-Undo $rest; break }
      'count' { $rc = Cmd-Count $rest; break }
      'pack' { $rc = Cmd-Pack $rest; break }
      default { $rc = Cmd-Pack @($argv) }
    }
  }
} catch {
  Say ((Red '✗ ') + $_.Exception.Message)
  if ($env:LLMUX_DEBUG) { Say $_.ScriptStackTrace }
  $rc = 2
}
exit ([int]($rc | Select-Object -Last 1))
