defmodule HarnessForge.RevisionUseHoldProposalTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Evidence, Repo, Workspaces}
  alias HarnessForge.Models.Proposal
  alias HarnessForge.Privacy.Purge

  setup do
    directory = Path.join(System.tmp_dir!(), "proposal-hold-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic proposal",
        "provider" => "local",
        "directory" => directory
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "record.md",
        "title" => "Synthetic",
        "body" => "Café requires explicit approval."
      })

    citation = %{
      "source_id" => source["id"],
      "revision_id" => source["latest_revision"]["id"],
      "start_byte" => 0,
      "end_byte" => byte_size("Café"),
      "snippet" => "Café"
    }

    claims = [%{"text" => "Synthetic supported proposal", "citations" => [citation]}]
    %{source: source, claims: claims}
  end

  test "the owning publication entry holds the privacy fence before its first SQL operation", c do
    handler = {__MODULE__, Ecto.UUID.generate()}
    owner = self()
    key = {Purge, :synchronize, Workspaces.current_id()}

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, _, _ -> send(owner, {:proposal_sql_fenced, Process.get(key) == true}) end,
        nil
      )

    try do
      assert {:ok, [_]} = Proposal.persist(c.claims, c.source)
      flags = drain([])
      refute flags == []
      assert Enum.all?(flags), "proposal SQL began before the owning privacy fence"
    after
      :telemetry.detach(handler)
    end
  end

  test "an externally owned transaction is refused before publication takes a privacy fence", c do
    assert {:ok, {:error, :proposal_requires_outermost_transaction}} =
             Repo.transaction(fn -> Proposal.persist(c.claims, c.source) end)

    assert {:ok, []} = Evidence.list_claims()
  end

  test "a restriction committed before publication admits no claim or citation", c do
    r = c.source["latest_revision"]

    assert {:ok, _} =
             Evidence.restrict_revision(
               %{
                 "version" => 1,
                 "source_id" => c.source["id"],
                 "revision_id" => r["id"],
                 "body_hash" => r["body_hash"],
                 "expected_generation" => 0,
                 "command_id" => Ecto.UUID.generate(),
                 "reason_code" => "operator_restriction"
               },
               caller()
             )

    assert {:error, _} = Proposal.persist(c.claims, c.source)
    assert {:ok, []} = Evidence.list_claims()

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM evidence_citations WHERE workspace_id=?", [
               Workspaces.current_id()
             ]).rows
  end

  test "a concurrent publication waits outside SQL while the restriction owns the privacy fence",
       c do
    owner = self()
    r = c.source["latest_revision"]

    publisher =
      Purge.synchronize(fn ->
        publisher =
          Task.async(fn ->
            send(owner, :proposal_started)
            Proposal.persist(c.claims, c.source)
          end)

        assert_receive :proposal_started, 1_000

        assert {:ok, _} =
                 Evidence.restrict_revision(
                   %{
                     "version" => 1,
                     "source_id" => c.source["id"],
                     "revision_id" => r["id"],
                     "body_hash" => r["body_hash"],
                     "expected_generation" => 0,
                     "command_id" => Ecto.UUID.generate(),
                     "reason_code" => "operator_restriction"
                   },
                   caller()
                 )

        publisher
      end)

    assert {:error, _} = Task.await(publisher, 2_000)
    assert {:ok, []} = Evidence.list_claims()

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM evidence_citations WHERE workspace_id=?", [
               Workspaces.current_id()
             ]).rows
  end

  defp drain(flags) do
    receive do
      {:proposal_sql_fenced, flag} -> drain([flag | flags])
    after
      0 -> flags
    end
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("synthetic proposal"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
end
