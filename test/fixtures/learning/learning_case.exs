defmodule HarnessForge.LearningCase do
  @moduledoc """
  Synthetic helpers for the learning tests: a stub learner (no Docker, no model) and a
  stub verification runner. Everything here is generated; no third-party text.
  """

  alias HarnessForge.SyntheticRepositories, as: Repositories

  @doc "Commit subjects to full hashes for the repository at `root`."
  def hashes(root) do
    root
    |> Repositories.git!(["log", "--format=%H %s"])
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [hash, subject] = String.split(line, " ", parts: 2)
      {subject, hash}
    end)
  end

  @doc """
  A Python project (`SyntheticRepositories.python_project/1`) plus one commit on a side
  branch that HEAD does not reach. Returns `{root, side_hash}`.
  """
  def repository(root) do
    Repositories.python_project(root)
    Repositories.git!(root, ["checkout", "--quiet", "-b", "side"])

    Repositories.commit!(root, 40, "Fix parsing of later widgets", %{
      "src/acme_widgets/parser.py" => "VALUE = 40\n"
    })

    side = root |> Repositories.git!(["rev-parse", "HEAD"]) |> String.trim()
    Repositories.git!(root, ["checkout", "--quiet", "main"])
    {root, side}
  end

  @doc "A raw learner output for the synthetic repository at `root`."
  def raw(root, side, overrides \\ %{}) do
    h = hashes(root)
    parsing = h["Fix crash when parsing an empty widget"]
    validation = h["Fix validation of nested fields"]
    header = h["Fix header encoding"]
    cache = h["Fix leak in the cache"]
    eviction = h["Fix cache eviction order"]
    timeout = h["Fix wrong default timeout"]

    Map.merge(
      %{
        "concepts" => [
          %{
            "id" => "c1",
            "terms" => ["parsing", "validation", "header"],
            "paths" => ["src/acme_widgets/parser.py"],
            "symbols" => ["VALUE", "NoSuchSymbol"],
            "tests" => ["tests/test_parser.py"],
            "evidence" => [parsing, validation, header]
          },
          %{
            "id" => "c2",
            "terms" => ["cache"],
            "paths" => ["src/acme_widgets/missing.py"],
            "evidence" => [cache, eviction]
          },
          %{
            "id" => "c3",
            "terms" => ["parsing"],
            "paths" => ["src/acme_widgets/parser.py"],
            "evidence" => [parsing, side]
          },
          %{
            "id" => "c4",
            "terms" => ["cache"],
            "paths" => ["src/acme_widgets/parser.py"],
            "evidence" => [cache, eviction]
          },
          %{
            "id" => "c5",
            "terms" => ["header", "validation", "parsing"],
            "paths" => ["src/acme_widgets/parser.py"],
            "evidence" => [parsing, validation]
          },
          %{
            "id" => "c6",
            "terms" => ["cache"],
            "paths" => ["src/acme_widgets/cache.py"],
            "evidence" => [cache, String.duplicate("ab", 20)]
          }
        ],
        "pitfalls" => [
          %{
            "id" => "p1",
            "scope" => "global",
            "concept" => nil,
            "kind" => "changelog",
            "text" => "Every fix adds a line to CHANGES.md describing the change.",
            "trigger_terms" => [],
            "evidence" => [parsing, validation, header],
            "check" => %{"pattern" => "- change [0-9]+", "min_commits" => 3}
          },
          %{
            "id" => "p2",
            "scope" => "concept",
            "concept" => "c1",
            "kind" => "test_location",
            "text" => "Parser fixes come with a test in tests/test_parser.py.",
            "trigger_terms" => ["parser"],
            # In 3 of the 12 fix commits: specific enough (at most a quarter).
            "evidence" => [parsing, cache],
            "check" => %{"pattern" => "def test_case", "min_commits" => 2}
          },
          %{
            "id" => "p3",
            "scope" => "global",
            "concept" => nil,
            "kind" => "docs",
            "text" => "Read the guide at https://example.invalid/guide first.",
            "trigger_terms" => [],
            "evidence" => [parsing, validation, header],
            "check" => %{"pattern" => "change", "min_commits" => 2}
          },
          %{
            "id" => "p4",
            "scope" => "global",
            "concept" => nil,
            "kind" => "other",
            "text" => "Two commits are not enough evidence for a global rule.",
            "trigger_terms" => [],
            "evidence" => [parsing, validation],
            "check" => %{"pattern" => "change", "min_commits" => 2}
          },
          %{
            "id" => "p5",
            "scope" => "global",
            "concept" => nil,
            "kind" => "typing",
            "text" => "This pattern does not appear in the cited fixes at all.",
            "trigger_terms" => [],
            "evidence" => [parsing, validation, header],
            "check" => %{"pattern" => "TypeAlias", "min_commits" => 2}
          },
          %{
            "id" => "p6",
            "scope" => "concept",
            "concept" => "c1",
            "kind" => "test_location",
            "text" => "Every parser fix changes an assert line in the tests.",
            "trigger_terms" => ["parser"],
            # In all 12 fix commits: says nothing about this rule.
            "evidence" => [parsing, validation],
            "check" => %{"pattern" => "assert", "min_commits" => 2}
          },
          %{
            "id" => "p7",
            "scope" => "global",
            "concept" => nil,
            "kind" => "deprecation",
            # The learner prompt's own example, word for word.
            "text" =>
              "Keep removed public names working and warn with DeprecationWarning; tests use pytest.deprecated_call.",
            "trigger_terms" => [],
            "evidence" => [parsing, validation, header],
            "check" => %{"pattern" => "- change [0-9]+", "min_commits" => 3}
          },
          %{
            "id" => "p8",
            "scope" => "global",
            "concept" => nil,
            "kind" => "typing",
            # mypy is missing in the stub verification image.
            "text" => "Type changes are checked by strict mypy, so run mypy after editing types.",
            "trigger_terms" => [],
            "evidence" => [parsing, cache, timeout],
            "check" => %{"pattern" => "def test_case", "min_commits" => 3}
          }
        ],
        "commands" => [
          %{"role" => "test_file", "argv" => ["uv", "run", "pytest", "-q", "{file}"]},
          %{"role" => "test", "argv" => ["sh", "-c", "pytest"]},
          %{"role" => "lint", "argv" => ["rm", "-rf", "build"]},
          %{"role" => "typecheck", "argv" => ["uv", "run", "pyright", "{file}"]}
        ],
        "rewrites" => [
          %{
            "kind" => "quiet_flags",
            "match" => %{"argv_prefix" => ["uv", "run", "pytest"]},
            "replace" => %{"argv_prefix" => ["uv", "run", "pytest", "-q"]}
          },
          %{
            "kind" => "missing_tool",
            "match" => %{"argv_prefix" => ["uv", "run", "mypy"]},
            "replace" => %{"message_id" => "tool_missing", "tool" => "mypy"}
          },
          %{
            "kind" => "wrong_runner",
            "match" => %{"argv_prefix" => ["curl"]},
            "replace" => %{"argv_prefix" => ["uv", "run", "curl"]}
          }
        ]
      },
      overrides
    )
  end

  @doc """
  `raw/3` plus proposed skills and agents (learner prompt v2). Expected: skill s1 and
  agents a1 (test_runner) and a3 (locator) kept; s2 path_missing_at_base, s3
  evidence_after_base, s4 evidence_missing, s5 evidence_mismatch, s6 schema_invalid (its
  concept was dropped), s7 over_limit (only 6 are considered); a2 not_verified (no
  typecheck command is verified), a4 over_limit (a second locator).
  """
  def native_raw(root, side) do
    h = hashes(root)
    parsing = h["Fix crash when parsing an empty widget"]
    validation = h["Fix validation of nested fields"]
    cache = h["Fix leak in the cache"]
    eviction = h["Fix cache eviction order"]
    timeout = h["Fix wrong default timeout"]
    pagination = h["Fix pagination off by one"]
    parser = "src/acme_widgets/parser.py"
    client = "src/acme_widgets/client.py"

    skill = fn overrides ->
      Map.merge(
        %{
          "kind" => "area",
          "concept" => "c1",
          "slug" => "parser",
          "paths" => [parser, client],
          "tests" => ["tests/test_parser.py"],
          "symbols" => [],
          "pitfalls" => [],
          "evidence" => [parsing, validation]
        },
        overrides
      )
    end

    raw(root, side, %{
      "skills" => [
        skill.(%{
          "id" => "s1",
          "symbols" => ["parse_widget", "NoSuchSymbol"],
          "pitfalls" => ["p2"]
        }),
        skill.(%{
          "id" => "s2",
          "slug" => "missing",
          "paths" => [parser, "src/acme_widgets/missing.py"]
        }),
        skill.(%{"id" => "s3", "slug" => "later", "evidence" => [parsing, side]}),
        skill.(%{
          "id" => "s4",
          "slug" => "unknown",
          "evidence" => [parsing, String.duplicate("ab", 20)]
        }),
        skill.(%{
          "id" => "s5",
          "slug" => "cache",
          "paths" => ["src/acme_widgets/cache.py", "src/acme_widgets/__init__.py"],
          "tests" => []
        }),
        skill.(%{"id" => "s6", "slug" => "dropped-concept", "concept" => "c2"}),
        skill.(%{"id" => "s7", "slug" => "seventh"})
      ],
      "agents" => [
        %{
          "id" => "a1",
          "kind" => "test_runner",
          "paths" => ["tests/test_parser.py", parser],
          "commands" => ["cmd-test-file", "cmd-test"],
          "evidence" => [parsing, validation]
        },
        %{
          "id" => "a2",
          "kind" => "test_runner",
          "paths" => [client],
          "commands" => ["cmd-typecheck"],
          "evidence" => [timeout, pagination]
        },
        %{
          "id" => "a3",
          "kind" => "locator",
          "paths" => [parser, client],
          "commands" => [],
          "evidence" => [parsing, timeout]
        },
        %{
          "id" => "a4",
          "kind" => "locator",
          "paths" => ["src/acme_widgets/cache.py"],
          "commands" => [],
          "evidence" => [cache, eviction]
        }
      ]
    })
  end

  @doc "A launcher stub that returns `raw` as the learner's file, with fixed usage."
  def launcher(raw) do
    fn spec ->
      send(self(), {:launcher_spec, Map.drop(spec, [:extract, :ctx])})

      %{
        status: if(spec.mode == :mock, do: "mock", else: "ok"),
        reason: "none",
        raw: raw,
        requests: 2,
        tokens: %{"input" => 1000, "output" => 200, "cache_read" => 0, "cache_write" => 0},
        cost_nanousd: 0,
        wall_ms: 1234,
        transcript: ~s({"type":"result","subtype":"success"}\n),
        report: %{"stub" => true}
      }
    end
  end

  @image_id "sha256:" <> String.duplicate("0", 64)

  @doc """
  A verification runner stub: mypy is missing, pyright needs the network, -q is quiet,
  and `--collect-nothing` exits 0 having run no test.
  """
  def runner(availability \\ {:ok, @image_id}) do
    fn
      :availability, _image ->
        availability

      :repo_mode, _ ->
        :copy

      :probe, %{forms: forms} ->
        Enum.map(forms, &result/1)

      :run, %{argv: argv} ->
        result(argv)
    end
  end

  defp result(argv) do
    cond do
      "mypy" in argv ->
        %{exit: 127, bytes: 20, signature: "exit_127", network: 0, ms: 5}

      "pyright" in argv ->
        %{exit: 1, bytes: 80, signature: "none", network: 1, ms: 5}

      "--collect-nothing" in argv ->
        %{exit: 0, bytes: 30, signature: "none", network: 0, ms: 5, zero_tests: 1}

      "-q" in argv ->
        %{exit: 0, bytes: 100, signature: "none", network: 0, ms: 5}

      true ->
        %{exit: 0, bytes: 1000, signature: "none", network: 0, ms: 5}
    end
  end
end
