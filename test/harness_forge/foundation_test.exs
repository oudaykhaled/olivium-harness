defmodule HarnessForge.FoundationTest do
  use HarnessForge.DataCase, async: false
  use Oban.Testing, repo: HarnessForge.Repo, engine: Oban.Engines.Lite

  defmodule ProbeWorker do
    use Oban.Worker, queue: :default, max_attempts: 1

    @impl true
    def perform(%Oban.Job{args: %{"probe" => true}}), do: :ok
  end

  test "the packaged SQLite driver supports FTS5" do
    Repo.query!("CREATE VIRTUAL TABLE foundation_fts_probe USING fts5(content)")
    Repo.query!("INSERT INTO foundation_fts_probe(content) VALUES (?)", ["approved evidence"])

    assert %{rows: [["approved evidence"]]} =
             Repo.query!(
               "SELECT content FROM foundation_fts_probe WHERE foundation_fts_probe MATCH ?",
               ["evidence"]
             )
  end

  test "Oban Lite persists jobs and supports deterministic manual execution" do
    assert Oban.config().engine == Oban.Engines.Lite
    assert {:ok, %Oban.Job{id: id}} = Oban.insert(ProbeWorker.new(%{"probe" => true}))
    assert is_integer(id)
    assert_enqueued(worker: ProbeWorker, args: %{"probe" => true})
    assert :ok = perform_job(ProbeWorker, %{"probe" => true})
  end
end
