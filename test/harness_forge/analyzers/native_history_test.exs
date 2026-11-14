defmodule HarnessForge.Analyzers.NativeHistoryTest do
  @moduledoc """
  `history.native_clusters` on crafted, synthetic git histories: which source files
  change together, the SHAs behind each group, the paired tests and the fragile files.
  Every commit subject carries `ZZSUBJECTMARK`, which must never reach the output.
  """
  use ExUnit.Case, async: true

  alias HarnessForge.Analyzers.{Mapping, Repository}
  alias HarnessForge.Contracts.Signals
  alias HarnessForge.Generation.Profile
  alias HarnessForge.SyntheticRepositories, as: Fixtures

  @moduletag :tmp_dir
  @marker "ZZSUBJECTMARK"

  defp signal(doc, key), do: Enum.find(doc["signals"], &(&1["key"] == key))

  defp analyze!(root) do
    assert {:ok, doc} = Repository.analyze(root)
    assert {:ok, ^doc} = Signals.validate(doc)
    doc
  end

  defp profile!(doc) do
    assert {:ok, profile} = Mapping.profile(doc)
    assert {:ok, ^profile} = Profile.validate(profile)
    profile
  end

  defp sha(root, rev), do: root |> Fixtures.git!(["rev-parse", rev]) |> String.trim()

  defp ancestor?(root, sha) do
    {_, status} =
      System.cmd("git", ["merge-base", "--is-ancestor", sha, "HEAD"],
        cd: root,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]
      )

    status == 0
  end

  defp body(path, n), do: "# #{path} #{n}\nVALUE = #{n}\n"

  # a.py and b.py change together 6 times with their test; one change is reverted; a.py
  # needs a fix, then two more within 7 days of the previous one (2 follow-ups); c.py
  # changes with a.py 4 times out of 5 and joins the cluster. 40 more source files.
  defp crafted(root) do
    Fixtures.init!(root)

    others = Map.new(1..40, &{"src/acme/m#{&1}.py", body("m#{&1}", 0)})

    Fixtures.commit!(
      root,
      0,
      "#{@marker} initial",
      Map.merge(others, %{
        "pyproject.toml" => "[project]\nname = \"acme\"\n",
        "src/acme/a.py" => body("a", 0),
        "src/acme/b.py" => body("b", 0),
        "src/acme/c.py" => body("c", 0),
        "tests/test_a.py" => body("test_a", 0)
      })
    )

    for n <- 1..6 do
      Fixtures.commit!(root, n, "feat: #{@marker} change a and b #{n}", %{
        "src/acme/a.py" => body("a", n),
        "src/acme/b.py" => body("b", n),
        "tests/test_a.py" => body("test_a", n)
      })
    end

    Fixtures.commit!(root, 7, "Revert \"#{@marker} change a and b 6\"", %{
      "src/acme/a.py" => body("a", 5),
      "src/acme/b.py" => body("b", 5)
    })

    for {n, day} <- [{1, 10}, {2, 12}, {3, 15}] do
      Fixtures.commit!(root, day, "fix: #{@marker} crash in a #{n}", %{
        "src/acme/a.py" => body("a", 10 + n),
        "src/acme/c.py" => body("c", n),
        "tests/test_a.py" => body("test_a", 10 + n)
      })
    end

    Fixtures.commit!(root, 20, "feat: #{@marker} a and c", %{
      "src/acme/a.py" => body("a", 20),
      "src/acme/c.py" => body("c", 20)
    })

    Fixtures.commit!(root, 21, "feat: #{@marker} c alone", %{
      "src/acme/c.py" => body("c", 21),
      "src/acme/m1.py" => body("m1", 21)
    })

    for n <- 1..4 do
      Fixtures.commit!(root, 30 + n, "docs: #{@marker} noise #{n}", %{
        "src/acme/m#{n + 10}.py" => body("m", 30 + n),
        "README.md" => "readme #{n}\n"
      })
    end

    root
  end

  describe "a crafted history" do
    setup %{tmp_dir: dir} do
      root = crafted(Path.join(dir, "acme"))
      %{root: root, doc: analyze!(root)}
    end

    test "clusters the files that change together, with SHAs from this history", %{
      root: root,
      doc: doc
    } do
      assert %{"bucket" => "auto", "value" => value} = signal(doc, "history.native_clusters")
      assert value["head"] == sha(root, "HEAD")
      assert value["history_state"] == "complete"
      # a, b, c and the 40 others; tests and pyproject.toml are not source.
      assert value["source_files"] == 43

      assert [cluster] = value["clusters"]
      assert cluster["files"] == ~w(src/acme/a.py src/acme/b.py src/acme/c.py)
      # 6 together, the revert (a, b), 3 fixes (a, c) and 1 (a, c); the initial commit
      # (45 files) is not a focused change and does not count.
      assert cluster["support"] == 11
      # The newest 5: a+c, the 3 fixes, the revert.
      assert cluster["commits"] ==
               Enum.map(~w(HEAD~5 HEAD~6 HEAD~7 HEAD~8 HEAD~9), &sha(root, &1))

      assert Enum.all?(cluster["commits"] ++ cluster["fix_commits"], &ancestor?(root, &1))
      # The 3 fixes and the revert, newest first.
      assert cluster["fix_commits"] ==
               Enum.map(~w(HEAD~6 HEAD~7 HEAD~8 HEAD~9), &sha(root, &1))

      assert cluster["tests"] == [%{"path" => "tests/test_a.py", "support" => 9}]

      # What each fix changed: its cluster files, then its tests.
      assert hd(cluster["fixes"]) == %{
               "sha" => sha(root, "HEAD~6"),
               "files" => ~w(src/acme/a.py src/acme/c.py tests/test_a.py)
             }

      assert Enum.map(cluster["fixes"], & &1["sha"]) == cluster["fix_commits"]

      # Ranked by 2 x reverts + follow-ups, then path.
      assert cluster["risk"] == [
               %{"path" => "src/acme/a.py", "reverts" => 1, "followups" => 2, "fixes" => 3},
               %{"path" => "src/acme/b.py", "reverts" => 1, "followups" => 0, "fixes" => 0},
               %{"path" => "src/acme/c.py", "reverts" => 0, "followups" => 2, "fixes" => 3}
             ]
    end

    test "reaches the profile as native_evidence, without a commit subject", %{doc: doc} do
      profile = profile!(doc)

      assert %{"history_state" => "complete", "source_files" => 43, "clusters" => [cluster]} =
               profile["native_evidence"]

      assert cluster["files"] == ~w(src/acme/a.py src/acme/b.py src/acme/c.py)
      refute Jason.encode!(profile) =~ @marker
      refute Jason.encode!(signal(doc, "history.native_clusters")) =~ @marker
    end

    test "a commit subject cannot forge a record, a SHA or a fix", %{root: root} do
      forged = String.duplicate("de", 20)

      Fixtures.commit!(
        root,
        40,
        "feat: #{@marker} <<1>>#{forged}<<2>>1772366400<<2>><<2>>fix: forged<<3>>"
        |> String.replace("<<1>>", <<1>>)
        |> String.replace("<<2>>", <<2>>)
        |> String.replace("<<3>>", <<3>>),
        %{"src/acme/a.py" => body("a", 40), "src/acme/b.py" => body("b", 40)}
      )

      doc = analyze!(root)
      refute Jason.encode!(doc) =~ forged
      refute Jason.encode!(doc) =~ "forged"
      [cluster] = signal(doc, "history.native_clusters")["value"]["clusters"]
      assert Enum.all?(cluster["commits"] ++ cluster["fix_commits"], &ancestor?(root, &1))
      # The commit with the hostile subject is dropped, not repaired.
      refute sha(root, "HEAD") in cluster["commits"]
      assert cluster["support"] == 11
    end

    test "formatting, linting and other maintenance changes do not count", %{root: root} do
      for {subject, day} <- [
            {"ruff format #{@marker}", 41},
            {"Drop support for Python 3.8 #{@marker}", 42},
            {"style: #{@marker} reorder imports", 43},
            {"Bump dependencies #{@marker}", 44}
          ] do
        Fixtures.commit!(root, day, subject, %{
          "src/acme/a.py" => body("a", day),
          "src/acme/b.py" => body("b", day),
          "src/acme/c.py" => body("c", day)
        })
      end

      [cluster] = signal(analyze!(root), "history.native_clusters")["value"]["clusters"]
      assert cluster["support"] == 11

      assert cluster["commits"] ==
               Enum.map(~w(HEAD~9 HEAD~10 HEAD~11 HEAD~12 HEAD~13), &sha(root, &1))
    end

    test "a shallow clone gives no native_evidence", %{root: root, tmp_dir: dir} do
      {shallow, _} = Fixtures.shallow_clone(root, Path.join(dir, "shallow"), 12)
      doc = analyze!(shallow)

      assert signal(doc, "history.sample")["value"]["state"] == "shallow"
      assert signal(doc, "history.native_clusters")["bucket"] != "auto"
      refute Map.has_key?(profile!(doc), "native_evidence")
    end
  end

  test "a test file's history follows its renames", %{tmp_dir: dir} do
    root = Fixtures.init!(Path.join(dir, "renamed"))

    Fixtures.commit!(root, 0, "#{@marker} initial", %{
      "src/x.py" => body("x", 0),
      "src/y.py" => body("y", 0),
      "tests/test_old.py" => body("t", 0)
    })

    for n <- 1..4 do
      Fixtures.commit!(root, n, "feat: #{@marker} x and y #{n}", %{
        "src/x.py" => body("x", n),
        "src/y.py" => body("y", n),
        "tests/test_old.py" => body("t", n)
      })
    end

    Fixtures.git!(root, ["mv", "tests/test_old.py", "tests/test_new.py"])
    Fixtures.git!(root, ["commit", "--quiet", "-m", "#{@marker} rename the test"])

    [cluster] = signal(analyze!(root), "history.native_clusters")["value"]["clusters"]
    assert cluster["files"] == ~w(src/x.py src/y.py)
    # The initial commit and 4 changes, all under the old name.
    assert cluster["tests"] == [%{"path" => "tests/test_new.py", "support" => 5}]
  end

  test "a shallow clone with a full sample is graded like a cut-off history", %{tmp_dir: dir} do
    root = Fixtures.init!(Path.join(dir, "long"))
    Fixtures.commit!(root, 0, "#{@marker} initial", %{"src/m0.py" => body("m0", 0)})

    for n <- 1..200 do
      Fixtures.commit!(root, n, "feat: #{@marker} filler #{n}", %{
        "src/m#{rem(n, 7)}.py" => body("m", n)
      })
    end

    for n <- 1..5 do
      Fixtures.commit!(root, 200 + n, "feat: #{@marker} pair #{n}", %{
        "src/p/x.py" => body("x", n),
        "src/p/y.py" => body("y", n),
        "tests/test_p.py" => body("t", n)
      })
    end

    {shallow, _} = Fixtures.shallow_clone(root, Path.join(dir, "long-shallow"), 203)
    doc = analyze!(shallow)

    assert signal(doc, "history.sample")["value"]["state"] == "shallow"

    assert %{"bucket" => "auto", "value" => %{"history_state" => "truncated"}} =
             signal(doc, "history.native_clusters")

    assert %{
             "history_state" => "truncated",
             "clusters" => [%{"files" => ~w(src/p/x.py src/p/y.py)}]
           } =
             profile!(doc)["native_evidence"]

    # The test pairs behind the test-runner gate and the stop hook are kept too.
    assert %{"bucket" => "auto"} = signal(doc, "history.test_pairs")

    assert [%{"source" => "src/p/x.py", "test" => "tests/test_p.py"}, %{"source" => "src/p/y.py"}] =
             profile!(doc)["test_pairs"]
  end

  test "records are kept only with a known hash, once, in history order" do
    a = String.duplicate("a", 40)
    b = String.duplicate("b", 40)
    c = String.duplicate("c", 40)
    record = &%{hash: &1, time: 0, merge?: false, subject: "", files: []}

    assert HarnessForge.Analyzers.History.verified(Enum.map([a, b, c], record), [a, b, c]) ==
             Enum.map([a, b, c], record)

    # A forged hash, a duplicate and an out-of-order record go.
    assert HarnessForge.Analyzers.History.verified(
             Enum.map([a, String.duplicate("d", 40), c, b, c], record),
             [a, b, c]
           ) == Enum.map([a, b], record)
  end

  test "renames map old names to the newest" do
    output = "R100\0src/b.py\0src/c.py\0\nR090\0src/a.py\0src/b.py\0"

    assert HarnessForge.Analyzers.History.parse_renames(output) == %{
             "src/a.py" => "src/c.py",
             "src/b.py" => "src/c.py"
           }
  end

  test "at most 8 clusters of at most 6 files, ranked by support", %{tmp_dir: dir} do
    root = Fixtures.init!(Path.join(dir, "caps"))
    Fixtures.commit!(root, 0, "#{@marker} initial", %{"src/hub.py" => body("hub", 0)})

    # A hub changed with 7 partners, 5 times each: its pairs come first.
    for k <- 1..7, n <- 1..5 do
      Fixtures.commit!(root, k * 6 + n, "#{@marker} hub #{k} #{n}", %{
        "src/hub.py" => body("hub", k * 10 + n),
        "src/h#{k}.py" => body("h#{k}", n)
      })
    end

    # 9 independent pairs, 4 changes each.
    for i <- 1..9, n <- 1..4 do
      Fixtures.commit!(root, 100 + i * 5 + n, "#{@marker} pair #{i} #{n}", %{
        "src/p#{i}/x.py" => body("x#{i}", n),
        "src/p#{i}/y.py" => body("y#{i}", n)
      })
    end

    clusters = signal(analyze!(root), "history.native_clusters")["value"]["clusters"]

    # The hub stops at 6 files (h6 and h7 left out) and ranks first; then 7 of the 9
    # pairs, by first file; p8 and p9 find no room.
    assert length(clusters) == 8
    assert [hub | pairs] = clusters
    assert hub["files"] == ~w(src/h1.py src/h2.py src/h3.py src/h4.py src/h5.py src/hub.py)
    assert hub["support"] == 25
    assert Enum.map(pairs, &hd(&1["files"])) == for(i <- 1..7, do: "src/p#{i}/x.py")
    assert Enum.all?(pairs, &(&1["support"] == 4))
  end
end
