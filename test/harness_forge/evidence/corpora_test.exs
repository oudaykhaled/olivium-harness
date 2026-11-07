defmodule HarnessForge.Evidence.CorporaTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Evidence, Repo}
  alias HarnessForge.Evidence.{Corpora, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "corpora-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Generic public documents",
        "provider" => "local",
        "directory" => root
      })

    %{connection: connection, caller: caller()}
  end

  test "strict server authorization and string-keyed boundaries", %{caller: caller} do
    assert {:error, :operator_session_revoked} =
             Corpora.create(
               %{"name" => "Public"},
               Keyword.put(caller, :authorize, fn -> false end)
             )

    assert {:error, :invalid_input} = Corpora.create(%{name: "Public"}, caller)

    assert {:error, :invalid_input} =
             Corpora.create(%{"name" => "Public", "workspace_id" => Store.workspace()}, caller)

    assert {:ok, corpus} = Corpora.create(%{"name" => "Public"}, caller)
    assert corpus["semantic_generation"] == 0
  end

  test "relational membership exceeds the old array cap and no-op replay is stable", %{
    connection: connection,
    caller: caller
  } do
    {:ok, corpus} = Corpora.create(%{"name" => "Generic"}, caller)

    changes =
      Enum.map(1..101, fn number ->
        {:ok, source} =
          Evidence.import_markdown(connection["id"], %{
            "external_id" => "#{number}.md",
            "title" => "Document #{number}",
            "body" => "Public botanical record #{number}."
          })

        %{
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "action" => "include"
        }
      end)

    assert {:ok, first} = Corpora.apply_members(corpus["id"], 0, Enum.take(changes, 100), caller)

    assert {:ok, final} =
             Corpora.apply_members(
               corpus["id"],
               first["semantic_generation"],
               Enum.drop(changes, 100),
               caller
             )

    assert {:ok, unchanged} =
             Corpora.apply_members(
               corpus["id"],
               final["semantic_generation"],
               [List.last(changes)],
               caller
             )

    assert unchanged["semantic_generation"] == final["semantic_generation"]

    assert [[101]] =
             Repo.query!("SELECT count(*) FROM corpus_members WHERE corpus_id=?", [corpus["id"]]).rows

    assert {:ok, page} = Corpora.members(corpus["id"], %{}, caller)
    assert length(page["rows"]) == 25
    assert is_binary(page["next_cursor"])

    assert {:ok, second} =
             Corpora.members(corpus["id"], %{"cursor" => page["next_cursor"]}, caller)

    refute hd(page["rows"])["source_id"] == hd(second["rows"])["source_id"]
  end

  test "generation change invalidates previous eligibility without changing citations", %{
    connection: connection,
    caller: caller
  } do
    {:ok, corpus} = Corpora.create(%{"name" => "Generic"}, caller)

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "record.md",
        "title" => "Record",
        "body" => "Public garden schedule."
      })

    {:ok, current} =
      Corpora.apply_members(
        corpus["id"],
        0,
        [
          %{
            "source_id" => source["id"],
            "revision_id" => source["latest_revision"]["id"],
            "action" => "include"
          }
        ],
        caller
      )

    assert :ok = Corpora.assert_current(corpus["id"], current["semantic_generation"], 0)
    assert :ok = Corpora.invalidate_source(source["id"], :metadata_changed)

    assert {:error, :stale_generation} =
             Corpora.assert_current(corpus["id"], current["semantic_generation"], 0)
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("generic caller"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
end
