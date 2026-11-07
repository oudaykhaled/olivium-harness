defmodule HarnessForge.Evidence.GraphManifestsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Evidence, Repo}
  alias HarnessForge.Evidence.{Corpora, GraphManifests, Store}
  alias HarnessForge.Graphiti.SchemaPolicy
  alias HarnessForge.Models.{StageAuthority, StageControl, Stages}

  @context ~w(graph_kind operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest)
  @row ~w(dependency_key kind source_id revision_id content_hash role episode_binding_id derivative_version_id projection_id projection_hash parent_manifest_id)

  test "an inventory lookup miss preserves the caller transaction for current-save fallback" do
    {_certificate, auth} = garden(1) |> certify()

    base = %{
      "inventory_revision" => 0,
      "inventory_manifest_id" => nil,
      "inventory_manifest_digest" => nil
    }

    assert {:ok, :fallback_still_readable} =
             Store.transaction(fn ->
               assert {:error, :closure_incomplete} =
                        GraphManifests.inventory_version(
                          base,
                          "deterministic_output",
                          "EntityNode:" <> Ecto.UUID.generate(),
                          auth
                        )

               assert %{rows: [[1]]} = Repo.query!("SELECT 1", [])
               {:ok, :fallback_still_readable}
             end)
  end

  test "a source certificate proves an empty base but cannot impersonate a completed graph inventory" do
    f = garden(1)
    {certificate, auth} = certify(f)

    empty = %{
      "inventory_revision" => 0,
      "inventory_manifest_id" => nil,
      "inventory_manifest_digest" => nil
    }

    assert {:ok, nil} = GraphManifests.inventory_parent(empty, auth)

    for malformed <- [
          Map.put(empty, "inventory_revision", "0"),
          Map.put(empty, "selector", "latest"),
          Map.put(empty, "inventory_revision", 1)
        ] do
      assert {:error, _} = GraphManifests.inventory_parent(malformed, auth)
    end

    assert {:error, _} =
             GraphManifests.inventory_version(
               empty,
               "deterministic_output",
               "EntityNode:" <> Ecto.UUID.generate(),
               auth
             )

    # Deliberately point the scalar control at a valid same-S SOURCE manifest.
    # Foreign keys and a matching digest alone must never make it an inventory.
    Repo.query!(
      "UPDATE graph_partition_controls SET inventory_revision=1,inventory_manifest_id=?,inventory_manifest_digest=? WHERE id=?",
      [certificate["manifest_id"], certificate["digest"], auth.partition_id]
    )

    forged = %{
      "inventory_revision" => 1,
      "inventory_manifest_id" => certificate["manifest_id"],
      "inventory_manifest_digest" => certificate["digest"]
    }

    assert {:error, _} = GraphManifests.inventory_parent(forged, auth)
    assert {:error, _} = GraphManifests.inventory_stage_pins(forged, auth)
    assert {:error, _} = GraphManifests.inventory_configuration_current(auth.partition_id)
    assert {:error, _} = GraphManifests.inventory_configuration(auth.partition_id, [])
    assert {:error, _} = GraphManifests.inventory_parent(empty, auth)
  end

  test "historical inventory helpers cannot bypass a changed source generation" do
    f = garden(1)
    {_certificate, auth} = certify(f)

    empty = %{
      "inventory_revision" => 0,
      "inventory_manifest_id" => nil,
      "inventory_manifest_digest" => nil
    }

    assert {:ok, nil} = GraphManifests.inventory_parent(empty, auth)
    :ok = Corpora.advance(auth.corpus_id)
    assert {:error, _} = GraphManifests.inventory_parent(empty, auth)

    assert {:error, _} =
             GraphManifests.inventory_version(
               empty,
               "summary",
               "EntityNode:" <> Ecto.UUID.generate(),
               auth
             )
  end

  test "bootstrap seals a multi-page exact source set before the partition has a manifest" do
    f = garden(104, true)

    assert [[nil]] =
             Repo.query!("SELECT manifest_id FROM graph_partition_controls WHERE id=?", [
               f.auth.partition_id
             ]).rows

    {:ok, started} = GraphManifests.begin_manifest(f.auth, "partition", source_context())
    id = started["manifest_id"]
    pages = Enum.chunk_every(f.rows, 100)
    {acks, _} = append_pages(id, pages, f.auth)
    assert length(acks) == 2

    assert {:ok, hd(acks)} ==
             GraphManifests.append_page(id, page(0, 0, nil, false, hd(pages)), f.auth)

    assert {:ok, waiting} =
             GraphManifests.finish_manifest(
               id,
               %{"dependency_count" => 104, "source_count" => 104},
               f.auth
             )

    assert waiting["phase"] == "validating"
    assert {:ok, first} = GraphManifests.advance_validation(id, f.auth)
    assert first["phase"] == "validating"

    assert [[100]] =
             Repo.query!(
               "SELECT validated_count FROM graph_manifest_builds WHERE manifest_id=?",
               [id]
             ).rows

    assert {:ok, final} = GraphManifests.advance_validation(id, f.auth)
    assert final["state"] == "sealed"
    assert final["effective_source_count"] == 104
    assert {:error, _} = GraphManifests.validate_scope_certificate(id, final["digest"], f.auth)
    assert {:ok, auth} = StageControl.bind_graph_manifest(f.auth, id, final["digest"])

    assert {:ok, certificate} =
             GraphManifests.validate_scope_certificate(id, final["digest"], auth)

    assert is_nil(certificate["execution_identity"])
    assert certificate["source_identity"]["source_lock_digest"] == f.source_digest
    refute Map.has_key?(certificate["source_identity"], "cancel_epoch")
    assert {:ok, a} = GraphManifests.read_page(id, final["digest"], 0, auth)
    assert length(a["rows"]) == 100 and not a["exhausted"]
    assert {:ok, b} = GraphManifests.read_page(id, final["digest"], a["next_ordinal"], auth)
    assert length(b["rows"]) == 4 and b["exhausted"]
    assert {:ok, empty} = GraphManifests.read_page(id, final["digest"], 104, auth)
    assert empty["rows"] == [] and empty["exhausted"]
    all = a["rows"] ++ b["rows"]
    expected_chain = independent_row_chain(all, 37)
    assert expected_chain == independent_row_chain(all, 100)

    [[header_hash, chain]] =
      Repo.query!(
        "SELECT header_hash,row_chain_hash FROM graph_manifest_builds WHERE manifest_id=?",
        [id]
      ).rows

    assert chain == expected_chain

    assert final["digest"] ==
             Contracts.digest(%{
               "format" => "graph-manifest-v2",
               "header_hash" => header_hash,
               "rows_hash" => expected_chain,
               "dependency_count" => 104,
               "source_count" => 104
             })
  end

  test "local manifests inherit sources by certificate without copying or reading source bodies" do
    f = garden(104, true)
    {cert, auth} = certify(f)
    parent = local(auth, cert, cert, [])
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, metadata, _ ->
          send(owner, {:manifest_query, metadata.query, metadata.result})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    child = local(auth, cert, parent, [parent_row(parent)])

    assert {:ok, metadata} =
             GraphManifests.validate_current(child["manifest_id"], child["digest"], auth)

    assert metadata["source_count"] == 0
    assert metadata["effective_source_count"] == 104

    assert [[1]] =
             Repo.query!("SELECT count(*) FROM origin_dependencies WHERE manifest_id=?", [
               child["manifest_id"]
             ]).rows

    assert {:ok, true} =
             GraphManifests.contains_source?(
               child["manifest_id"],
               child["digest"],
               hd(f.rows)["source_id"],
               auth
             )

    assert {:ok, false} =
             GraphManifests.contains_source?(
               child["manifest_id"],
               child["digest"],
               Ecto.UUID.generate(),
               auth
             )

    queries = drain_queries([])

    refute Enum.any?(queries, fn {sql, _} ->
             String.contains?(sql, "FROM evidence_sources") or
               String.contains?(sql, "FROM evidence_revisions")
           end)

    for {_sql, result} <- queries, match?({:ok, %{columns: _}}, result) do
      {:ok, rows} = result
      refute "body" in (rows.columns || [])
      assert length(rows.rows || []) <= 100
    end
  end

  test "metadata-only initial validation checks permission and never materializes a large body" do
    f = garden(3, true)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:harness_forge, :repo, :query],
        fn _, _, metadata, _ ->
          if String.contains?(metadata.query, "FROM evidence_sources"),
            do: send(owner, {:source_metadata, metadata.query, metadata.result})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {cert, _auth} = certify(f)
    assert cert["effective_source_count"] == 3
    assert_receive {:source_metadata, sql, {:ok, result}}
    assert String.contains?(sql, "cm.revision_id=r.id")
    refute "body" in result.columns
    assert Enum.sort(result.columns) == Enum.sort(~w(id revision_id body_hash))
  end

  test "changed replay denies a building record and exact accepted replay remains stable" do
    f = garden(3)
    {:ok, started} = GraphManifests.begin_manifest(f.auth, "partition", source_context())
    dto = page(0, 0, nil, true, f.rows)
    assert {:ok, ack} = GraphManifests.append_page(started["manifest_id"], dto, f.auth)
    assert {:ok, ^ack} = GraphManifests.append_page(started["manifest_id"], dto, f.auth)

    changed =
      put_in(
        dto,
        ["rows", Access.at(0), "content_hash"],
        Contracts.sha256("changed public garden record")
      )

    assert {:error, :closure_incomplete} =
             GraphManifests.append_page(started["manifest_id"], changed, f.auth)

    assert [["denied", "denied"]] =
             Repo.query!(
               "SELECT b.phase,m.state FROM graph_manifest_builds b JOIN dependency_manifests m ON m.id=b.manifest_id WHERE b.manifest_id=?",
               [started["manifest_id"]]
             ).rows

    assert {:error, _} =
             GraphManifests.finish_manifest(
               started["manifest_id"],
               %{"dependency_count" => 3, "source_count" => 3},
               f.auth
             )
  end

  test "noncontiguous pages cannot certify a partial source set" do
    f = garden(3)
    {:ok, started} = GraphManifests.begin_manifest(f.auth, "partition", source_context())

    assert {:error, :closure_incomplete} =
             GraphManifests.append_page(
               started["manifest_id"],
               page(0, 1, nil, true, f.rows),
               f.auth
             )

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM origin_dependencies WHERE manifest_id=?", [
               started["manifest_id"]
             ]).rows
  end

  test "missing final markers and wrong expected counts never seal" do
    for failure <- [:missing_final, :wrong_total] do
      f = garden(3)
      {:ok, started} = GraphManifests.begin_manifest(f.auth, "partition", source_context())

      assert {:ok, _} =
               GraphManifests.append_page(
                 started["manifest_id"],
                 page(0, 0, nil, failure != :missing_final, f.rows),
                 f.auth
               )

      count = if failure == :wrong_total, do: 2, else: 3

      assert {:error, :closure_incomplete} =
               GraphManifests.finish_manifest(
                 started["manifest_id"],
                 %{"dependency_count" => count, "source_count" => count},
                 f.auth
               )

      assert [["denied"]] =
               Repo.query!("SELECT state FROM dependency_manifests WHERE id=?", [
                 started["manifest_id"]
               ]).rows
    end
  end

  test "a current root control cannot substitute a stale or forged source body hash" do
    f = garden(3)
    {:ok, started} = GraphManifests.begin_manifest(f.auth, "partition", source_context())

    wrong =
      hd(f.rows) |> Map.put("content_hash", Contracts.sha256("different original source bytes"))

    assert {:error, :source_unavailable} =
             GraphManifests.append_page(
               started["manifest_id"],
               page(0, 0, nil, true, [wrong]),
               f.auth
             )

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM origin_dependencies WHERE manifest_id=?", [
               started["manifest_id"]
             ]).rows
  end

  test "final worker page cannot omit an independently pinned original source" do
    f = garden(3)
    {:ok, started} = GraphManifests.begin_manifest(f.auth, "partition", source_context())

    assert {:ok, _} =
             GraphManifests.append_page(
               started["manifest_id"],
               page(0, 0, nil, true, Enum.take(f.rows, 2)),
               f.auth
             )

    assert {:error, :closure_incomplete} =
             GraphManifests.finish_manifest(
               started["manifest_id"],
               %{"dependency_count" => 2, "source_count" => 2},
               f.auth
             )

    assert [["denied"]] =
             Repo.query!("SELECT state FROM dependency_manifests WHERE id=?", [
               started["manifest_id"]
             ]).rows
  end

  test "building rows/header are immutable before publication" do
    f = garden(3)
    {:ok, started} = GraphManifests.begin_manifest(f.auth, "partition", source_context())

    assert {:ok, _} =
             GraphManifests.append_page(
               started["manifest_id"],
               page(0, 0, nil, true, f.rows),
               f.auth
             )

    assert {:error, _} =
             Repo.query("UPDATE origin_dependencies SET content_hash=? WHERE manifest_id=?", [
               Contracts.sha256("forged"),
               started["manifest_id"]
             ])

    assert {:error, _} =
             Repo.query("UPDATE dependency_manifests SET context_json='{}' WHERE id=?", [
               started["manifest_id"]
             ])

    assert {:error, _} =
             Repo.query("UPDATE graph_manifest_builds SET header_hash=? WHERE manifest_id=?", [
               Contracts.sha256("forged header"),
               started["manifest_id"]
             ])
  end

  test "a fresh stage/operation reuses stable source eligibility but not historical local authority" do
    f = garden(3)
    {cert, old_auth} = certify(f)
    old_context = local(old_auth, cert, cert, [])

    Repo.query!("UPDATE stage_operations SET state='completed' WHERE workspace_id=? AND id=?", [
      Store.workspace(),
      old_auth.operation_id
    ])

    Repo.query!("UPDATE graph_partition_controls SET state='ready' WHERE id=?", [
      old_auth.partition_id
    ])

    next_pin = stage_pin("garden-stage-v2")
    assert {:ok, _} = StageAuthority.create_pin(next_pin, caller())

    next = %{
      old_auth
      | operation_id: Ecto.UUID.generate(),
        lease_id: Ecto.UUID.generate(),
        worker_session_id: Ecto.UUID.generate(),
        operation_type: "search",
        stage_pins: [next_pin],
        manifest_id: nil,
        manifest_digest: nil,
        control_token: nil
    }

    assert {:ok, opened} = StageControl.open(next)

    assert {:ok, fresh} =
             StageControl.bind_graph_manifest(opened, cert["manifest_id"], cert["digest"])

    assert {:ok, _} =
             GraphManifests.validate_scope_certificate(cert["manifest_id"], cert["digest"], fresh)

    assert {:error, _} =
             GraphManifests.validate_current(
               old_context["manifest_id"],
               old_context["digest"],
               fresh
             )

    # A prior sealed local context may remain a provenance row; it is not used
    # as a live base context or as transferable execution authority.
    current = local(fresh, cert, cert, [parent_row(old_context)])
    assert current["source_count"] == 0 and current["effective_source_count"] == 3

    assert {:ok, _} =
             GraphManifests.validate_current(current["manifest_id"], current["digest"], fresh)

    assert {:ok, _} = StageControl.cancel(fresh)

    assert {:error, _} =
             GraphManifests.validate_current(current["manifest_id"], current["digest"], fresh)

    assert [["ready", 0, 1]] =
             Repo.query!(
               "SELECT state,cancel_epoch,lock_version FROM graph_partition_controls WHERE id=?",
               [fresh.partition_id]
             ).rows
  end

  test "source generation and denied source certificate invalidate current descendants" do
    f = garden(3)
    {cert, auth} = certify(f)
    child = local(auth, cert, cert, [])

    Repo.query!("UPDATE dependency_manifests SET state='denied' WHERE id=?", [cert["manifest_id"]])

    assert {:error, _} =
             GraphManifests.validate_current(child["manifest_id"], child["digest"], auth)

    assert {:error, _} =
             Repo.query("UPDATE dependency_manifests SET state='sealed' WHERE id=?", [
               cert["manifest_id"]
             ])

    Repo.query!("UPDATE corpora SET semantic_generation=semantic_generation+1 WHERE id=?", [
      f.corpus.id
    ])

    assert {:error, _} =
             GraphManifests.validate_scope_certificate(cert["manifest_id"], cert["digest"], auth)
  end

  test "building, missing and self-referential parents remain uncertified" do
    f = garden(3)
    {cert, auth} = certify(f)

    assert {:ok, building} =
             GraphManifests.begin_manifest(auth, "derivative", local_context(auth, cert))

    row =
      parent_row(%{
        "manifest_id" => building["manifest_id"],
        "digest" => Contracts.sha256("not certified")
      })

    assert {:error, :closure_incomplete} =
             GraphManifests.append_page(
               building["manifest_id"],
               page(0, 0, nil, true, [row]),
               auth
             )

    assert {:error, _} =
             GraphManifests.validate_current(Ecto.UUID.generate(), cert["digest"], auth)
  end

  test "typed versions require prior certified input, correct hash, and immutable predecessor identity" do
    f = garden(3)
    {cert, auth} = certify(f)
    input = local(auth, cert, cert, [])
    version = Ecto.UUID.generate()
    hash = Contracts.digest(%{"summary" => "Public garden schedule"})
    insert_version!(version, auth, input, "garden-object", 1, hash, nil)

    typed =
      blank_row()
      |> Map.merge(%{
        "dependency_key" => "summary:" <> version,
        "kind" => "summary",
        "derivative_version_id" => version,
        "content_hash" => hash,
        "role" => "transitive",
        "projection_id" => "garden_summary_v1",
        "projection_hash" => Contracts.sha256("Public garden schedule")
      })

    typed = Map.put(typed, "dependency_key", typed["dependency_key"] <> ":garden_summary_v1")
    child = local(auth, cert, input, [typed])
    assert child["effective_source_count"] == 3

    assert {:error, _} =
             Repo.query("UPDATE graph_derivative_versions SET value_hash=? WHERE id=?", [
               Contracts.sha256("mutated"),
               version
             ])

    assert {:error, _} =
             Repo.query(
               "INSERT INTO graph_derivative_versions(id,workspace_id,partition_id,object_kind,object_id,version,value_hash,manifest_id,predecessor_id,state,inserted_at) VALUES(?,?,?,'summary','different-object',2,?,?,?,'staging',?)",
               [
                 Ecto.UUID.generate(),
                 Store.workspace(),
                 auth.partition_id,
                 hash,
                 input["manifest_id"],
                 version,
                 Corpora.now()
               ]
             )

    assert {:ok, unsealed} =
             GraphManifests.begin_manifest(auth, "derivative", local_context(auth, cert))

    assert {:error, _} =
             Repo.query(
               "INSERT INTO graph_derivative_versions(id,workspace_id,partition_id,object_kind,object_id,version,value_hash,manifest_id,state,inserted_at) VALUES(?,?,?,'summary','garden-new-object',1,?,?,'staging',?)",
               [
                 Ecto.UUID.generate(),
                 Store.workspace(),
                 auth.partition_id,
                 hash,
                 unsealed["manifest_id"],
                 Corpora.now()
               ]
             )
  end

  test "source page size and strict authority/DTO boundaries do not get relaxed" do
    f = garden(3)

    assert {:error, :invalid_scope} =
             GraphManifests.begin_manifest(%{}, "partition", source_context())

    {:ok, started} = GraphManifests.begin_manifest(f.auth, "partition", source_context())
    oversized = page(0, 0, nil, true, List.duplicate(hd(f.rows), 101))

    assert {:error, :invalid_input} =
             GraphManifests.append_page(started["manifest_id"], oversized, f.auth)

    assert {:error, :invalid_input} =
             GraphManifests.begin_manifest(
               f.auth,
               "partition",
               Map.put(source_context(), "source_ids", [])
             )
  end

  for kind <- ~w(rendered_message embed_input deterministic_output) do
    @derivative_kind kind

    test "#{kind} uses immutable typed versions and prior sealed inputs without weakening guards" do
      kind = @derivative_kind
      f = garden(1)
      {cert, auth} = certify(f)
      input = local(auth, cert, cert, [])
      version = Ecto.UUID.generate()
      hash = Contracts.digest(%{"value" => "Public garden observation", "kind" => kind})
      object = "garden-observation-" <> kind
      insert_version!(version, auth, input, object, 1, hash, nil, kind)
      typed = version_row(kind, version, hash)
      child = local(auth, cert, input, [typed])

      assert {:ok, read} =
               GraphManifests.read_page(child["manifest_id"], child["digest"], 0, auth)

      assert [Map.put(typed, "ordinal", 0)] == read["rows"]
      assert Enum.sort(Map.keys(typed)) == Enum.sort(@row)
      assert child["source_count"] == 0 and child["effective_source_count"] == 1

      assert {:error, _} =
               Repo.query("UPDATE graph_derivative_versions SET value_hash=? WHERE id=?", [
                 Contracts.sha256("mutated observation"),
                 version
               ])

      next_version = Ecto.UUID.generate()
      next_hash = Contracts.digest(%{"value" => "Next public garden observation", "kind" => kind})
      insert_version!(next_version, auth, child, object, 2, next_hash, version, kind)
      successor = local(auth, cert, child, [version_row(kind, next_version, next_hash)])
      assert successor["state"] == "sealed"

      assert {:error, _} =
               Repo.query(
                 "INSERT INTO graph_derivative_versions(id,workspace_id,partition_id,object_kind,object_id,version,value_hash,manifest_id,predecessor_id,state,inserted_at) VALUES(?,?,?,?,?,2,?,?,?,'staging',?)",
                 [
                   Ecto.UUID.generate(),
                   Store.workspace(),
                   auth.partition_id,
                   kind,
                   object <> "-different",
                   next_hash,
                   child["manifest_id"],
                   version,
                   Corpora.now()
                 ]
               )

      other_kind = if kind == "rendered_message", do: "embed_input", else: "rendered_message"

      for bad <- [
            version_row(other_kind, version, hash),
            version_row(kind, version, Contracts.sha256("wrong observed value")),
            version_row(kind, Ecto.UUID.generate(), hash)
          ] do
        assert_rejected_version_row(auth, cert, bad)
      end

      other = garden(1)
      {other_cert, other_auth} = certify(other)
      other_input = local(other_auth, other_cert, other_cert, [])
      other_version = Ecto.UUID.generate()
      insert_version!(other_version, other_auth, other_input, object, 1, hash, nil, kind)
      assert_rejected_version_row(auth, cert, version_row(kind, other_version, hash))

      assert {:ok, unsealed} =
               GraphManifests.begin_manifest(auth, "derivative", local_context(auth, cert))

      unsealed_version = Ecto.UUID.generate()

      assert {:error, _} =
               Repo.query(
                 "INSERT INTO graph_derivative_versions(id,workspace_id,partition_id,object_kind,object_id,version,value_hash,manifest_id,state,inserted_at) VALUES(?,?,?,?,?,1,?,?,'staging',?)",
                 [
                   unsealed_version,
                   Store.workspace(),
                   auth.partition_id,
                   kind,
                   object <> "-unsealed",
                   hash,
                   unsealed["manifest_id"],
                   Corpora.now()
                 ]
               )

      assert [[0]] =
               Repo.query!("SELECT count(*) FROM graph_derivative_versions WHERE id=?", [
                 unsealed_version
               ]).rows

      assert {:error, :closure_incomplete} =
               GraphManifests.append_page(
                 unsealed["manifest_id"],
                 page(0, 0, nil, true, [version_row(kind, unsealed_version, hash)]),
                 auth
               )

      assert {:ok, self_parent} =
               GraphManifests.begin_manifest(auth, "derivative", local_context(auth, cert))

      self_row =
        parent_row(%{
          "manifest_id" => self_parent["manifest_id"],
          "digest" => Contracts.sha256("uncertified self parent")
        })

      assert {:error, :closure_incomplete} =
               GraphManifests.append_page(
                 self_parent["manifest_id"],
                 page(0, 0, nil, true, [typed, self_row]),
                 auth
               )

      assert {:ok, _} =
               GraphManifests.validate_current(child["manifest_id"], child["digest"], auth)
    end
  end

  test "one qualified graph catalogue pin admits distinct measured schemas and preserves inputs rules" do
    f = garden(1)
    {cert, auth} = certify(f)
    [pin] = auth.stage_pins
    assert pin["schema_digest"] == SchemaPolicy.digest()

    contexts =
      for prompt <- ~w(extract_nodes.extract_summary extract_nodes.extract_summaries_batch) do
        assert {:ok, entry} = SchemaPolicy.entry(pin, prompt)
        assert entry["schema_digest"] != pin["schema_digest"]

        context =
          local_context(auth, cert)
          |> Map.merge(%{
            "prompt_name" => prompt,
            "schema_digest" => entry["schema_digest"],
            "seam_id" => "llm.context.v1",
            "transform_id" => "graphiti_builder_v1"
          })

        sealed = seal_context(auth, context, [])

        assert {:ok, metadata} =
                 GraphManifests.validate_current(sealed["manifest_id"], sealed["digest"], auth)

        assert metadata["context"]["schema_digest"] == entry["schema_digest"]
        context
      end

    assert length(Enum.uniq(Enum.map(contexts, & &1["schema_digest"]))) == 2

    inputs =
      hd(contexts)
      |> Map.merge(%{
        "context_id" => Ecto.UUID.generate(),
        "graph_kind" => "inputs",
        "transform_id" => nil
      })

    assert seal_context(auth, inputs, [])["state"] == "sealed"

    assert {:error, :invalid_input} =
             GraphManifests.begin_manifest(
               auth,
               "derivative",
               Map.put(inputs, "transform_id", "graphiti_builder_v1")
             )
  end

  test "graph context schema policy rejects catalogue substitution and unqualified prompt stage seam or transform" do
    summary = stage_pin("garden-summary")
    extraction = stage_pin("garden-extraction", "extraction")
    f = garden(1, false, [summary, extraction])
    {cert, auth} = certify(f)
    context = local_context(auth, cert)
    assert {:ok, _} = GraphManifests.begin_manifest(auth, "derivative", context)

    assert {:ok, other_schema} =
             SchemaPolicy.entry(summary, "extract_nodes.extract_summaries_batch")

    for changed <- [
          %{"schema_digest" => SchemaPolicy.digest()},
          %{"schema_digest" => other_schema["schema_digest"]},
          %{"prompt_name" => "unknown.unqualified_prompt"},
          %{"stage_id" => extraction["id"], "config_digest" => extraction["config_digest"]},
          %{"seam_id" => "graphiti.extract_nodes.v1"},
          %{"transform_id" => "graphiti_extract_nodes_v1"},
          %{"config_digest" => Contracts.sha256("different graph stage configuration")}
        ] do
      rejected =
        context
        |> Map.merge(changed)
        |> Map.put("context_id", Ecto.UUID.generate())

      assert {:error, :stage_unavailable} =
               GraphManifests.begin_manifest(auth, "derivative", rejected)
    end

    # Scalar equality alone would accept this pin/context pair. A graph pin
    # must identify the whole qualified catalogue, not one actual descriptor.
    substituted =
      stage_pin("garden-substituted-catalogue")
      |> Map.put("schema_digest", context["schema_digest"])
      |> then(&Map.put(&1, "config_digest", Stages.fingerprint(&1)))

    invalid_fixture = garden(1, false, [substituted])
    {invalid_cert, invalid_auth} = certify(invalid_fixture)

    assert {:error, :stage_unavailable} =
             GraphManifests.begin_manifest(
               invalid_auth,
               "derivative",
               local_context(invalid_auth, invalid_cert)
             )
  end

  test "synthesis retains direct schema equality independently of the graph catalogue" do
    synthesis = stage_pin("garden-synthesis", "synthesis")
    f = garden(1, false, [synthesis])
    {cert, auth} = certify(f)

    context =
      local_context(auth, cert)
      |> Map.merge(%{
        "prompt_name" => "garden_synthesis",
        "schema_digest" => synthesis["schema_digest"],
        "seam_id" => "garden_synthesis_fixture",
        "transform_id" => "garden_synthesis_fixture_v1"
      })

    assert seal_context(auth, context, [])["state"] == "sealed"

    assert {:error, :stage_unavailable} =
             GraphManifests.begin_manifest(
               auth,
               "derivative",
               context
               |> Map.put("context_id", Ecto.UUID.generate())
               |> Map.put("schema_digest", SchemaPolicy.digest())
             )
  end

  defp garden(count, large? \\ false, pins \\ nil) do
    directory = Path.join(System.tmp_dir!(), "graph-garden-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Public synthetic garden",
        "provider" => "local",
        "directory" => directory
      })

    sources =
      for n <- 1..count do
        body =
          if n == 1 and large?,
            do: String.duplicate("Public garden observation.\n", 20_000),
            else: "Public garden observation #{n}."

        {:ok, source} =
          Evidence.import_markdown(connection["id"], %{
            "external_id" => "garden-#{n}.md",
            "title" => "Garden #{n}",
            "body" => body
          })

        source
      end

    {:ok, corpus} = Corpora.create(%{"name" => "Public garden source scope"}, caller())

    for batch <- Enum.chunk_every(sources, 100) do
      {:ok, current} = Corpora.get(corpus["id"])

      {:ok, _} =
        Corpora.apply_members(
          current.id,
          current.semantic_generation,
          Enum.map(
            batch,
            &%{
              "source_id" => &1["id"],
              "revision_id" => &1["latest_revision"]["id"],
              "action" => "include"
            }
          ),
          caller()
        )
    end

    {:ok, current} = Corpora.get(corpus["id"])

    rows =
      Enum.map(sources, fn source ->
        blank_row()
        |> Map.merge(%{
          "dependency_key" => "source_revision:" <> source["latest_revision"]["id"],
          "kind" => "source_revision",
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "content_hash" => source["latest_revision"]["body_hash"],
          "role" => "uncited"
        })
      end)
      |> Enum.sort_by(& &1["source_id"])

    source_digest = independent_source_digest(rows)

    bundle = %{
      "fixture" => "synthetic-garden-not-production-qualified",
      "backend" => "no-backend",
      "runtime" => "no-model-calls"
    }

    backend = Contracts.digest(bundle)
    partition = Ecto.UUID.generate()
    group = "hf_garden_" <> String.replace(partition, "-", "")

    Repo.query!(
      "INSERT INTO graph_partition_controls(id,workspace_id,corpus_id,group_id,semantic_generation,authorization_generation,cancel_epoch,state,lock_version,source_lock_digest,backend_pin_digest,authority_json,inserted_at,updated_at) VALUES(?,?,?,?,?,?,0,'staging',1,?,?,?,?,?)",
      [
        partition,
        Store.workspace(),
        current.id,
        group,
        current.semantic_generation,
        current.authorization_generation,
        source_digest,
        backend,
        Contracts.canonical_json(bundle),
        Corpora.now(),
        Corpora.now()
      ]
    )

    pins = pins || [stage_pin("garden-summary")]

    for pin <- pins do
      assert {:ok, _} = StageAuthority.create_pin(pin, caller())
    end

    auth = %StageAuthority{
      workspace_id: Store.workspace(),
      operation_id: Ecto.UUID.generate(),
      scope_ref: group,
      manifest_id: nil,
      manifest_digest: nil,
      stage_pins: pins,
      semantic_generation: current.semantic_generation,
      authorization_generation: current.authorization_generation,
      cancel_epoch: 0,
      deadline_at: DateTime.add(Store.now(), 3600, :second),
      caller: caller(),
      partition_id: partition,
      lease_id: Ecto.UUID.generate(),
      worker_session_id: Ecto.UUID.generate(),
      corpus_id: current.id,
      operation_type: "ingest",
      partition_lock_version: 1,
      source_lock_digest: source_digest,
      backend_pin_digest: backend
    }

    {:ok, opened} = StageControl.open(auth)
    %{auth: opened, rows: rows, corpus: current, source_digest: source_digest}
  end

  defp certify(f) do
    {:ok, started} = GraphManifests.begin_manifest(f.auth, "partition", source_context())
    append_pages(started["manifest_id"], Enum.chunk_every(f.rows, 100), f.auth)

    {:ok, _} =
      GraphManifests.finish_manifest(
        started["manifest_id"],
        %{"dependency_count" => length(f.rows), "source_count" => length(f.rows)},
        f.auth
      )

    final = validate_until_sealed(started["manifest_id"], f.auth, div(length(f.rows), 100) + 2)
    {:ok, auth} = StageControl.bind_graph_manifest(f.auth, final["manifest_id"], final["digest"])
    {final, auth}
  end

  defp local(auth, cert, base, rows) do
    context =
      local_context(auth, cert)
      |> Map.merge(%{
        "base_context_ref" => base["manifest_id"],
        "base_context_digest" => base["digest"]
      })

    seal_context(auth, context, rows)
  end

  defp seal_context(auth, context, rows) do
    {:ok, started} = GraphManifests.begin_manifest(auth, "derivative", context)

    {:ok, _} =
      GraphManifests.append_page(started["manifest_id"], page(0, 0, nil, true, rows), auth)

    {:ok, _} =
      GraphManifests.finish_manifest(
        started["manifest_id"],
        %{
          "dependency_count" => length(rows),
          "source_count" => Enum.count(rows, &(&1["kind"] == "source_revision"))
        },
        auth
      )

    validate_until_sealed(started["manifest_id"], auth, 2)
  end

  defp validate_until_sealed(id, auth, remaining) when remaining > 0 do
    {:ok, status} = GraphManifests.advance_validation(id, auth)

    if status["state"] == "sealed",
      do: status,
      else: validate_until_sealed(id, auth, remaining - 1)
  end

  defp append_pages(id, pages, auth) do
    Enum.with_index(pages)
    |> Enum.reduce({[], nil}, fn {rows, index}, {acks, previous} ->
      first = Enum.reduce(acks, 0, fn ack, count -> max(count, ack["next_ordinal"]) end)

      {:ok, ack} =
        GraphManifests.append_page(
          id,
          page(index, first, previous, index == length(pages) - 1, rows),
          auth
        )

      {acks ++ [ack], ack["page_digest"]}
    end)
  end

  defp page(index, first, previous, final, rows),
    do: %{
      "page_index" => index,
      "first_ordinal" => first,
      "previous_page_digest" => previous,
      "final" => final,
      "rows" => rows
    }

  defp source_context, do: Map.new(@context, &{&1, nil}) |> Map.put("graph_kind", "operation")

  defp local_context(auth, cert) do
    [pin | _] = auth.stage_pins

    source_context()
    |> Map.merge(%{
      "graph_kind" => "derived",
      "operation_manifest_ref" => cert["manifest_id"],
      "operation_manifest_digest" => cert["digest"],
      "base_context_ref" => cert["manifest_id"],
      "base_context_digest" => cert["digest"],
      "context_id" => Ecto.UUID.generate(),
      "logical_call_id" => "garden-call-" <> Ecto.UUID.generate(),
      "stage_id" => pin["id"],
      "config_digest" => pin["config_digest"],
      "prompt_name" => "graphiti.summary_flight.v1",
      "schema_digest" => Contracts.digest(%{"seam" => "graphiti.summary_flight.v1", "v" => 1}),
      "seam_id" => "graphiti.summary_flight.v1",
      "transform_id" => "graphiti_summary_flight_v1"
    })
    |> then(fn context ->
      assert auth.manifest_id == cert["manifest_id"]
      context
    end)
  end

  defp blank_row, do: Map.new(@row, &{&1, nil})

  defp parent_row(parent),
    do:
      blank_row()
      |> Map.merge(%{
        "dependency_key" => "manifest:" <> parent["manifest_id"],
        "kind" => "manifest",
        "parent_manifest_id" => parent["manifest_id"],
        "content_hash" => parent["digest"],
        "role" => "transitive"
      })

  defp version_row(kind, version, hash),
    do:
      blank_row()
      |> Map.merge(%{
        "dependency_key" => kind <> ":" <> version <> ":identity_v1",
        "kind" => kind,
        "derivative_version_id" => version,
        "content_hash" => hash,
        "role" => "transitive",
        "projection_id" => "identity_v1",
        "projection_hash" => hash
      })

  defp assert_rejected_version_row(auth, cert, row) do
    assert {:ok, started} =
             GraphManifests.begin_manifest(auth, "derivative", local_context(auth, cert))

    assert {:error, :closure_incomplete} =
             GraphManifests.append_page(
               started["manifest_id"],
               page(0, 0, nil, true, [row]),
               auth
             )
  end

  defp independent_source_digest(rows) do
    initial = Contracts.sha256("HF-GRAPH-SOURCE-ROWS-v1\n")

    hash =
      rows
      |> Enum.with_index()
      |> Enum.reduce(initial, fn {row, ordinal}, hash ->
        bytes =
          Contracts.canonical_json(%{
            "source_id" => row["source_id"],
            "revision_id" => row["revision_id"],
            "body_hash" => row["content_hash"]
          })

        Contracts.sha256(
          <<Base.decode16!(hash, case: :lower)::binary, ordinal::unsigned-big-64,
            byte_size(bytes)::unsigned-big-64, bytes::binary>>
        )
      end)

    Contracts.digest(%{
      "format" => "graph-source-set-v1",
      "rows_hash" => hash,
      "source_count" => length(rows)
    })
  end

  defp independent_row_chain(rows, page_size) do
    rows
    |> Enum.chunk_every(page_size)
    |> Enum.reduce(Contracts.sha256("HF-GRAPH-MANIFEST-ROWS-v2\n"), fn page, previous ->
      Enum.reduce(page, previous, fn row, hash ->
        bytes = Contracts.canonical_json(row)

        Contracts.sha256(
          <<Base.decode16!(hash, case: :lower)::binary, row["ordinal"]::unsigned-big-64,
            byte_size(bytes)::unsigned-big-64, bytes::binary>>
        )
      end)
    end)
  end

  defp insert_version!(id, auth, input, object, version, hash, predecessor, kind \\ "summary") do
    Repo.query!(
      "INSERT INTO graph_derivative_versions(id,workspace_id,partition_id,object_kind,object_id,version,value_hash,manifest_id,predecessor_id,state,inserted_at) VALUES(?,?,?,?,?,?,?,?,?,'staging',?)",
      [
        id,
        Store.workspace(),
        auth.partition_id,
        kind,
        object,
        version,
        hash,
        input["manifest_id"],
        predecessor,
        Corpora.now()
      ]
    )
  end

  defp stage_pin(model, stage \\ "summary") do
    pin = %{
      "id" => Ecto.UUID.generate(),
      "stage" => stage,
      "provider" => "ollama",
      "model" => model,
      "endpoint" => "http://127.0.0.1:11434/v1/chat/completions",
      "route_id" =>
        if(stage == "synthesis", do: "company_synthesis_v2", else: "graphiti_" <> stage),
      "credential_ref" => nil,
      "prompt_digest" =>
        if(stage == "synthesis",
          do: Contracts.sha256("garden synthesis prompt"),
          else: SchemaPolicy.prompt_policy_digest(stage)
        ),
      "schema_digest" =>
        if(stage == "synthesis",
          do: Contracts.digest(HarnessForge.Models.CompanyAnalysis.schema()),
          else: SchemaPolicy.digest()
        ),
      "consent_revision" => 1,
      "input_rate" => 0,
      "output_rate" => 0,
      "max_output_tokens" => 100,
      "timeout_ms" => 1000
    }

    Map.put(pin, "config_digest", Stages.fingerprint(pin))
  end

  defp drain_queries(acc) do
    receive do
      {:manifest_query, sql, result} -> drain_queries([{sql, result} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("graph garden caller"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
end
