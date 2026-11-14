defmodule HarnessForge.AnalyzersGitBoundaryTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Analyzers.Git
  alias HarnessForge.Contracts.Error

  @moduletag :tmp_dir

  @author [
    {"GIT_AUTHOR_NAME", "Synthetic"},
    {"GIT_AUTHOR_EMAIL", "synthetic@example.invalid"},
    {"GIT_COMMITTER_NAME", "Synthetic"},
    {"GIT_COMMITTER_EMAIL", "synthetic@example.invalid"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"}
  ]

  defp git!(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, env: @author, stderr_to_stdout: true)
    output
  end

  defp repository(dir) do
    root = Path.join(dir, "repo")
    File.mkdir_p!(root)
    git!(root, ["init", "--quiet"])
    File.write!(Path.join(root, "app.txt"), "one\n")
    File.write!(Path.join(root, ".gitattributes"), "* diff=evil filter=evil\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "first"])
    File.write!(Path.join(root, "app.txt"), "two\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "--quiet", "-m", "second"])
    root
  end

  # Every key below names a program git would start. The script only touches a
  # marker in the test's own directory, and the boundary must never start it.
  defp make_hostile(root, dir) do
    marker = Path.join(dir, "executed")
    script = Path.join(dir, "evil.sh")
    File.write!(script, "#!/bin/sh\ntouch #{marker}\ncat >/dev/null 2>&1\nexit 0\n")
    File.chmod!(script, 0o755)

    File.write!(Path.join(root, ".git/config"), """
    [core]
    \trepositoryformatversion = 1
    \tbare = false
    \tfsmonitor = #{script}
    \tpager = #{script}
    \tsshCommand = #{script}
    \thooksPath = #{dir}
    [extensions]
    \tpartialClone = origin
    [remote "origin"]
    \turl = ext::#{script}
    \tpromisor = true
    \tpartialclonefilter = blob:none
    [diff]
    \texternal = #{script}
    [diff "evil"]
    \ttextconv = #{script}
    \tcommand = #{script}
    [filter "evil"]
    \tclean = #{script}
    \tsmudge = #{script}
    \tprocess = #{script}
    [gpg]
    \tprogram = #{script}
    [log]
    \tshowSignature = true
    [pager]
    \tlog = #{script}
    """)

    File.write!(Path.join(dir, "post-index-change"), "#!/bin/sh\ntouch #{marker}\n")
    File.chmod!(Path.join(dir, "post-index-change"), 0o755)
    marker
  end

  test "a hostile .git/config cannot start anything", %{tmp_dir: dir} do
    root = repository(dir)
    marker = make_hostile(root, dir)

    # Control: the hostile values are live config. Reading config runs nothing.
    assert git!(root, ["config", "--get", "core.fsmonitor"]) =~ "evil.sh"
    assert git!(root, ["config", "--get", "diff.external"]) =~ "evil.sh"

    assert {:ok, repo} = Git.open(root)
    assert {:ok, head} = Git.head(repo)
    assert head =~ ~r/^[0-9a-f]{40}$/
    assert {:ok, [".gitattributes", "app.txt"]} = Git.ls_files(repo)
    assert {:ok, [".gitattributes", "app.txt"]} = Git.ls_files(repo, others: true)
    assert {:ok, log} = Git.log(repo, ["--format=%H", "--numstat", "--name-only"])
    assert log =~ "app.txt"
    assert {:ok, "two\n"} = Git.show_path(repo, "HEAD", "app.txt")
    assert {:ok, "one\n"} = Git.show_path(repo, "HEAD~1", "app.txt")

    # A lazy fetch from the promisor remote is the path to `ext::`.
    blob = root |> git!(["rev-parse", "HEAD:app.txt"]) |> String.trim()
    <<prefix::binary-size(2), rest::binary>> = blob
    File.rm!(Path.join([root, ".git/objects", prefix, rest]))
    assert {:error, %Error{code: "git_failed"}} = Git.show_path(repo, "HEAD", "app.txt")

    refute File.exists?(marker), "a repository-configured program was executed"
  end

  test "only allow-listed commands and arguments reach git", %{tmp_dir: dir} do
    assert {:ok, repo} = Git.open(repository(dir))

    for {subcommand, args} <- [
          {"push", []},
          {"config", ["--get", "core.fsmonitor"]},
          {"fetch", []},
          {"status", []},
          {"log", ["--output=/tmp/owned"]},
          {"log", ["--ext-diff"]},
          {"log", ["--textconv"]},
          {"log", ["--show-signature"]},
          {"log", ["-p"]},
          {"log", ["--format=%GG"]},
          {"log", ["--since=1.year.ago"]},
          {"log", ["--max-count=999999999"]},
          {"log", ["--", "../outside"]},
          {"log", ["--", ".git/config"]},
          {"log", ["-Oorder"]},
          {"ls-files", ["--modified"]},
          {"ls-files", ["--deleted"]},
          {"ls-files", ["--recurse-submodules"]},
          {"rev-parse", ["--show-toplevel"]},
          {"rev-parse", ["--git-path", "config"]},
          {"rev-parse", ["--parseopt"]},
          {"rev-parse", []},
          {"show", ["HEAD"]},
          {"show", ["HEAD:../outside"]},
          {"show", ["HEAD:.git/config"]},
          {"show", ["HEAD:/etc/passwd"]},
          {"show", ["--output=/tmp/x", "HEAD:app.txt"]},
          {"show", ["HEAD:a", "HEAD:b"]}
        ] do
      assert {:error, %Error{code: "git_command_rejected"}} = Git.run(repo, subcommand, args),
             inspect({subcommand, args})
    end
  end

  test "a repository with no commits has no head", %{tmp_dir: dir} do
    root = Path.join(dir, "empty")
    File.mkdir_p!(root)
    git!(root, ["init", "--quiet"])

    assert {:ok, repo} = Git.open(root)
    assert {:ok, nil} = Git.head(repo)
    assert {:ok, []} = Git.ls_files(repo)
  end

  test "output is capped", %{tmp_dir: dir} do
    assert {:ok, repo} = Git.open(repository(dir))

    assert {:error, %Error{code: "git_output_limit"}} =
             Git.log(repo, ["--format=%H"], max_bytes: 10)
  end

  test "a hung process is killed at the deadline", %{tmp_dir: dir} do
    root = repository(dir)
    pidfile = Path.join(dir, "pid")
    slow = Path.join(dir, "slow-git")
    File.write!(slow, "#!/bin/sh\necho $$ > #{pidfile}\nexec sleep 30\n")
    File.chmod!(slow, 0o755)

    {micros, result} =
      :timer.tc(fn ->
        Git.rev_parse(%Git{root: root, executable: slow}, ["HEAD"], timeout_ms: 3_000)
      end)

    assert {:error, %Error{code: "git_timeout"}} = result
    assert micros < 15_000_000

    pid = pidfile |> File.read!() |> String.trim()
    assert_gone(pid, 50)
  end

  defp assert_gone(pid, attempts) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} when attempts > 0 ->
        Process.sleep(50)
        assert_gone(pid, attempts - 1)

      {_, status} ->
        assert status != 0, "process #{pid} survived the timeout"
    end
  end

  test "absent or refused git is reported, not raised", %{tmp_dir: dir} do
    plain = Path.join(dir, "plain")
    File.mkdir_p!(plain)

    assert {:error, %Error{code: "git_unavailable", details: ["not_a_repository"]}} =
             Git.open(plain)

    assert %{"status" => "git_unavailable", "reason" => "not_a_repository"} =
             Git.availability(plain)

    linked = Path.join(dir, "gitfile")
    File.mkdir_p!(linked)
    File.write!(Path.join(linked, ".git"), "gitdir: /somewhere/else\n")

    assert {:error, %Error{code: "git_unavailable", details: ["git_dir_refused"]}} =
             Git.open(linked)

    symlinked = Path.join(dir, "gitlink")
    File.mkdir_p!(symlinked)
    File.ln_s!(Path.join(dir, "elsewhere"), Path.join(symlinked, ".git"))

    assert {:error, %Error{code: "git_unavailable", details: ["git_dir_refused"]}} =
             Git.open(symlinked)

    missing = %Git{root: repository(dir), executable: Path.join(dir, "no-such-git")}

    assert {:error, %Error{code: "git_unavailable", details: ["spawn_failed"]}} =
             Git.rev_parse(missing, ["HEAD"])
  end

  test "the environment is cleared and the null device replaces config", %{tmp_dir: dir} do
    root = repository(dir)
    dump = Path.join(dir, "env")
    fake = Path.join(dir, "env-git")
    File.write!(fake, "#!/bin/sh\nenv > #{dump}\necho $@ >> #{dump}\n")
    File.chmod!(fake, 0o755)
    System.put_env("OLIVIUM_TEST_LEAK", "secret-value")

    assert {:ok, _} = Git.rev_parse(%Git{root: root, executable: fake}, ["HEAD"])

    captured = File.read!(dump)
    refute captured =~ "OLIVIUM_TEST_LEAK"
    assert captured =~ "GIT_CONFIG_GLOBAL=/dev/null"
    assert captured =~ "GIT_CONFIG_SYSTEM=/dev/null"
    assert captured =~ "core.fsmonitor=false"
    assert captured =~ "protocol.allow=never"
  end

  test "file helpers refuse symlink escapes and non-regular files", %{tmp_dir: dir} do
    root = repository(dir)
    outside = Path.join(dir, "outside.txt")
    File.write!(outside, "secret\n")
    File.mkdir_p!(Path.join(root, "sub"))

    File.ln_s!(outside, Path.join(root, "absolute"))
    File.ln_s!("../outside.txt", Path.join(root, "relative"))
    File.ln_s!("../../outside.txt", Path.join(root, "sub/deep"))
    File.ln_s!("app.txt", Path.join(root, "inner"))
    File.ln_s!("sub", Path.join(root, "dirlink"))
    File.ln_s!(".git/config", Path.join(root, "gitconfig"))
    File.ln_s!("loop-b", Path.join(root, "loop-a"))
    File.ln_s!("loop-a", Path.join(root, "loop-b"))

    assert {:ok, "two\n"} = Git.read_file(root, "inner")
    assert {:ok, "two\n"} = Git.read_file(root, "app.txt")
    assert {:ok, _} = Git.safe_path(root, "dirlink")

    for path <- ~w(absolute relative sub/deep gitconfig loop-a .git/config .GIT/config) do
      assert {:error, %Error{code: "path_outside_repository"}} = Git.safe_path(root, path), path
    end

    for path <- ["/etc/passwd", "../outside.txt", "sub/../../outside.txt", "~/x"] do
      assert {:error, %Error{code: "path_outside_repository"}} = Git.safe_path(root, path), path
    end

    assert {:error, %Error{code: "path_not_found"}} = Git.safe_path(root, "nope")
    assert {:error, %Error{code: "unreadable_file"}} = Git.read_file(root, "sub")
    assert {:error, %Error{code: "file_too_large"}} = Git.read_file(root, "app.txt", max_bytes: 1)

    {_, 0} = System.cmd("mkfifo", [Path.join(root, "fifo")])
    assert {:error, %Error{code: "unreadable_file"}} = Git.read_file(root, "fifo")
  end

  test "the same repository state yields the same results", %{tmp_dir: dir} do
    assert {:ok, repo} = Git.open(repository(dir))
    args = ["--format=%H %at %s", "--numstat", "--date=iso-strict"]
    assert Git.log(repo, args) == Git.log(repo, args)
  end
end
