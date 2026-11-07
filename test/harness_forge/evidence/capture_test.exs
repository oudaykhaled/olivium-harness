defmodule HarnessForge.Evidence.CaptureTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Evidence, Repo}
  alias HarnessForge.Evidence.{Capture, Corpora}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "capture-public-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Public files",
        "provider" => "local",
        "directory" => directory
      })

    {:ok, corpus} = Corpora.create(%{"name" => "Public garden archive"}, caller())
    %{directory: directory, connection: connection, corpus: corpus}
  end

  test "pause/resume/cancel use exact revisions and invalidate old leases", %{
    connection: connection,
    corpus: corpus
  } do
    {:ok, run} = Capture.start_capture(corpus["id"], connection["id"], 0, caller())
    assert {:ok, paused} = Capture.pause(run["run_id"], run["revision"], caller())
    assert {:error, :stale_revision} = Capture.resume(run["run_id"], run["revision"], caller())
    assert {:ok, resumed} = Capture.resume(run["run_id"], paused["revision"], caller())
    assert {:ok, cancelled} = Capture.cancel(run["run_id"], resumed["revision"], caller())
    assert {:ok, ^cancelled} = Capture.cancel(run["run_id"], resumed["revision"], caller())
    assert {:error, :cancelled} = Capture.check_lease(run["run_id"], "expired-token")
  end

  test "physical capture spans batches and replay does not duplicate revisions", %{
    directory: directory,
    connection: connection,
    corpus: corpus
  } do
    if Process.whereis(HarnessForge.Evidence.Capture.Scanner) == nil,
      do: start_supervised!({HarnessForge.Evidence.Capture.Scanner, []})

    for number <- 1..104,
        do:
          File.write!(
            Path.join(directory, "public-#{number}.md"),
            String.duplicate("Public botanical archive.\n", 3600)
          )

    {:ok, run} = Capture.start_capture(corpus["id"], connection["id"], 0, caller())
    assert {:ok, result} = Capture.run(run["run_id"])
    assert result["capture"]["complete"]
    assert result["capture"]["checkpoint"] >= 2

    assert [[104]] =
             Repo.query!("SELECT count(*) FROM corpus_members WHERE corpus_id=?", [corpus["id"]]).rows

    [[before]] = Repo.query!("SELECT count(*) FROM evidence_revisions", []).rows
    {:ok, current} = Corpora.get(corpus["id"])

    {:ok, again} =
      Capture.start_capture(corpus["id"], connection["id"], current.semantic_generation, caller())

    assert {:ok, replay} = Capture.run(again["run_id"])
    assert replay["capture"]["counts"]["unchanged"] == 104
    assert [[^before]] = Repo.query!("SELECT count(*) FROM evidence_revisions", []).rows
  end

  test "expired lease recovery reobserves frontier and cannot skip a committed but unacked batch",
       %{directory: directory, connection: connection, corpus: corpus} do
    if Process.whereis(HarnessForge.Evidence.Capture.Scanner) == nil,
      do: start_supervised!({HarnessForge.Evidence.Capture.Scanner, []})

    File.write!(Path.join(directory, "public.md"), "A generic public garden record.\n")
    {:ok, run} = Capture.start_capture(corpus["id"], connection["id"], 0, caller())
    expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    # Keep the real helper alive and waiting for the old process's missing ACK.
    assert :ok = HarnessForge.Evidence.Capture.Scanner.reset("old-lease")

    assert {:ok, %{"done" => true}} =
             HarnessForge.Evidence.Capture.Scanner.open_directory(
               run["run_id"],
               directory,
               "",
               "old-lease"
             )

    # Simulate process death after directory checkpoint, before file outcome/ACK.
    Repo.query!(
      "UPDATE capture_runs SET state='running',lease_token='old-lease',lease_until=? WHERE id=?",
      [expired, run["run_id"]]
    )

    Repo.query!("UPDATE capture_frontier SET state='done' WHERE run_id=?", [run["run_id"]])

    Repo.query!(
      "INSERT INTO capture_items(run_id,relative_path,kind,state,scan_epoch,attempts,updated_at) VALUES(?,'public.md','file','pending',1,0,?)",
      [run["run_id"], DateTime.to_iso8601(DateTime.utc_now())]
    )

    assert {:ok, result} = Capture.run(run["run_id"])
    assert result["capture"]["complete"]
    assert result["capture"]["counts"]["captured"] == 1

    assert [[2]] =
             Repo.query!("SELECT scan_epoch FROM capture_runs WHERE id=?", [run["run_id"]]).rows

    assert {:error, :cancelled} = Capture.check_lease(run["run_id"], "old-lease")
    assert {:error, :cancelled} = HarnessForge.Evidence.Capture.Scanner.cancel("old-lease")

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM capture_frontier WHERE run_id=? AND scan_epoch=2 AND state!='done'",
               [run["run_id"]]
             ).rows
  end

  test "an incomplete scan cannot remove an unseen corpus member", %{
    directory: directory,
    connection: connection,
    corpus: corpus
  } do
    if Process.whereis(HarnessForge.Evidence.Capture.Scanner) == nil,
      do: start_supervised!({HarnessForge.Evidence.Capture.Scanner, []})

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "not-on-disk.md",
        "title" => "Preserved",
        "body" => "Captured public history."
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
        caller()
      )

    File.ln_s!(directory, Path.join(directory, "unsafe-link"))

    {:ok, run} =
      Capture.start_capture(
        corpus["id"],
        connection["id"],
        current["semantic_generation"],
        caller()
      )

    assert {:ok, result} = Capture.run(run["run_id"])
    refute result["capture"]["complete"]

    assert [["active"]] =
             Repo.query!("SELECT status FROM corpus_members WHERE corpus_id=? AND source_id=?", [
               corpus["id"],
               source["id"]
             ]).rows
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("capture caller"),
      view_generation: String.duplicate("c", 32),
      reset_token: 0
    ]
end
