defmodule HarnessForge.Test.LeanAiFixture do
  @moduledoc false
  # Shared by the lean-ai generation and adapter tests (compiled with test/support):
  # the shared synthetic bundle and a synthetic `LearnedRender.prepare/3` result.
  alias HarnessForge.Contracts

  @fixture Path.expand("../fixtures/learned/learned-v1.synthetic.json", __DIR__)

  def fixture_path, do: @fixture

  def fixture_doc do
    {:ok, doc} = @fixture |> File.read!() |> Contracts.decode_json()
    doc
  end

  def resign(doc), do: Map.put(doc, "sha256", Contracts.digest(Map.delete(doc, "sha256")))

  # What LearnedRender.prepare/3 returns for a repository, here synthetic: the shared
  # fixture bundle, a small file list, index rows and gate numbers.
  def prepared(overrides \\ %{}) do
    doc = Map.get(overrides, "bundle", fixture_doc())

    %{
      "bundle" => doc,
      "file_sha256" => Contracts.sha256(Contracts.canonical_json(doc) <> "\n"),
      "head" => doc["repository"]["base_commit"],
      "files" =>
        ~w(CHANGES.md pyproject.toml src/acme/__init__.py src/acme/layout.py src/acme/retry.py src/acme/widgets.py src/acme_widgets/api.py src/acme_widgets/models.py tests/conftest.py tests/test_api.py tests/test_layout.py tests/test_models.py tests/test_retry.py tests/test_widgets.py),
      "symbols" =>
        Enum.sort([
          "Layout\tsrc/acme/layout.py\t8\t40\tclass",
          "RetryPolicy\tsrc/acme/retry.py\t12\t58\tclass",
          "Widget\tsrc/acme/widgets.py\t10\t90\tclass",
          "backoff_delay\tsrc/acme/retry.py\t60\t75\tdef",
          "create_widget\tsrc/acme_widgets/api.py\t5\t30\tdef",
          "resize\tsrc/acme/widgets.py\t44\t70\tdef"
        ]),
      "terms" =>
        Enum.sort([
          "backoff\tsrc/acme/retry.py\t520\thistory",
          "jitter\tsrc/acme/retry.py\t610\thistory",
          "layout\tsrc/acme/layout.py\t480\thistory",
          "resize\tsrc/acme/widgets.py\t450\thistory",
          "widget\tsrc/acme/widgets.py\t300\thistory",
          "widget\tsrc/acme_widgets/api.py\t200\thistory"
        ]),
      "gate" => %{
        "status" => "passed",
        "replay_n" => 30,
        "top3_hits" => 21,
        "wrong" => 3,
        "max_card_bytes" => 412
      }
    }
    |> Map.merge(Map.delete(overrides, "bundle"))
  end
end
