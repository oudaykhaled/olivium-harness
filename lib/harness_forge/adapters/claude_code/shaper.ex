defmodule HarnessForge.Adapters.ClaudeCode.Shaper do
  @moduledoc """
  The `lean-x` Bash output shaper: `.claude/hooks/olivium-shape.sh`, a Claude Code
  PreToolUse hook (matcher `Bash`) that answers with `updatedInput`.

  It copies every key of the call's `tool_input` and changes only:

  - `command`: wrapped so that the command, kept byte for byte on its own lines between
    `{` and `}`, writes its output to a private temporary file (`mktemp`, mode 0600).
    When the command ends, also through `exit` (an `EXIT` trap), the output is printed
    shaped: a line over 400 bytes keeps its first 400 bytes plus
    ` [olivium: cut N bytes]`; the output of a test command over 4,000 bytes (after
    that) keeps the head lines that fit in 1,200 bytes and the tail lines that fit in
    2,800 bytes, with one line between them,
    `[olivium: cut N lines (B bytes); full output: <file>]`. When only long lines were
    cut, the first such marker names the file too. With nothing cut the output is
    printed as it was, byte for byte, and the file is removed; otherwise the file is
    kept so the agent can read the rest. The exit code and the working directory are
    kept (`cd` persists, `exit 3` still prints and reports 3).
  - for a test command only: `timeout` becomes 600,000 ms when it is absent or lower,
    and `run_in_background` becomes false, so a suite runs in the foreground instead
    of being moved to the background after 2 minutes.

  A test command is one the v4 benchmark classifier calls one: its text contains
  pytest, py.test, tox or nox as a word end, npm test, npm run test, mocha, jest,
  vitest, mix test, go test, cargo test or unittest (`test_pattern/0`), matched on the
  JSON text of the command (escapes do not change these words).

  The hook prints nothing, and the command runs as written, when the call is already
  in the background and is not a test, when the command starts a background job
  (an `&` outside quotes, `nohup`, `disown`, `setsid`), sets a trap, replaces the shell
  (`exec` of a program), ends in a backslash, or is over 64 KiB of JSON text. When the
  hook cannot work (no `awk` or `mktemp`, no temporary file, input that is not the
  hook JSON) it prints one line on stderr, `Olivium shaper unavailable: <reason>; ...`,
  and no JSON: the command then runs as written and the transcript records why.

  It never approves or refuses a call. The settings command (`command/0`) sets `PATH`
  to `/usr/bin:/bin`, runs the file only while its SHA-256 is the pinned one and passes
  on only a line of the fixed output shape. The script is POSIX `sh` and `awk` only.
  It works on the JSON text of the input without decoding it, so the command and
  every other value are copied exactly as Claude Code sent them.
  """

  @path ".claude/hooks/olivium-shape.sh"
  @timeout_seconds 10

  # Applied to the captured output when the command ends (contract, lane H, item 4).
  @cap_awk ~S"""
  FNR == 1 { P++ }
  P == 1 {
    b = length($0)
    if (b > 400) { LL++; b = 400 + length(" [olivium: cut " (b - 400) " bytes]") }
    N++; TOT += b + 1
    if (N <= 1200) HS[N] = b + 1
    TS[N % 2801] = b + 1
    next
  }
  FNR == 1 {
    if (X && TOT > 4000) {
      a = 0; while (H < N && H < 1200 && a + HS[H + 1] <= 1200) { a += HS[H + 1]; H++ }
      a = 0; while (T < N - H && T < 2800 && a + TS[(N - T) % 2801] <= 2800) { a += TS[(N - T) % 2801]; T++ }
      if (H == 0 && T == 0) H = 1
      HT = (N - H - T > 0)
    }
    if (!HT && !LL) { NC = 1; exit }
  }
  HT && FNR > H && FNR <= N - T { CB += length($0) + 1; next }
  HT && !M && FNR > N - T { mark() }
  {
    b = length($0)
    if (b > 400) { printf "%s [olivium: cut %d bytes%s]\n", substr($0, 1, 400), b - 400, ((HT || PS) ? "" : "; full output: " FILENAME); PS = 1 }
    else print
  }
  END { if (NC || P < 2) exit 10; if (HT && !M) mark() }
  function mark() { printf "[olivium: cut %d lines (%d bytes); full output: %s]\n", N - H - T, CB, FILENAME; M = 1 }
  """

  # The text that goes before and after the command. X is 1 for a test command.
  wrapper_head = fn x ->
    "__olivium_cap() { case $1 in /dev/stdout) return 0 ;; esac; " <>
      "LC_ALL=C command -p awk -v X=#{x} '\n" <>
      @cap_awk <>
      "' \"$1\" \"$1\"; case $? in 0) ;; " <>
      "10) command -p cat \"$1\"; command -p rm -f \"$1\" ;; " <>
      "*) echo '[olivium: output not shaped: awk failed; the full output follows]'; command -p cat \"$1\" ;; esac; }\n" <>
      "__o=$(command -p mktemp \"${TMPDIR:-/tmp}/olivium-out.XXXXXX\") || " <>
      "{ __o=/dev/stdout; echo '[olivium: output not shaped: no temporary file]'; }\n" <>
      "trap '__olivium_cap \"$__o\"' EXIT\n{\n"
  end

  @wrapper_heads %{false => wrapper_head.("0"), true => wrapper_head.("1")}
  @wrapper_tail "\n} >>\"$__o\" 2>&1; __rc=$?; trap - EXIT; __olivium_cap \"$__o\"; (exit $__rc)"

  # JSON string text (without the quotes), then an awk string literal inside the
  # single-quoted awk program of the hook.
  json = fn text ->
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
  end

  awk = fn text ->
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("'", "\\047")
    |> String.replace("\n", "\\n")
  end

  # The v4 classifier (`classify_bash` test pattern). `\b` after tox and nox is a
  # non-word character; the command text gets one space appended, so the end counts.
  @test_pattern "(pytest|py[.]test|tox[^A-Za-z0-9_]|nox[^A-Za-z0-9_]|npm (run )?test|npx (mocha|jest|vitest)|mocha|jest|vitest|mix test|go test|cargo test|unittest)"

  @template ~S"""
  #!/bin/sh
  # Generated by Olivium Harness. A Claude Code PreToolUse hook (Bash) that shapes what
  # the model reads from a command. The command is wrapped, byte for byte, so that its
  # output goes to a private temporary file; when it ends, any line over 400 bytes keeps
  # its first 400 bytes, and the output of a test command over 4000 bytes keeps a
  # 1200-byte head and a 2800-byte tail. Every cut is marked "[olivium: cut ...", and a
  # marker names the temporary file, which keeps the full output; with nothing cut the
  # output is printed as it was and the file is removed. The exit code and the working
  # directory are kept. A test command also gets a 600 s timeout in the foreground.
  # A command that starts a background job, sets a trap, replaces the shell or ends in
  # a backslash, a non-test call already in the background and a command over 64 KiB
  # run as written. It never approves or refuses a call: it prints one line of JSON
  # with the new tool input, or nothing. When it cannot work it says so in one line on
  # stderr and the command runs as written.
  LC_ALL=C
  export LC_ALL
  unavailable() {
    printf 'Olivium shaper unavailable: %s; this command runs as written.\n' "$1" >&2
    exit 0
  }
  command -v awk >/dev/null 2>&1 || unavailable 'awk is not installed'
  command -v mktemp >/dev/null 2>&1 || unavailable 'mktemp is not installed'
  t=$(mktemp "${TMPDIR:-/tmp}/olivium-out.XXXXXX" 2>/dev/null) || unavailable 'no temporary file can be made'
  rm -f "$t"
  exec awk '
  BEGIN {
    PRE0 = "@PRE0@"
    PRE1 = "@PRE1@"
    SUF = "@SUF@"
    TEST = "@TEST@"
    TRAP = "([;&|({!]|\\\\n|then|do|else)( |\\\\t)*trap "
    EXEC = "([;&|({!]|\\\\n|then|do|else)( |\\\\t)*exec +[^ 0-9<>&|;]"
  }
  function bail(why) {
    printf "Olivium shaper unavailable: %s; this command runs as written.\n", why > "/dev/stderr"
    exit 0
  }
  function ws() { while (i <= n && index(" \t\r\n", substr(s, i, 1)) > 0) i++ }
  # A JSON string at i, returned as its raw text with the quotes.
  function jstr(    st, c) {
    st = i; i++
    while (i <= n) {
      if (match(substr(s, i, 4096), /^[^"\\]+/)) { i += RLENGTH; continue }
      c = substr(s, i, 1)
      if (c == "\\") { i += 2; continue }
      i++
      return substr(s, st, i - st)
    }
    bad = "the hook input has an unterminated string"
    return ""
  }
  # Any JSON value at i, returned as its raw text.
  function jval(    st, c, d) {
    ws(); st = i; c = substr(s, i, 1)
    if (c == "\"") return jstr()
    if (c == "{" || c == "[") {
      d = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\"") { jstr(); if (bad != "") return ""; continue }
        if (c == "{" || c == "[") d++
        else if (c == "}" || c == "]") { d--; if (d == 0) { i++; return substr(s, st, i - st) } }
        i++
      }
      bad = "the hook input has an unterminated object"
      return ""
    }
    if (match(substr(s, i, 64), /^(-?[0-9][0-9.eE+-]*|true|false|null)/)) { i += RLENGTH; return substr(s, st, RLENGTH) }
    bad = "the hook input has a value that is not JSON"
    return ""
  }
  # The object at i: raw keys in K, raw values in V, in order; returns their number.
  function jobj(K, V,    m, c) {
    ws()
    if (substr(s, i, 1) != "{") { bad = "the hook input is not a JSON object"; return 0 }
    i++; m = 0; ws()
    if (substr(s, i, 1) == "}") { i++; return 0 }
    while (bad == "") {
      ws()
      if (substr(s, i, 1) != "\"") { bad = "the hook input has a key that is not a string"; return 0 }
      m++; K[m] = jstr(); ws()
      if (substr(s, i, 1) != ":") { bad = "the hook input misses a colon"; return 0 }
      i++; V[m] = jval(); ws()
      c = substr(s, i, 1); i++
      if (c == "}") return m
      if (c != ",") bad = "the hook input misses a comma"
    }
    return 0
  }
  # Whether the command starts a background job: an & outside quotes and comments that
  # is not part of &&, >&, <&, &> or |&. Read through the JSON escapes; a here-document
  # body counts as shell text, so an & in one also counts.
  function background(c,    k, L, ch, e, d, pd, nd, sq, dq, esc, cm) {
    if (index(c, "&") == 0) return 0
    L = length(c); pd = "\n"
    for (k = 1; k <= L; k++) {
      ch = substr(c, k, 1)
      if (ch == "\\") {
        e = substr(c, k + 1, 1); k++
        if (e == "u") { k += 4; d = "u" }
        else if (e == "n") d = "\n"
        else if (e == "t") d = "\t"
        else if (e == "r" || e == "b" || e == "f") d = " "
        else d = e
      } else d = ch
      if (cm) { if (d == "\n") cm = 0; pd = d; continue }
      if (sq) { if (d == "\047") sq = 0; pd = d; continue }
      if (esc) { esc = 0; pd = "x"; continue }
      if (d == "\\") { esc = 1; pd = d; continue }
      if (dq) { if (d == "\"") dq = 0; pd = d; continue }
      if (d == "\047") { sq = 1; pd = d; continue }
      if (d == "\"") { dq = 1; pd = d; continue }
      if (d == "#" && index(" \t\n;&|(", pd) > 0) { cm = 1; continue }
      if (d == "&") {
        nd = substr(c, k + 1, 1)
        if (pd != "&" && pd != ">" && pd != "<" && pd != "|" && nd != "&" && nd != ">") return 1
      }
      pd = d
    }
    return 0
  }
  { s = s $0 "\n" }
  END {
    n = length(s); i = 1; bad = ""
    m = jobj(TK, TV)
    if (bad != "") bail(bad)
    tool = ""; ti = ""
    for (j = 1; j <= m; j++) {
      if (TK[j] == "\"tool_name\"") tool = TV[j]
      else if (TK[j] == "\"tool_input\"") ti = TV[j]
    }
    if (tool != "\"Bash\"") exit 0
    s = ti; n = length(s); i = 1
    m = jobj(K, V)
    if (bad != "") bail(bad)
    ci = 0; bg = 0
    for (j = 1; j <= m; j++) {
      if (K[j] == "\"command\"") ci = j
      else if (K[j] == "\"run_in_background\"" && V[j] == "true") bg = 1
    }
    if (!ci || V[ci] !~ /^"/) bail("the hook input has no command string")
    c = substr(V[ci], 2, length(V[ci]) - 2)
    test = ((c " ") ~ TEST)
    if (bg && !test) exit 0
    if (length(c) > 65536 || c ~ /nohup|disown|setsid/ || c ~ /\\\\$/) exit 0
    if ((";" c) ~ TRAP || (";" c) ~ EXEC || background(c)) exit 0
    o = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"" (test ? PRE1 : PRE0) c SUF "\""
    ht = 0; hb = 0
    for (j = 1; j <= m; j++) {
      if (j == ci) continue
      v = V[j]
      if (test && K[j] == "\"timeout\"") { ht = 1; if (v !~ /^[0-9]/ || v + 0 < 600000) v = "600000" }
      if (test && K[j] == "\"run_in_background\"") { hb = 1; v = "false" }
      gsub(/[\r\n]/, " ", v)
      o = o "," K[j] ":" v
    }
    if (test && !ht) o = o ",\"timeout\":600000"
    if (test && !hb) o = o ",\"run_in_background\":false"
    print o "}}}"
  }
  '
  """

  @script @template
          |> String.replace("@PRE0@", awk.(json.(@wrapper_heads[false])))
          |> String.replace("@PRE1@", awk.(json.(@wrapper_heads[true])))
          |> String.replace("@SUF@", awk.(json.(@wrapper_tail)))
          |> String.replace("@TEST@", awk.(@test_pattern))

  # The pin: a change to the script must change this line too.
  @sha256 "5eac93b8fc16f28a8a90aa2579f8877cf39ebf3696fccf2759d10e2a4dd898cd"

  digest = :crypto.hash(:sha256, @script) |> Base.encode16(case: :lower)

  if digest != @sha256 do
    raise CompileError,
      description: "olivium-shape.sh has SHA-256 #{digest}, not the pinned #{@sha256}"
  end

  # The one line the settings command passes on: the fixed start of the output, a
  # command that begins with the wrapper, and the closing braces.
  @output_line ~S|^[{]"hookSpecificOutput":[{]"hookEventName":"PreToolUse","updatedInput":[{]"command":"__olivium_cap[(][)] [{] case .*[}][}][}]$|

  @spec path() :: String.t()
  def path, do: @path

  @doc "The hook script, byte for byte; it ends in exactly one newline."
  @spec script() :: String.t()
  def script, do: @script

  @doc "The pinned SHA-256 of `script/0`, lowercase hex."
  @spec sha256() :: String.t()
  def sha256, do: @sha256

  @doc "Seconds Claude Code gives the hook."
  @spec timeout_seconds() :: pos_integer()
  def timeout_seconds, do: @timeout_seconds

  @doc "The fixed shape of the only line the settings command passes on."
  @spec output_line() :: String.t()
  def output_line, do: @output_line

  @doc "The test-command pattern, as the hook matches it (POSIX ERE)."
  @spec test_pattern() :: String.t()
  def test_pattern, do: @test_pattern

  @doc """
  The command the hook makes of `command` (decoded text), for a test command or not.
  Documentation and tests only: the hook builds the same bytes from the JSON text.
  """
  @spec wrap(String.t(), boolean()) :: String.t()
  def wrap(command, test?) when is_binary(command) and is_boolean(test?),
    do: @wrapper_heads[test?] <> command <> @wrapper_tail

  @doc """
  The settings command: PATH set to /usr/bin:/bin, the script run only while its
  SHA-256 is the pinned one, and only a line of the fixed output shape passed on.
  The script's own `Olivium shaper unavailable` line reaches stderr. Always exits 0.
  """
  @spec command() :: String.t()
  def command do
    ~s(PATH=/usr/bin:/bin; f="$CLAUDE_PROJECT_DIR/#{@path}"; s=$\(cat "$f" 2>/dev/null\); h=$\(printf '%s\\n' "$s" | { sha256sum || shasum -a 256; } 2>/dev/null\); if [ "$h" = "#{@sha256}  -" ]; then /bin/sh -c "$s" olivium-shape | grep -E '#{@output_line}'; else echo "Olivium shaper unavailable: #{@path} is missing, changed or cannot be checked; commands run as written." >&2; fi; true)
  end
end
