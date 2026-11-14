defmodule HarnessForge.Adapters.ClaudeCodeShaperTest do
  @moduledoc """
  The lean-x Bash output shaper (`.claude/hooks/olivium-shape.sh`).

  The first block checks the rendered bytes only. The second runs the rendered hook,
  through the exact settings command, on synthetic hook input, and then runs each
  synthetic command and its shaped form the way Claude Code runs a Bash call. It runs
  only inside Docker (`--network none`, `--pull never`, an `olivium-bench-shaper-test-`
  name, a non-root user), never on the host, and only when OLIVIUM_DOCKER_TESTS=1; it
  is reported as skipped otherwise. It needs the public `debian:stable-slim` and
  `alpine:3` images already pulled. Every command here is a synthetic string.
  """
  use ExUnit.Case, async: true

  alias HarnessForge.Adapters.ClaudeCode.Shaper

  # The v4 benchmark classifier's test pattern (Python `re`, searched in the stripped text).
  @v4_test ~r/(pytest|py\.test|tox\b|nox\b|npm (run )?test|npx (mocha|jest|vitest)|mocha|jest|vitest|mix test|go test|cargo test|unittest)/

  describe "the rendered hook" do
    test "the script is pinned and the settings command runs it only with that digest" do
      digest = :crypto.hash(:sha256, Shaper.script()) |> Base.encode16(case: :lower)
      assert digest == Shaper.sha256()
      assert String.ends_with?(Shaper.script(), "\n")
      refute String.ends_with?(Shaper.script(), "\n\n")

      command = Shaper.command()
      assert String.starts_with?(command, "PATH=/usr/bin:/bin; ")
      assert command =~ ~s(if [ "$h" = "#{digest}  -" ]; then /bin/sh -c "$s" olivium-shape)

      assert command =~
               "| grep -E '#{Shaper.output_line()}'; else echo \"Olivium shaper unavailable: "

      assert String.ends_with?(command, "; fi; true")
      assert length(String.split(command, "$CLAUDE_PROJECT_DIR/" <> Shaper.path())) == 2
      assert Shaper.path() == ".claude/hooks/olivium-shape.sh"
      assert Shaper.timeout_seconds() == 10
    end

    test "the script is POSIX sh and awk, and names no other interpreter" do
      script = Shaper.script()
      assert String.starts_with?(script, "#!/bin/sh\n")

      for word <- ["bash", "python", "perl", "node", "jq", "[[", "$'", "local "] do
        refute script =~ word, word
      end
    end

    test "wrap keeps the command byte for byte on its own lines between the head and the tail" do
      command = "printf '%s\\n' \"a b\" 'c' `d` $(e) \\\\ é ✓\n  echo two\t&& exit 3"

      for test? <- [true, false] do
        wrapped = Shaper.wrap(command, test?)
        [head, tail] = String.split(wrapped, command)
        assert String.ends_with?(head, "\n{\n")
        assert String.starts_with?(tail, "\n} >>\"$__o\" 2>&1; __rc=$?; trap - EXIT;")
        assert String.ends_with?(tail, "(exit $__rc)")
        assert head =~ "awk -v X=#{if test?, do: 1, else: 0} "
        assert head =~ "trap '__olivium_cap \"$__o\"' EXIT"
      end
    end

    test "a test command is one the v4 classifier calls one" do
      pattern = Regex.compile!(Shaper.test_pattern())

      commands = [
        "pytest -q tests",
        "python -m pytest tests/test_a.py 2>&1 | tail -20",
        "uv run py.test",
        "tox",
        "tox -e py312",
        "toxic --help",
        "nox -s tests",
        "noxious",
        "npm test",
        "npm run test -- --grep x",
        "npm run test-node-run-only",
        "npx mocha test/a.spec.js",
        "npx jest",
        "npx vitest run",
        "./node_modules/.bin/mocha",
        "mix test test/a_test.exs",
        "go test ./...",
        "cargo test",
        "python -m unittest discover",
        "grep -rn pytest .",
        "cat setup.cfg",
        "git log --oneline",
        "ls",
        "echo tox_",
        "cd /work/repo && tox\n"
      ]

      for command <- commands do
        # The hook matches the JSON text of the command followed by a space.
        json = command |> Jason.encode!() |> String.slice(1..-2//1)

        assert Regex.match?(pattern, json <> " ") == Regex.match?(@v4_test, String.trim(command)),
               command
      end
    end
  end

  describe "the hook in Docker" do
    if System.get_env("OLIVIUM_DOCKER_TESTS") != "1" do
      @describetag skip:
                     "set OLIVIUM_DOCKER_TESTS=1 to run the shaper in Docker (debian:stable-slim, alpine:3)"
    end

    @describetag timeout: 300_000

    for image <- ["debian:stable-slim", "alpine:3"] do
      @tag image: image
      test "contract cases on #{image}", %{image: image} do
        run_cases(image)
      end
    end
  end

  @test300 "pytest() { i=1; while [ $i -le 300 ]; do echo \"tests/test_mod.py::test_case_$i PASSED [ $i%]\"; i=$((i + 1)); done; echo '=== 1 failed, 299 passed in 0.12s ==='; return 1; }; pytest -q tests"

  defp cases do
    [
      {"test300", %{"command" => @test300}, nil},
      {"line500", %{"command" => "printf '%0500d\\n' 7; echo short"}, nil},
      {"exit3", %{"command" => "seq 1 5; exit 3"}, nil},
      {"cd1", %{"command" => "mkdir -p sub && cd sub && echo moved"}, "cwd"},
      {"cd2", %{"command" => "pwd"}, "cwd"},
      {"heredoc", %{"command" => "cat <<'E'\nheredoc-ok $HOME `x`\nE\necho after"}, nil},
      {"amp", %{"command" => "sleep 0 & echo started; wait"}, nil},
      {"rib_other", %{"command" => "echo bg", "run_in_background" => true}, nil},
      {"rib_test", %{"command" => "echo pytest-in-background", "run_in_background" => true}, nil},
      {"timeout_keep", %{"command" => "echo mocha 900", "timeout" => 900_000}, nil},
      {"timeout_raise", %{"command" => "echo jest 5", "timeout" => 5000}, nil},
      {"unicode",
       %{
         "command" =>
           "echo \"a \\\"b\\\" \\\\ c\" 'it'\"'\"'s' é ✓ 😀\ttab; printf '%s\\n' \"$HOME\"",
         "dangerouslyDisableSandbox" => false,
         "nested" => %{"k" => ["v", 1, nil, %{"q" => "\"}"}]}
       }, nil},
      {"nocut", %{"command" => "printf 'a\\r\\nb\\n\\nno-newline'"}, nil},
      {"set_e", %{"command" => "set -e; echo before; false; echo never"}, nil}
    ]
  end

  defp payload(tool, input) do
    Jason.encode!(%{
      "session_id" => "s",
      "transcript_path" => "/tmp/t.jsonl",
      "cwd" => "/work",
      "permission_mode" => "default",
      "hook_event_name" => "PreToolUse",
      "tool_name" => tool,
      "tool_input" => input,
      "tool_use_id" => "toolu_s"
    })
  end

  @phase1 """
  set -u
  cmd=$(cat /work/in/command.txt)
  mkdir -p /tmp/o
  for f in /work/in/p1/*.json; do
    b=$(basename "$f" .json)
    if [ "$b" = tmp_missing ]; then t=/nonexistent-olivium; else t=/tmp; fi
    TMPDIR=$t CLAUDE_PROJECT_DIR=/work/in/proj /bin/sh -c "$cmd" < "$f" > /tmp/o/$b.out 2> /tmp/o/$b.err
    echo $? > /tmp/o/$b.code
  done
  cd /tmp/o && tar cf - . | base64
  """

  # A Bash call as Claude Code runs it: from the session's working directory, stdin
  # /dev/null, and the directory kept for the next call when the command succeeds.
  @phase2 """
  set -u
  mkdir -p /tmp/o
  if command -v bash >/dev/null 2>&1; then SH=bash; else SH=sh; fi
  run() {
    d=$1; n=$2; c=$3
    [ -f "$d/cwd" ] || { mkdir -p "$d/home"; echo "$d/home" > "$d/cwd"; }
    $SH -c 'cd "$(cat "$1/cwd")" || exit 99; eval "$(cat "$2")" < /dev/null && pwd -P >| "$1/cwd"' call "$d" "$c" > /tmp/o/$n.out 2>&1
    echo $? > /tmp/o/$n.code
    sed "s#^$d/##" "$d/cwd" > /tmp/o/$n.cwd
  }
  for f in /work/in/p2/*.raw; do
    b=$(basename "$f" .raw)
    s=$(cat /work/in/p2/$b.seq)
    run /tmp/raw-$s raw-$b "$f"
    run /tmp/shaped-$s shaped-$b /work/in/p2/$b.shaped
    n=0; m=
    for t in /tmp/olivium-out.*; do [ -f "$t" ] && { n=$((n + 1)); m=$(stat -c '%a' "$t"); }; done
    echo "$n $m" > /tmp/o/shaped-$b.tmp
    rm -f /tmp/olivium-out.*
  done
  cd /tmp/o && tar cf - . | base64
  """

  defp run_cases(image) do
    dir = Path.join(System.tmp_dir!(), "hf-shaper-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(dir) end)
    File.mkdir_p!(Path.join(dir, "p1"))
    File.mkdir_p!(Path.join(dir, "p2"))
    File.mkdir_p!(Path.join(dir, "proj/.claude/hooks"))
    File.write!(Path.join(dir, "proj/" <> Shaper.path()), Shaper.script())
    File.write!(Path.join(dir, "command.txt"), Shaper.command())
    File.write!(Path.join(dir, "phase1.sh"), @phase1)
    File.write!(Path.join(dir, "phase2.sh"), @phase2)

    for {id, input, _} <- cases(),
        do: File.write!(Path.join(dir, "p1/#{id}.json"), payload("Bash", input))

    File.write!(
      Path.join(dir, "p1/tmp_missing.json"),
      payload("Bash", %{"command" => "echo tmp"})
    )

    File.write!(Path.join(dir, "p1/read_tool.json"), payload("Read", %{"file_path" => "/x"}))
    File.write!(Path.join(dir, "p1/not_json.json"), "this is not json")

    hook = docker!(image, dir, "p1", "phase1.sh")

    updated =
      for {id, input, seq} <- cases(), into: %{} do
        out = hook["#{id}.out"]
        assert hook["#{id}.code"] == "0\n", id
        assert hook["#{id}.err"] == "", "#{id}: #{hook["#{id}.err"]}"

        if out == "" do
          {id, nil}
        else
          assert [line] = String.split(out, "\n", trim: true)

          assert %{
                   "hookSpecificOutput" => %{
                     "hookEventName" => "PreToolUse",
                     "updatedInput" => new
                   }
                 } = Jason.decode!(line)

          File.write!(Path.join(dir, "p2/#{id}.raw"), input["command"])
          File.write!(Path.join(dir, "p2/#{id}.shaped"), new["command"])
          File.write!(Path.join(dir, "p2/#{id}.seq"), seq || id)
          {id, new}
        end
      end

    # Passed through: a background job, and a call already in the background that is no test.
    assert updated["amp"] == nil
    assert updated["rib_other"] == nil

    for {id, input, _} <- cases(), updated[id] != nil do
      test? = Regex.match?(@v4_test, input["command"])
      new = updated[id]
      assert new["command"] == Shaper.wrap(input["command"], test?), id

      assert Map.drop(new, ~w(command timeout run_in_background)) ==
               Map.drop(input, ~w(command timeout run_in_background)),
             id

      if test? do
        assert new["timeout"] == max(input["timeout"] || 0, 600_000), id
        assert new["run_in_background"] == false, id
      else
        assert Map.take(new, ~w(timeout run_in_background)) ==
                 Map.take(input, ~w(timeout run_in_background)),
               id
      end
    end

    assert updated["rib_test"]["run_in_background"] == false
    assert updated["timeout_keep"]["timeout"] == 900_000
    assert updated["timeout_raise"]["timeout"] == 600_000

    assert Map.keys(updated["unicode"]) |> Enum.sort() ==
             ~w(command dangerouslyDisableSandbox nested)

    # Visible, never silent: no temporary file, a tool that is not Bash, input that is not JSON.
    assert hook["tmp_missing.out"] == ""

    assert hook["tmp_missing.err"] =~
             ~r/^Olivium shaper unavailable: .*; this command runs as written\.\n$/

    assert hook["read_tool.out"] == "" and hook["read_tool.err"] == ""
    assert hook["not_json.out"] == ""
    assert hook["not_json.err"] =~ "Olivium shaper unavailable: "

    # Each side runs in its own directory tree, /tmp/raw-<seq> or /tmp/shaped-<seq>.
    calls =
      docker!(image, dir, "p2", "phase2.sh")
      |> Map.new(fn {name, bytes} ->
        {name, String.replace(bytes, ~r{/tmp/(raw|shaped)-}, "/tmp/X-")}
      end)

    for {id, _, _} <- cases(), updated[id] != nil do
      assert calls["raw-#{id}.code"] == calls["shaped-#{id}.code"], id
      assert calls["raw-#{id}.cwd"] == calls["shaped-#{id}.cwd"], id
    end

    raw = calls["raw-test300.out"]
    shaped = calls["shaped-test300.out"]
    assert calls["shaped-test300.code"] == "1\n"
    assert byte_size(raw) > 10_000
    assert byte_size(shaped) < 4_100

    assert [_, kept_head, file, kept_tail] =
             Regex.run(
               ~r/\A(.*?)\[olivium: cut \d+ lines \(\d+ bytes\); full output: (\/tmp\/olivium-out\.\S+)\]\n(.*)\z/s,
               shaped
             )

    assert byte_size(kept_head) <= 1200 and byte_size(kept_tail) <= 2800
    assert String.starts_with?(raw, kept_head) and String.ends_with?(raw, kept_tail)
    assert kept_tail =~ "=== 1 failed, 299 passed in 0.12s ===\n"
    assert file =~ ~r/^\/tmp\/olivium-out\.[A-Za-z0-9]+$/
    assert calls["shaped-test300.tmp"] == "1 600\n"

    assert calls["shaped-line500.out"] =~
             ~r/\A0{400} \[olivium: cut 100 bytes; full output: \/tmp\/olivium-out\.\S+\]\nshort\n\z/

    assert calls["shaped-exit3.code"] == "3\n"
    assert calls["shaped-exit3.out"] == calls["raw-exit3.out"]
    assert calls["shaped-cd2.out"] == calls["raw-cd2.out"]
    assert calls["shaped-cd2.out"] == "/tmp/X-cwd/home/sub\n"
    assert calls["shaped-cd2.cwd"] == "home/sub\n"

    for id <- ~w(exit3 cd1 cd2 heredoc unicode nocut set_e rib_test timeout_keep) do
      assert calls["shaped-#{id}.out"] == calls["raw-#{id}.out"], id
      assert calls["shaped-#{id}.tmp"] == "0 \n", id
    end

    assert calls["raw-heredoc.out"] =~ "heredoc-ok $HOME `x`\nafter\n"
    # `set -e` inside the call: whatever the shell does with it, both forms do the same.
    assert calls["shaped-set_e.out"] == calls["raw-set_e.out"]
  end

  defp docker!(image, dir, phase, script) do
    name = "olivium-bench-shaper-test-#{System.unique_integer([:positive])}-#{phase}"

    args =
      ~w(run --rm --pull never --network none --memory 256m --pids-limit 128 --user 1001:1001 --name) ++
        [
          name,
          "-v",
          dir <> ":/work/in:ro",
          "--entrypoint",
          "/bin/sh",
          image,
          "/work/in/" <> script
        ]

    {out, code} = System.cmd("docker", args, stderr_to_stdout: true)
    assert code == 0, "docker run #{image} exited #{code}: #{String.slice(out, -800, 800)}"

    {:ok, files} =
      :erl_tar.extract({:binary, Base.decode64!(out, ignore: :whitespace)}, [:memory])

    Map.new(files, fn {name, bytes} -> {Path.basename(to_string(name)), bytes} end)
  end
end
