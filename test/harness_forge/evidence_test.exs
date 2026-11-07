defmodule HarnessForge.EvidenceTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Audit, Decisions, Evidence, Goals}
  alias HarnessForge.Evidence.{LocalImport, Revision}

  setup do
    directory = Path.join(File.cwd!(), ".evidence-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    workspace = Application.get_env(:harness_forge, :workspace_id)
    Application.put_env(:harness_forge, :workspace_id, "test-workspace")

    on_exit(fn ->
      File.rm_rf!(directory)
      Application.put_env(:harness_forge, :workspace_id, workspace)
    end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic notes",
        "provider" => "local",
        "directory" => directory
      })

    %{directory: directory, connection: connection}
  end

  test "local import is idempotent and changed UTF-8 bodies append immutable revisions", %{
    directory: directory,
    connection: connection
  } do
    path = Path.join(directory, "decisions.md")
    File.write!(path, "Café rules\n")
    assert {:ok, %{"imported" => 1}} = Evidence.import_directory(connection["id"])
    assert {:ok, [source]} = Evidence.list_sources()
    first = source["latest_revision"]
    assert first["body"] == "Café rules\n"

    assert {:ok, %{"unchanged" => 1, "imported" => 0}} =
             Evidence.import_directory(connection["id"])

    File.write!(path, "Café changed\n")
    assert {:ok, %{"imported" => 1}} = Evidence.import_directory(connection["id"])
    assert {:ok, current} = Evidence.get_source(source["id"])
    assert current["latest_revision"]["revision"] == 2
    assert current["latest_revision"]["id"] != first["id"]
    assert Repo.get!(Revision, first["id"]).body == "Café rules\n"
    assert {:error, _} = Repo.query("UPDATE evidence_revisions SET body = 'tampered'")
  end

  test "search is literal, current-revision and workspace scoped; revoked sources disappear", %{
    connection: connection
  } do
    {:ok, source} = document(connection, "Public architecture evidence")
    assert {:ok, [found]} = Evidence.search("architecture")
    assert found["id"] == source["id"]
    assert {:ok, []} = Evidence.search("\" OR *")
    assert {:ok, _} = document(connection, "Public updated evidence")
    assert {:ok, []} = Evidence.search("architecture")
    assert {:ok, [_]} = Evidence.search("updated")
    Application.put_env(:harness_forge, :workspace_id, "other-workspace")
    assert {:ok, []} = Evidence.list_sources()
    assert {:error, :not_found} = Evidence.get_source(source["id"])
    assert {:ok, []} = Evidence.search("updated")
    Application.put_env(:harness_forge, :workspace_id, "test-workspace")
    assert {:ok, _} = Evidence.revoke_source(source["id"])
    assert {:ok, []} = Evidence.search("updated")
  end

  test "citations enforce exact UTF-8 byte boundaries and unmodified snippets", %{
    connection: connection
  } do
    {:ok, source} = document(connection, "Café rules")
    revision = source["latest_revision"]["id"]
    assert {:error, :invalid_offsets} = Evidence.citation(revision, 3, 4)
    assert {:error, :invalid_offsets} = Evidence.citation(revision, -1, 5)
    assert {:error, :invalid_offsets} = Evidence.citation(revision, 0, 100)
    assert {:ok, citation} = Evidence.citation(revision, 3, 5)
    assert citation["snippet"] == "é"

    assert {:error, :invalid_citation} =
             Evidence.create_claim(%{"text" => "Claim", "citations" => []})

    assert {:error, :invalid_citation} =
             Evidence.create_claim(%{
               "text" => "Claim",
               "citations" => [Map.put(citation, "snippet", "forged")]
             })
  end

  test "claims require an explicit decision for exact revision and edits return to proposed", %{
    connection: connection
  } do
    {claim, citation} = proposed_claim(connection)
    assert claim["status"] == "proposed"
    assert {:ok, []} = Evidence.approved_claims()

    assert {:error, :invalid_input} =
             Decisions.decide(claim["id"], %{
               "decision" => "approve",
               "expected_revision_hash" => claim["revision_hash"]
             })

    assert {:error, :stale_revision} = Decisions.decide(claim["id"], decision("approve", "wrong"))

    assert {:ok, %{"status" => "approved"}} =
             Decisions.decide(claim["id"], decision("approve", claim["revision_hash"]))

    assert {:ok, [approved]} = Evidence.approved_claims()
    assert approved["id"] == claim["id"]

    assert {:error, :already_decided} =
             Decisions.decide(claim["id"], decision("reject", claim["revision_hash"]))

    assert {:ok, edited} =
             Evidence.create_claim(%{
               "text" => "Revised claim",
               "citations" => [citation],
               "supersedes_id" => claim["id"]
             })

    assert edited["status"] == "proposed"
    assert edited["revision_hash"] != claim["revision_hash"]
    assert {:ok, []} = Evidence.approved_claims()

    assert {:error, :superseded_revision} =
             Decisions.decide(claim["id"], decision("approve", claim["revision_hash"]))

    assert {:ok, %{"status" => "rejected"}} =
             Decisions.decide(edited["id"], decision("reject", edited["revision_hash"]))

    assert {:ok, []} = Evidence.approved_claims()
  end

  test "revocation invalidates approved claims and subsequent citations", %{
    connection: connection
  } do
    {claim, citation} = proposed_claim(connection)
    assert {:ok, _} = Decisions.decide(claim["id"], decision("approve", claim["revision_hash"]))
    assert {:ok, [source]} = Evidence.list_sources()
    assert {:ok, _} = Evidence.revoke_source(source["id"])
    assert {:ok, []} = Evidence.approved_claims()
    assert {:error, :source_unavailable} = Evidence.citation(citation["revision_id"], 0, 4)
  end

  test "directory import rejects links, traversal, binary, oversize and unsupported providers", %{
    directory: directory,
    connection: connection
  } do
    assert {:error, :provider_unavailable} =
             Evidence.connect(%{
               "name" => "Cloud",
               "provider" => "github",
               "directory" => directory
             })

    assert {:error, :unsafe_directory} =
             LocalImport.approved_directory(Path.join(directory, "../"))

    target = Path.join(directory, "target.md")
    File.write!(target, "safe")
    File.ln_s!(target, Path.join(directory, "linked.md"))
    assert {:error, :symlink_not_allowed} = Evidence.import_directory(connection["id"])
    File.rm!(Path.join(directory, "linked.md"))
    File.write!(target, <<0, 1, 2>>)
    assert {:error, :binary_file} = Evidence.import_directory(connection["id"])
    File.write!(target, String.duplicate("x", 1_048_577))
    assert {:error, :file_too_large} = Evidence.import_directory(connection["id"])

    assert {:error, :path_escape} =
             Evidence.import_markdown(connection["id"], %{
               "external_id" => "../escape.md",
               "title" => "Escape",
               "body" => "safe"
             })

    assert {:ok, []} = Evidence.list_sources()
  end

  test "goals require owner and acceptance; audit payloads omit secrets", %{} do
    assert {:error, :invalid_input} = Goals.add_goal(%{"title" => "Ship"})

    assert {:ok, goal} =
             Goals.add_goal(%{
               "title" => "Ship",
               "owner" => "Maintainer",
               "acceptance" => "All acceptance checks pass"
             })

    assert {:ok, [^goal]} = Goals.list_goals()

    assert {:ok, event} =
             Audit.append("synthetic.test", %{
               "artifact_digest" => String.duplicate("a", 64),
               "release_id" => "release-reference",
               "evaluation_id" => "evaluation-reference",
               "actor" => "Bearer secret",
               "token" => "do-not-log",
               "body" => "private",
               "count" => 1
             })

    assert event["details"] == %{
             "actor" => "[REDACTED]",
             "count" => 1,
             "artifact_digest" => String.duplicate("a", 64),
             "release_id" => "release-reference",
             "evaluation_id" => "evaluation-reference"
           }

    assert {:ok, events} = Audit.list_events()
    assert Enum.any?(events, &(&1["action"] == "goal.created"))
  end

  test "two approved connections can contain the same external filename", %{
    connection: connection,
    directory: directory
  } do
    other_dir = Path.join(directory, "other")
    File.mkdir_p!(other_dir)

    {:ok, other} =
      Evidence.connect(%{
        "name" => "Other notes",
        "provider" => "local",
        "directory" => other_dir
      })

    assert {:ok, first} = document(connection, "First connection")
    assert {:ok, second} = document(other, "Second connection")
    assert first["id"] != second["id"]
    assert first["external_id"] == second["external_id"]
    assert {:ok, sources} = Evidence.list_sources()
    assert length(sources) == 2
  end

  test "changed and deleted source revisions make approvals ineligible", %{
    connection: connection,
    directory: directory
  } do
    File.write!(Path.join(directory, "note.md"), "Use explicit approvals")
    {claim, _} = proposed_claim(connection)
    assert {:ok, _} = Decisions.decide(claim["id"], decision("approve", claim["revision_hash"]))
    File.write!(Path.join(directory, "note.md"), "Updated explicit approvals")
    assert {:ok, %{"imported" => 1}} = Evidence.import_directory(connection["id"])
    assert {:ok, []} = Evidence.approved_claims()
    assert {:ok, %{"status" => "stale"}} = Evidence.get_claim(claim["id"])
    File.rm!(Path.join(directory, "note.md"))
    assert {:ok, %{"deleted" => 1}} = Evidence.import_directory(connection["id"])
    assert {:ok, []} = Evidence.search("Updated")
    assert {:ok, [%{"status" => "deleted"}]} = Evidence.list_sources()
  end

  defp document(connection, body) do
    Evidence.import_markdown(connection["id"], %{
      "external_id" => "note.md",
      "title" => "Synthetic note",
      "body" => body
    })
  end

  defp proposed_claim(connection) do
    {:ok, source} = document(connection, "Use explicit approvals")
    {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, 22)

    {:ok, claim} =
      Evidence.create_claim(%{
        "text" => "Explicit approvals are required",
        "citations" => [citation]
      })

    {claim, citation}
  end

  defp decision(value, hash),
    do: %{
      "actor" => "synthetic-maintainer",
      "decision" => value,
      "expected_revision_hash" => hash
    }
end
