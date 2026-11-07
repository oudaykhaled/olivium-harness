defmodule HarnessForge.Evidence.GraphSourcesTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Evidence, Repo}
  alias HarnessForge.Evidence.{Corpora, GraphManifests, GraphSources, OriginV2}
  alias HarnessForge.Models.{GraphConsent, StageAuthority, StageControl, Stages}

  setup do
    previous = Application.get_env(:harness_forge, :graph_runtime_authority)
    Application.delete_env(:harness_forge, :graph_runtime_authority)
    root = Path.join(System.tmp_dir!(), "graph-source-control-" <> Ecto.UUID.generate())
    File.mkdir_p!(root)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:harness_forge, :graph_runtime_authority),
        else: Application.put_env(:harness_forge, :graph_runtime_authority, previous)

      File.rm_rf!(root)
    end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Public synthetic source controls",
        "provider" => "local",
        "directory" => root
      })

    {:ok, corpus} = Corpora.create(%{"name" => "Public synthetic 101-source scope"}, caller())

    changes =
      for n <- 1..101 do
        {:ok, s} =
          Evidence.import_markdown(connection["id"], %{
            "external_id" => "control-#{n}.md",
            "title" => "Public record #{n}",
            "body" =>
              "Public synthetic garden record #{n}; compare named review decisions with future goals."
          })

        %{
          "source_id" => s["id"],
          "revision_id" => s["latest_revision"]["id"],
          "action" => "include"
        }
      end

    {:ok, c} = Corpora.apply_members(corpus["id"], 0, Enum.take(changes, 100), caller())

    {:ok, _} =
      Corpora.apply_members(
        corpus["id"],
        c["semantic_generation"],
        Enum.drop(changes, 100),
        caller()
      )

    %{corpus: corpus["id"], source: hd(changes)["source_id"]}
  end

  test "missing qualification denies; independent checkpointed scan and certificate agree beyond 100",
       ctx do
    assert {:error, :graph_unavailable} = GraphSources.start(ctx.corpus, caller())
    configure_synthetic_control_runtime()
    {:ok, partition} = GraphSources.start(ctx.corpus, caller())
    id = partition["partition_id"]

    assert {:ok, %{"state" => "scanning", "source_count" => 100}} =
             GraphSources.advance(id, caller())

    assert {:ok, %{"state" => "scanning", "source_count" => 101}} =
             GraphSources.advance(id, caller())

    assert [[nil]] =
             Repo.query!("SELECT source_lock_digest FROM graph_partition_controls WHERE id=?", [
               id
             ]).rows

    assert {:ok, %{"state" => "complete", "source_count" => 101}} =
             GraphSources.advance(id, caller())

    assert {:ok, %{"state" => "complete", "source_count" => 101}} =
             GraphSources.advance(id, caller())

    pin = stage()
    assert {:ok, _} = StageAuthority.create_pin(pin, caller())

    assert {:ok, auth} =
             StageAuthority.new_graph(
               Ecto.UUID.generate(),
               "ingest",
               id,
               [pin["id"]],
               "synthetic-session-1",
               caller()
             )

    cert = seal_sources(auth)
    assert cert["effective_source_count"] == 101

    assert {:ok, bound} =
             StageAuthority.bind_graph_manifest(auth, cert["manifest_id"], cert["digest"])

    assert {:ok, _} =
             GraphManifests.validate_scope_certificate(cert["manifest_id"], cert["digest"], bound)

    assert {:error, _} =
             StageAuthority.bind_graph_manifest(bound, cert["manifest_id"], cert["digest"])

    assert {:error, _} =
             StageControl.graph_current(%{bound | backend_pin_digest: String.duplicate("0", 64)})

    assert {:error, :closure_incomplete} =
             StageAuthority.observe_context(%{"authority" => bound}, %{})

    local = local_context(bound, pin, cert)
    assert OriginV2.contains_source?(local["manifest_id"], ctx.source)
    refute OriginV2.contains_source?(local["manifest_id"], Ecto.UUID.generate())

    assert [] == Repo.query!("PRAGMA foreign_key_check", []).rows
  end

  test "consent grant pages once; scalar certificate reuses scope across operation epochs and revocation denies",
       ctx do
    configure_synthetic_control_runtime()
    {:ok, p} = GraphSources.start(ctx.corpus, caller())
    for _ <- 1..3, do: assert({:ok, _} = GraphSources.advance(p["partition_id"], caller()))
    pin = stage()
    {:ok, _} = StageAuthority.create_pin(pin, caller())

    {:ok, auth} =
      StageAuthority.new_graph(
        Ecto.UUID.generate(),
        "ingest",
        p["partition_id"],
        [pin["id"]],
        "synthetic-session-1",
        caller()
      )

    cert = seal_sources(auth)
    {:ok, auth} = StageAuthority.bind_graph_manifest(auth, cert["manifest_id"], cert["digest"])
    assert {:ok, grant} = GraphConsent.start_grant(auth, pin["id"])
    consent = grant["consent_id"]
    id = grant["certificate_id"]
    assert {:error, :consent_required} = GraphConsent.validate(id, auth, pin, consent)
    assert {:ok, %{"state" => "checking", "next_ordinal" => 100}} = GraphConsent.advance(id, auth)

    assert [[200]] =
             Repo.query!("SELECT count(*) FROM stage_consent_sources WHERE consent_id=?", [
               consent
             ]).rows

    assert {:ok, %{"state" => "sealed", "next_ordinal" => 101}} = GraphConsent.advance(id, auth)
    assert :ok = GraphConsent.validate(id, auth, pin, consent)

    assert [[202]] =
             Repo.query!("SELECT count(*) FROM stage_consent_sources WHERE consent_id=?", [
               consent
             ]).rows

    Repo.query!("UPDATE stage_operations SET state='completed' WHERE id=?", [auth.operation_id])

    Repo.query!(
      "UPDATE graph_partition_controls SET state='ready',inventory_revision=1 WHERE id=?",
      [auth.partition_id]
    )

    assert {:ok, fresh} =
             StageAuthority.new_graph(
               Ecto.UUID.generate(),
               "search",
               auth.partition_id,
               [pin["id"]],
               "synthetic-session-2",
               caller()
             )

    assert fresh.manifest_id == auth.manifest_id
    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, meta, _ -> send(owner, {:consent_query, meta.query, meta.result}) end,
        nil
      )

    try do
      for _ <- 1..3, do: assert(:ok = GraphConsent.validate(id, fresh, pin, consent))
      sql = drain_queries([])
      refute Enum.any?(sql, &String.contains?(&1, "FROM origin_dependencies"))
      refute Enum.any?(sql, &String.contains?(&1, "FROM stage_consent_sources"))
    after
      :telemetry.detach(handler)
    end

    assert {:ok, _} = StageAuthority.cancel(fresh)

    assert [["ready", 1]] =
             Repo.query!(
               "SELECT state,inventory_revision FROM graph_partition_controls WHERE id=?",
               [auth.partition_id]
             ).rows

    assert {:ok, next} =
             StageAuthority.new_graph(
               Ecto.UUID.generate(),
               "search",
               auth.partition_id,
               [pin["id"]],
               "synthetic-session-3",
               caller()
             )

    assert :ok = GraphConsent.validate(id, next, pin, consent)
    Repo.query!("UPDATE stage_consent_revisions SET state='revoked' WHERE id=?", [consent])
    assert {:error, :consent_required} = GraphConsent.validate(id, next, pin, consent)

    triggers =
      Repo.query!(
        "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name LIKE 'immutable_graph_%_delete' ORDER BY name",
        []
      ).rows

    assert {:ok, _} = HarnessForge.Privacy.purge_source(ctx.source, ctx.source)

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM graph_consent_certificates WHERE id=?", [id]).rows

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM graph_manifest_builds WHERE manifest_id=?", [
               cert["manifest_id"]
             ]).rows

    assert triggers ==
             Repo.query!(
               "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name LIKE 'immutable_graph_%_delete' ORDER BY name",
               []
             ).rows

    assert [] == Repo.query!("PRAGMA foreign_key_check", []).rows
  end

  test "source authorization change fences unfinished scan before certification", ctx do
    configure_synthetic_control_runtime()
    {:ok, p} = GraphSources.start(ctx.corpus, caller())
    assert {:ok, %{"source_count" => 100}} = GraphSources.advance(p["partition_id"], caller())
    assert :ok = Corpora.invalidate_source(ctx.source, :metadata_changed)
    assert {:error, :stale_generation} = GraphSources.advance(p["partition_id"], caller())

    assert [[nil]] =
             Repo.query!("SELECT source_lock_digest FROM graph_partition_controls WHERE id=?", [
               p["partition_id"]
             ]).rows
  end

  defp seal_sources(auth) do
    Enum.reduce_while(1..12, nil, fn _, _ ->
      assert {:ok, status} = GraphSources.certificate_step(auth)
      if status["phase"] == "sealed", do: {:halt, status}, else: {:cont, status}
    end)
    |> then(fn status ->
      assert status["phase"] == "sealed"
      status
    end)
  end

  defp local_context(auth, pin, cert) do
    context =
      Map.new(
        ~w(operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest),
        &{&1, nil}
      )
      |> Map.merge(%{
        "graph_kind" => "inputs",
        "operation_manifest_ref" => auth.manifest_id,
        "operation_manifest_digest" => auth.manifest_digest,
        "context_id" => Ecto.UUID.generate(),
        "logical_call_id" => Ecto.UUID.generate(),
        "seam_id" => "embedder.input.v1",
        "stage_id" => pin["id"],
        "prompt_name" => "embedder.create",
        "config_digest" => pin["config_digest"],
        "schema_digest" =>
          elem(HarnessForge.Graphiti.SchemaPolicy.entry(pin, "embedder.create"), 1)[
            "schema_digest"
          ]
      })

    {:ok, status} = GraphManifests.begin_manifest(auth, "graph_ingest", context)

    row =
      Map.new(
        ~w(source_id revision_id episode_binding_id derivative_version_id parent_manifest_id projection_id projection_hash),
        &{&1, nil}
      )
      |> Map.merge(%{
        "dependency_key" => "manifest:" <> cert["manifest_id"],
        "kind" => "manifest",
        "content_hash" => cert["digest"],
        "role" => "transitive",
        "parent_manifest_id" => cert["manifest_id"]
      })

    assert {:ok, _} =
             GraphManifests.append_page(
               status["manifest_id"],
               %{
                 "page_index" => 0,
                 "first_ordinal" => 0,
                 "previous_page_digest" => nil,
                 "final" => true,
                 "rows" => [row]
               },
               auth
             )

    assert {:ok, _} =
             GraphManifests.finish_manifest(
               status["manifest_id"],
               %{"dependency_count" => 1, "source_count" => 0},
               auth
             )

    assert {:ok, sealed} = GraphManifests.advance_validation(status["manifest_id"], auth)
    assert sealed["phase"] == "sealed"
    sealed
  end

  defp configure_synthetic_control_runtime do
    # Scoped test-only registry: this does not qualify an actual image/backend.
    {:ok, bundle} =
      GraphSources.runtime_bundle(%{
        "worker_image" => "sha256:" <> String.duplicate("1", 64),
        "backend_image" => "sha256:" <> String.duplicate("2", 64),
        "backend_instance" => "synthetic-control-only",
        "database" => "neo4j",
        "index_identity" => "synthetic-index-v1"
      })

    Application.put_env(:harness_forge, :graph_runtime_authority, %{
      "qualified" => true,
      "bundle" => bundle,
      "qualification_ref" => "synthetic-control-tests-only"
    })
  end

  defp stage do
    attrs = %{
      "id" => Ecto.UUID.generate(),
      "stage" => "embedder",
      "provider" => "ollama",
      "model" => "synthetic-vector-v1",
      "endpoint" => "http://127.0.0.1:11434/v1/embeddings",
      "route_id" => "graphiti_embedder",
      "credential_ref" => nil,
      "prompt_digest" => HarnessForge.Graphiti.SchemaPolicy.prompt_policy_digest("embedder"),
      "schema_digest" => HarnessForge.Graphiti.SchemaPolicy.digest(),
      "consent_revision" => 1,
      "input_rate" => 0,
      "output_rate" => 0,
      "max_output_tokens" => 1024,
      "timeout_ms" => 1000
    }

    Map.put(attrs, "config_digest", Stages.fingerprint(attrs))
  end

  defp drain_queries(acc) do
    receive do
      {:consent_query, sql, {:ok, result}} ->
        assert length(result.rows || []) <= 1
        drain_queries([sql | acc])

      {:consent_query, sql, _} ->
        drain_queries([sql | acc])
    after
      0 -> acc
    end
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("graph-source-control"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
end
