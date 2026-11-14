defmodule HarnessForge.Adapters.ClaudeCode.OutputStyle do
  @moduledoc """
  The `lean-x` output style, `.claude/output-styles/olivium.md`, selected with
  `"outputStyle": "olivium"` in `.claude/settings.json`.

  The text is fixed: nothing from the repository or the spec reaches it. Its four body
  lines ask for fewer model requests (independent searches and reads in one Bash call,
  the narrowest test in the same call as the edit, tests in the foreground). On Claude
  Code 2.1.311 a style of this size adds 38 bytes to the system prompt and its body to
  the first message of every request, about 185 to 227 tokens per request (measured
  with a mock capture meter). `keep-coding-instructions: true` keeps Claude Code's own
  coding instructions in interactive sessions; in `-p` mode the prompt has none to keep.
  """

  @path ".claude/output-styles/olivium.md"
  @name "olivium"
  # The largest style body measured: a longer file costs more on every request.
  @max_bytes 495
  @content """
  ---
  name: olivium
  description: Olivium Harness - fewer requests
  keep-coding-instructions: true
  ---
  Work in as few requests as you can.
  - Put independent searches and file reads in one Bash call, joined with `;`, and read exact line ranges.
  - After an edit, run the narrowest relevant test in the same Bash call.
  - Run tests in the foreground and wait for them; do not poll with sleep.
  """

  if byte_size(@content) > @max_bytes,
    do: raise(CompileError, description: "the olivium output style is over #{@max_bytes} bytes")

  @spec path() :: String.t()
  def path, do: @path

  @doc "The value of `outputStyle` in `.claude/settings.json`."
  @spec name() :: String.t()
  def name, do: @name

  @spec content() :: String.t()
  def content, do: @content

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes
end
