Code.require_file("../../fixtures/learning/learning_case.exs", __DIR__)

defmodule HarnessForge.Learning.ExtractTest do
  use ExUnit.Case, async: true

  alias HarnessForge.Learning.Extract
  alias HarnessForge.LearningCase
  alias HarnessForge.SyntheticRepositories, as: Repositories

  setup do
    root = Path.join(System.tmp_dir!(), "hf-learn-extract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {repo, side} = LearningCase.repository(Path.join(root, "widgets"))
    {:ok, repo: repo, side: side}
  end

  test "the extract is byte-identical across runs and reads HEAD only", %{repo: repo, side: side} do
    assert {:ok, first} = Extract.build(repo)
    assert {:ok, second} = Extract.build(repo)
    assert first.json == second.json
    assert first.sha256 == second.sha256
    assert Extract.digest!(repo) == first.sha256
    assert first.bytes == byte_size(first.json)
    assert first.bytes <= Extract.max_bytes()

    head = repo |> Repositories.git!(["rev-parse", "HEAD"]) |> String.trim()
    doc = first.doc
    assert doc["version"] == "history-extract/v1"
    assert doc["repository"]["base_commit"] == head
    assert doc["repository"]["name"] == "widgets"

    hashes = Enum.map(doc["commits"], & &1["hash"])
    assert head in hashes
    refute side in hashes
    refute Map.has_key?(first.commits, side)

    # The side-branch commit exists but is not an ancestor of HEAD.
    assert Extract.commit_exists?(first, side)
    refute MapSet.member?(Extract.ancestors(first), side)
    assert MapSet.member?(Extract.ancestors(first), head)
  end

  test "fix commits are marked and their diffs kept", %{repo: repo} do
    {:ok, extract} = Extract.build(repo)
    fixes = Enum.filter(extract.doc["commits"], & &1["fix"])
    assert length(fixes) >= 10
    assert extract.doc["fix_diffs"] != []

    [first | _] = extract.doc["fix_diffs"]
    assert Enum.any?(first["lines"], &String.starts_with?(&1, "--- "))
    assert Enum.any?(first["lines"], &String.starts_with?(&1, "@@ "))

    hash = LearningCase.hashes(repo)["Fix crash when parsing an empty widget"]
    lines = Extract.changed_lines(extract, hash)
    assert "VALUE = 1" in lines
    assert "VALUE = 0" in lines
    assert "- change 1" in lines
  end

  test "no author identity or e-mail address appears in the extract or its views", %{repo: repo} do
    {:ok, extract} = Extract.build(repo)
    texts = [extract.json | Enum.map(Extract.views(extract), &elem(&1, 1))]

    for text <- texts do
      refute text =~ Repositories.author_name()
      refute text =~ Repositories.author_email()
    end

    assert Enum.map(Extract.views(extract), &elem(&1, 0)) == ~w(commits.txt fixes.txt facts.json)
  end

  test "facts list tox environments, CI run lines and named tools", %{repo: repo} do
    {:ok, extract} = Extract.build(repo)
    facts = extract.doc["facts"]
    assert "typing" in facts["tox_envs"]
    assert Enum.any?(facts["ci_runs"], &(&1["command"] =~ "tox run"))
    assert "mypy" in facts["pyproject_tools"]
  end

  test "a directory that is not a repository is refused", %{repo: repo} do
    plain = Path.join(Path.dirname(repo), "plain")
    File.mkdir_p!(plain)
    assert {:error, %{code: "git_unavailable"}} = Extract.build(plain)
  end
end
