defmodule HarnessForge.Evidence.PassagesTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Evidence, Repo}
  alias HarnessForge.Evidence.{Corpora, Passages, Store}

  test "UTF-8 core spans cover every original byte exactly once" do
    body = String.duplicate("Café 植物 🌱\n", 900)
    assert {:ok, chunks} = Passages.chunks(body)

    {finish, reconstructed} =
      Enum.reduce(chunks, {0, ""}, fn span, {position, acc} ->
        assert span["start_byte"] == position
        text = binary_part(body, position, span["end_byte"] - position)
        assert String.valid?(text)
        assert byte_size(text) <= 2048
        assert span["parent_end_byte"] - span["parent_start_byte"] <= 4096
        assert Store.hash(text) == span["snippet_hash"]
        {span["end_byte"], acc <> text}
      end)

    assert finish == byte_size(body)
    assert reconstructed == body
    assert {:ok, []} = Passages.chunks("")
    assert {:error, :binary_file} = Passages.chunks(<<255>>)
  end

  test "index publication is idempotent and exact reads reject forged spans" do
    directory = Path.join(System.tmp_dir!(), "passages-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{"name" => "Generic", "provider" => "local", "directory" => directory})

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "flowers.md",
        "title" => "Flowers",
        "body" => "Café flowers need water.\n"
      })

    {:ok, corpus} = Corpora.create(%{"name" => "Garden"}, caller())

    {:ok, _} =
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
        caller()
      )

    assert {:ok, indexed} = Passages.index_revision(source["latest_revision"]["id"])
    assert indexed["state"] == "ready"
    assert {:ok, same} = Passages.index_revision(source["latest_revision"]["id"])
    assert indexed["id"] == same["id"]

    assert [[1]] =
             Repo.query!("SELECT count(*) FROM passages WHERE passage_set_id=?", [indexed["id"]]).rows

    [[id]] = Repo.query!("SELECT id FROM passages WHERE passage_set_id=?", [indexed["id"]]).rows
    {:ok, envelope} = Passages.envelope(id)

    assert {:ok, actual} =
             Passages.read(
               id,
               Map.take(
                 envelope,
                 ~w(passage_id source_id revision_id body_hash start_byte end_byte snippet_hash parent_start_byte parent_end_byte parent_hash)
               ),
               caller()
             )

    assert actual["snippet"] == "Café flowers need water.\n"

    assert {:error, :invalid_passage} =
             Passages.read(id, Map.put(envelope, "start_byte", 1), caller())
  end

  test "lazy serving materializes one bounded SQL window rather than a full revision" do
    directory = Path.join(System.tmp_dir!(), "lazy-passage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{"name" => "Generic", "provider" => "local", "directory" => directory})

    body = String.duplicate("Public garden observations.\n", 20_000)

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "large.md",
        "title" => "Large public record",
        "body" => body
      })

    {:ok, indexed} = Passages.index_revision(source["latest_revision"]["id"])

    [[id]] =
      Repo.query!("SELECT id FROM passages WHERE passage_set_id=? ORDER BY ordinal LIMIT 1", [
        indexed["id"]
      ]).rows

    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, metadata, _ ->
          if String.contains?(metadata.query, "AS parent_window"),
            do: send(owner, {:window_query, metadata.result})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, passage} = Passages.envelope(id)
    assert byte_size(passage["parent_text"]) <= 4096
    assert byte_size(passage["snippet"]) <= 2048
    assert_receive {:window_query, {:ok, result}}
    assert "parent_window" in result.columns
    refute "body" in result.columns
    index = Enum.find_index(result.columns, &(&1 == "parent_window"))
    assert byte_size(result.rows |> hd() |> Enum.at(index)) <= 4096
  end

  test "paragraph-aware cores isolate a short final paragraph after long unrelated text" do
    prefix =
      String.duplicate(
        "Ordinary public garden observations without special qualifications. ",
        150
      ) <> "\n\n"

    final = "Greenhouse orchids use the documented seasonal schedule.\n"
    body = prefix <> final
    assert {:ok, chunks} = Passages.chunks(body)
    last = List.last(chunks)
    assert last["start_byte"] == byte_size(prefix)
    assert binary_part(body, last["start_byte"], last["end_byte"] - last["start_byte"]) == final
    assert last["parent_start_byte"] == byte_size(prefix)
    assert last["parent_end_byte"] == byte_size(body)

    assert Enum.map_join(chunks, fn span ->
             binary_part(body, span["start_byte"], span["end_byte"] - span["start_byte"])
           end) == body

    assert Passages.versions()["chunker"] == "utf8-parent-v2"
  end

  test "only actual paragraph boundaries prove completeness; overlong paragraphs stay incomplete" do
    directory =
      Path.join(System.tmp_dir!(), "paragraph-proof-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Generic paragraphs",
        "provider" => "local",
        "directory" => directory
      })

    for separator <- ["\n\n", "\r\n\r\n"] do
      prefix = String.duplicate("Long unrelated garden observation. ", 250) <> separator
      final = "Orchids have a short, independently inspectable final paragraph."

      {:ok, source} =
        Evidence.import_markdown(connection["id"], %{
          "external_id" => "#{byte_size(separator)}.md",
          "title" => "Generic paragraph boundaries",
          "body" => prefix <> final
        })

      {:ok, set} = Passages.index_revision(source["latest_revision"]["id"])

      [[last]] =
        Repo.query!(
          "SELECT id FROM passages WHERE passage_set_id=? ORDER BY ordinal DESC LIMIT 1",
          [set["id"]]
        ).rows

      [[first]] =
        Repo.query!("SELECT id FROM passages WHERE passage_set_id=? ORDER BY ordinal LIMIT 1", [
          set["id"]
        ]).rows

      assert {:ok, complete} = Passages.envelope(last)
      assert complete["snippet"] == final
      refute complete["parent_incomplete"]
      assert {:ok, incomplete} = Passages.envelope(first)
      assert incomplete["parent_incomplete"]
      assert byte_size(incomplete["parent_text"]) <= 4096
    end
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("passage caller"),
      view_generation: String.duplicate("b", 32),
      reset_token: 0
    ]
end
