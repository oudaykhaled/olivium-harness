defmodule HarnessForge.Privacy.PurgeGeneratedPackageTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Evidence, Generation, Privacy}

  test "a generated package does not stop a source from being purged" do
    root = Path.join(System.tmp_dir!(), "purge-generated-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, connection} =
      Evidence.connect(%{"name" => "Synthetic", "provider" => "local", "directory" => root})

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "a.md",
        "title" => "Synthetic",
        "body" => "Synthetic body for the purge check."
      })

    profile =
      Path.expand("../../../examples/profiles/elixir_project.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, %{"counts" => %{"rules" => rules}}} =
             Generation.generate(%{"profile" => profile})

    assert rules > 0
    assert {:ok, _} = Privacy.purge_source(source["id"], source["id"])
  end
end
