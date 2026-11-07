defmodule HarnessForge.Graphiti.ObservationLedgerTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.{Contracts, Evidence, Repo}
  alias HarnessForge.Evidence.{Corpora, GraphManifests, GraphSources, Store}
  alias HarnessForge.Graphiti.{ObservationLedger, Protocol, SchemaPolicy}
  alias HarnessForge.Models.{StageAttempt, StageAuthority, StageConsent, Stages}

  @moduletag :metadata_only
  @input_marker "PUBLIC_SYNTHETIC_LEDGER_INPUT_NOT_PERSISTED"
  @message_marker "PUBLIC_SYNTHETIC_LEDGER_MESSAGE_NOT_PERSISTED"
  @response_marker "PUBLIC_SYNTHETIC_LEDGER_RESPONSE_NOT_PERSISTED"
  @context ~w(graph_kind operation_manifest_ref operation_manifest_digest base_context_ref base_context_digest context_id logical_call_id seam_id stage_id prompt_name config_digest schema_digest raw_body_sha256 rendered_projection_digest transform_id receipt_ref receipt_digest)
  @row ~w(dependency_key kind source_id revision_id content_hash role episode_binding_id derivative_version_id projection_id projection_hash parent_manifest_id)
  @artifacts ~w(dependency_manifests graph_manifest_builds graph_manifest_pages origin_dependencies graph_derivative_versions graph_observation_calls graph_observation_events)

  setup do
    previous = Application.get_env(:harness_forge, :graph_runtime_authority)

    directory =
      Path.join(System.tmp_dir!(), "metadata-only-observation-ledger-" <> Ecto.UUID.generate())

    File.mkdir_p!(directory)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:harness_forge, :graph_runtime_authority),
        else: Application.put_env(:harness_forge, :graph_runtime_authority, previous)

      File.rm_rf!(directory)
    end)

    # This registry qualifies synthetic metadata controls only. No worker,
    # backend, provider request, executable measurement or billing is exercised.
    {:ok, bundle} =
      GraphSources.runtime_bundle(%{
        "worker_image" => "sha256:" <> String.duplicate("1", 64),
        "backend_image" => "sha256:" <> String.duplicate("2", 64),
        "backend_instance" => "metadata-only-observation-ledger",
        "database" => "neo4j",
        "index_identity" => "metadata-only-ledger-index-v1"
      })

    Application.put_env(:harness_forge, :graph_runtime_authority, %{
      "qualified" => true,
      "bundle" => bundle,
      "qualification_ref" => "metadata-only-ledger-tests"
    })

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Public synthetic ledger metadata",
        "provider" => "local",
        "directory" => directory
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "public-garden.md",
        "title" => "Public synthetic garden",
        "body" => "A public synthetic garden record for metadata ledger tests."
      })

    {:ok, corpus} = Corpora.create(%{"name" => "One public synthetic ledger source"}, caller())

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

    {:ok, partition} = GraphSources.start(corpus["id"], caller())

    scanned =
      Enum.reduce_while(1..4, nil, fn _, _ ->
        assert {:ok, status} = GraphSources.advance(partition["partition_id"], caller())
        if status["state"] == "complete", do: {:halt, status}, else: {:cont, status}
      end)

    assert scanned["state"] == "complete" and scanned["source_count"] == 1
    pin = extraction_pin()
    assert :ok = SchemaPolicy.validate_pin(pin)
    {:ok, _} = StageAuthority.create_pin(pin, caller())

    {:ok, auth} =
      StageAuthority.new_graph(
        Ecto.UUID.generate(),
        "ingest",
        partition["partition_id"],
        [pin["id"]],
        "metadata-only-ledger-session",
        caller()
      )

    cert =
      Enum.reduce_while(1..8, nil, fn _, _ ->
        assert {:ok, status} = GraphSources.certificate_step(auth)
        if status["phase"] == "sealed", do: {:halt, status}, else: {:cont, status}
      end)

    assert cert["phase"] == "sealed" and cert["effective_source_count"] == 1
    {:ok, auth} = StageAuthority.bind_graph_manifest(auth, cert["manifest_id"], cert["digest"])

    assert {:ok, _} =
             GraphManifests.validate_scope_certificate(
               auth.manifest_id,
               auth.manifest_digest,
               auth
             )

    {:ok, descriptor} = SchemaPolicy.entry(pin, "extract_nodes.extract_text")

    %{auth: auth, pin: pin, descriptor: descriptor, logical_call: Ecto.UUID.generate()}
  end

  test "exact wire replay returns its original ACK without advancing the persisted call", f do
    page = wire(f, :inputs)
    assert {:ok, nil} = ObservationLedger.lookup(f.auth, page)

    assert {:ok, %{sequence: 0, state: nil}} =
             ObservationLedger.call_state(f.auth, f.logical_call)

    assert {:ok, committed} = commit(f, page, 0)
    ack = committed.ack
    counts = artifact_counts()
    assert {:ok, before} = ObservationLedger.call_state(f.auth, f.logical_call)
    assert before.sequence == 1

    for _ <- 1..3 do
      assert {:ok, ^ack} = ObservationLedger.lookup(f.auth, page)
      assert {:ok, ^before} = ObservationLedger.call_state(f.auth, f.logical_call)
    end

    # Keep every DTO/hash binding valid, while changing the full wire event.
    changed =
      Map.put(page, "entries", [
        entry(
          f,
          "deterministic_output",
          %{"query" => "Different public synthetic query"},
          "graphiti_context_v1"
        )
      ])

    changed = Map.put(changed, "rendered_projection_digest", Contracts.digest(changed["entries"]))
    assert :ok = Protocol.validate_payload("context_page", changed)
    refute Protocol.context_page_digest(changed) == Protocol.context_page_digest(page)
    assert {:error, :changed_replay} = ObservationLedger.lookup(f.auth, changed)
    assert {:ok, ^before} = ObservationLedger.call_state(f.auth, f.logical_call)
    assert artifact_counts() == counts
  end

  test "invalid ACK versions stale sequence and event conflict roll back the complete P V C transaction",
       f do
    input = wire(f, :inputs)
    assert {:ok, first} = commit(f, input, 0)
    messages = wire(f, :messages, handle(first.ack))
    baseline = artifact_counts()
    assert {:ok, previous} = ObservationLedger.call_state(f.auth, f.logical_call)

    cases = [
      {messages, 1,
       [
         ack: fn ack ->
           put_in(ack, ["version_refs", Access.at(0), "version_ref"], Ecto.UUID.generate())
         end
       ]},
      {messages, 1, [ack: &Map.put(&1, "version_refs", [])]},
      {messages, 0, []},
      {messages, 1, [version: &Map.put(&1, "kind", "deterministic_output")]},
      {messages, 1,
       [version: &Map.put(&1, "value_hash", Contracts.sha256("wrong stored value"))]},
      {messages, 1, [version: &Map.put(&1, "projection_id", "identity_v1")]},
      # This failure is after write_call's CAS, at the event uniqueness check.
      {Map.put(messages, "context_id", input["context_id"]), 1, []}
    ]

    for {page, sequence, options} <- cases do
      assert {:error, :closure_incomplete} = commit(f, page, sequence, options)
      assert artifact_counts() == baseline
      assert {:ok, ^previous} = ObservationLedger.call_state(f.auth, f.logical_call)
      assert [] == Repo.query!("PRAGMA foreign_key_check", []).rows
    end

    assert {:ok, second} = commit(f, messages, 1)
    assert second.state["step"] == "messages"
    assert {:ok, %{sequence: 2}} = ObservationLedger.call_state(f.auth, f.logical_call)
  end

  test "persisted capsules ACKs and immutable event identities contain no observed bodies", f do
    %{input: input, messages: messages, binding: binding} = bind_chain(f)

    rows =
      Repo.query!(
        "SELECT e.wire_digest,e.ack_json,c.state_json FROM graph_observation_events e JOIN graph_observation_calls c ON c.workspace_id=e.workspace_id AND c.operation_id=e.operation_id AND c.logical_call_id=e.logical_call_id WHERE e.workspace_id=? AND e.operation_id=? ORDER BY e.context_id",
        [Store.workspace(), f.auth.operation_id]
      ).rows

    assert length(rows) == 3

    for [digest, ack_json, capsule_json] <- rows do
      assert Stages.digest?(digest)
      assert {:ok, ack} = Contracts.decode_json(ack_json)
      assert :ok = Protocol.validate_payload("context_ack", ack)
      assert {:ok, capsule} = Contracts.decode_json(capsule_json)
      assert capsule["step"] == "bound" and capsule["pending_bind"] == handle(binding.ack)

      for marker <- [@input_marker, @message_marker, @response_marker] do
        refute String.contains?(ack_json <> capsule_json, marker)
      end

      refute Map.has_key?(capsule, "entries")
      refute Map.has_key?(capsule, "body")
      refute Map.has_key?(capsule, "messages")
    end

    assert_sql_denied(
      "UPDATE graph_observation_events SET wire_digest=? WHERE context_id=?",
      [Contracts.sha256("changed wire"), input.page["context_id"]],
      "immutable graph observation event"
    )

    assert_sql_denied(
      "UPDATE graph_observation_events SET ack_json=? WHERE context_id=?",
      [
        Contracts.canonical_json(
          Map.put(messages.ack, "page_digest", Contracts.sha256("changed ACK"))
        ),
        messages.page["context_id"]
      ],
      "immutable graph observation event"
    )

    assert_sql_denied(
      "DELETE FROM graph_observation_events WHERE context_id=?",
      [input.page["context_id"]],
      "immutable corpus record"
    )

    assert_sql_denied(
      "UPDATE graph_observation_calls SET config_digest=?,call_version=call_version+1 WHERE operation_id=?",
      [Contracts.sha256("changed call config"), f.auth.operation_id],
      "invalid graph observation call transition"
    )

    assert_sql_denied(
      "UPDATE graph_observation_calls SET call_version=call_version+2 WHERE operation_id=?",
      [f.auth.operation_id],
      "invalid graph observation call transition"
    )

    Repo.query!(
      "UPDATE graph_observation_calls SET state='denied',call_version=call_version+1 WHERE operation_id=?",
      [f.auth.operation_id]
    )

    assert_sql_denied(
      "UPDATE graph_observation_calls SET state='active',call_version=call_version+1 WHERE operation_id=?",
      [f.auth.operation_id],
      "invalid graph observation call transition"
    )

    assert_sql_denied(
      "DELETE FROM graph_observation_calls WHERE operation_id=?",
      [f.auth.operation_id],
      "immutable corpus record"
    )
  end

  test "a metadata-only reserved attempt consumes its binding once and ACK replay cannot rearm it",
       f do
    %{binding: binding} = bind_chain(f)
    before_requests = count_rows("model_requests")
    assert {:ok, reserved} = reserve_and_consume(f, binding)

    assert [[nil, "reserved"]] =
             Repo.query!(
               "SELECT model_request_id,state FROM stage_attempts WHERE id=?",
               [reserved.attempt_id]
             ).rows

    assert [["consumed", reserved.attempt_id]] ==
             Repo.query!(
               "SELECT binding_state,consumed_attempt_id FROM graph_observation_events WHERE context_id=?",
               [binding.page["context_id"]]
             ).rows

    assert count_rows("model_requests") == before_requests
    ack = binding.ack
    assert {:ok, ^ack} = ObservationLedger.lookup(f.auth, binding.page)

    assert {:ok, %{sequence: 3, state: state}} =
             ObservationLedger.call_state(f.auth, f.logical_call)

    assert state["pending_bind"] == handle(ack)

    assert {:error, :closure_incomplete} =
             Store.transaction(fn ->
               with :ok <- ObservationLedger.consume_binding(f.auth, reserved.attempt),
                    do: {:ok, :consumed_twice}
             end)

    assert {:ok, ^ack} = ObservationLedger.lookup(f.auth, binding.page)

    assert_sql_denied(
      "UPDATE graph_observation_events SET binding_state='unused',consumed_attempt_id=NULL WHERE context_id=?",
      [binding.page["context_id"]],
      "immutable graph observation event"
    )

    assert [["consumed", reserved.attempt_id]] ==
             Repo.query!(
               "SELECT binding_state,consumed_attempt_id FROM graph_observation_events WHERE context_id=?",
               [binding.page["context_id"]]
             ).rows

    assert [] == Repo.query!("PRAGMA foreign_key_check", []).rows
  end

  test "finished metadata-only calls preserve their final ACK and cannot resume", f do
    %{messages: messages, binding: binding} = bind_chain(f)
    assert {:ok, reserved} = reserve_and_consume(f, binding)
    raw = Contracts.canonical_json(%{"result" => @response_marker})

    # A synthetic settled receipt row exercises metadata/flow only. It has no
    # ModelRequest and does not establish provider usage, billing or truth.
    Repo.query!(
      "UPDATE stage_attempts SET state='completed',result_hash=?,response_status=200,response_bytes=?,updated_at=? WHERE id=?",
      [Contracts.sha256(raw), byte_size(raw), Corpora.now(), reserved.attempt_id]
    )

    physical =
      wire(f, :physical, handle(messages.ack),
        parents: [handle(binding.ack)],
        receipt: reserved.attempt_id,
        response: raw
      )

    assert {:ok, response} = commit(f, physical, 3)
    logical = wire(f, :logical, handle(response.ack), parents: [handle(response.ack)])
    assert {:ok, finished} = commit(f, logical, 4)
    assert finished.state["finished"]

    assert [[5, "finished"]] ==
             Repo.query!(
               "SELECT call_version,state FROM graph_observation_calls WHERE operation_id=?",
               [f.auth.operation_id]
             ).rows

    ack = finished.ack
    assert {:ok, ^ack} = ObservationLedger.lookup(f.auth, logical)
    baseline = artifact_counts()
    resumed = wire(f, :logical, handle(finished.ack), parents: [handle(response.ack)])
    assert {:error, :closure_incomplete} = commit(f, resumed, 5)
    assert artifact_counts() == baseline

    assert_sql_denied(
      "UPDATE graph_observation_calls SET state='active',call_version=call_version+1 WHERE operation_id=?",
      [f.auth.operation_id],
      "invalid graph observation call transition"
    )

    assert {:ok, ^ack} = ObservationLedger.lookup(f.auth, logical)

    persisted =
      Repo.query!(
        "SELECT e.ack_json,c.state_json FROM graph_observation_events e JOIN graph_observation_calls c ON c.workspace_id=e.workspace_id AND c.operation_id=e.operation_id AND c.logical_call_id=e.logical_call_id WHERE e.operation_id=?",
        [f.auth.operation_id]
      ).rows

    for [ack_json, capsule_json] <- persisted do
      refute String.contains?(ack_json <> capsule_json, @response_marker)
    end

    assert [] == Repo.query!("PRAGMA foreign_key_check", []).rows
  end

  defp commit(f, page, sequence, options \\ []) do
    Store.transaction(fn ->
      assert Repo.in_transaction?()
      built = materialize(f, page, options)
      ack = Keyword.get(options, :ack, &Function.identity/1).(built.ack)

      with {:ok, state} <- ObservationLedger.append(f.auth, page, ack, sequence),
           do: {:ok, Map.merge(built, %{ack: ack, page: page, state: state})}
    end)
  end

  defp materialize(f, page, options) do
    # P and C have distinct root-internal identities, independent of wire ID.
    parent = seal(f.auth, context(f, page, "inputs", nil), provenance(f, page))

    versions =
      Enum.map(page["entries"], fn observed ->
        stored = Keyword.get(options, :version, &Function.identity/1).(observed)
        id = Ecto.UUID.generate()

        Repo.query!(
          "INSERT INTO graph_derivative_versions(id,workspace_id,partition_id,object_kind,object_id,version,value_hash,manifest_id,state,inserted_at) VALUES(?,?,?,?,?,1,?,?,'staging',?)",
          [
            id,
            Store.workspace(),
            f.auth.partition_id,
            stored["kind"],
            Ecto.UUID.generate(),
            stored["value_hash"],
            parent["manifest_id"],
            Corpora.now()
          ]
        )

        %{id: id, entry: observed, stored: stored}
      end)

    kind = if page["phase"] == "attempt_bind", do: "attempt_bind", else: "derived"
    consuming_context = context(f, page, kind, parent)

    consuming_context =
      case page["entries"] do
        [%{"receipt_ref" => receipt}] when is_binary(receipt) ->
          [[hash]] =
            Repo.query!(
              "SELECT result_hash FROM stage_attempts WHERE id=? AND state='completed'",
              [receipt]
            ).rows

          Map.merge(consuming_context, %{"receipt_ref" => receipt, "receipt_digest" => hash})

        _ ->
          consuming_context
      end

    consuming =
      seal(f.auth, consuming_context, [
        parent_row(handle(parent)) | Enum.map(versions, &version_row/1)
      ])

    ack = %{
      "job_id" => f.auth.operation_id,
      "context_id" => page["context_id"],
      "page_index" => 0,
      "page_digest" => Protocol.context_page_digest(page),
      "state" => "sealed",
      "version_refs" =>
        Enum.map(versions, &%{"entry_id" => &1.entry["entry_id"], "version_ref" => &1.id}),
      "context_manifest_ref" => consuming["manifest_id"],
      "context_manifest_digest" => consuming["digest"],
      "allowed_body_sha256" => page["raw_body_sha256"],
      "error_code" => nil
    }

    %{ack: ack, parent: parent, consuming: consuming, versions: versions}
  end

  defp context(f, page, kind, parent) do
    Map.new(@context, &{&1, nil})
    |> Map.merge(%{
      "graph_kind" => kind,
      "operation_manifest_ref" => f.auth.manifest_id,
      "operation_manifest_digest" => f.auth.manifest_digest,
      "context_id" => Ecto.UUID.generate(),
      "logical_call_id" => page["logical_call_id"],
      "seam_id" => page["seam_id"],
      "stage_id" => page["stage_id"],
      "prompt_name" => page["prompt_name"],
      "config_digest" => page["config_digest"],
      "schema_digest" => page["schema_digest"],
      "base_context_ref" => if(parent, do: parent["manifest_id"], else: page["base_context_ref"]),
      "base_context_digest" =>
        if(parent, do: parent["digest"], else: page["base_context_digest"]),
      "transform_id" => if(kind != "inputs", do: page["transform_id"]),
      "raw_body_sha256" => if(kind == "attempt_bind", do: page["raw_body_sha256"]),
      "rendered_projection_digest" =>
        if(kind == "attempt_bind", do: page["rendered_projection_digest"])
    })
  end

  defp provenance(f, page) do
    base =
      if page["base_context_ref"],
        do: [
          %{
            "manifest_ref" => page["base_context_ref"],
            "manifest_digest" => page["base_context_digest"]
          }
        ],
        else: []

    [
      %{"manifest_ref" => f.auth.manifest_id, "manifest_digest" => f.auth.manifest_digest}
      | base ++ page["parent_contexts"]
    ]
    |> Enum.uniq_by(& &1["manifest_ref"])
    |> Enum.map(&parent_row/1)
  end

  defp seal(auth, context, rows) do
    assert length(rows) <= 100
    assert {:ok, started} = GraphManifests.begin_manifest(auth, "derivative", context)

    assert {:ok, _} =
             GraphManifests.append_page(
               started["manifest_id"],
               %{
                 "page_index" => 0,
                 "first_ordinal" => 0,
                 "previous_page_digest" => nil,
                 "final" => true,
                 "rows" => rows
               },
               auth
             )

    assert {:ok, _} =
             GraphManifests.finish_manifest(
               started["manifest_id"],
               %{
                 "dependency_count" => length(rows),
                 "source_count" => 0
               },
               auth
             )

    assert {:ok, sealed} = GraphManifests.advance_validation(started["manifest_id"], auth)
    assert sealed["state"] == "sealed"
    sealed
  end

  defp parent_row(handle),
    do:
      Map.new(@row, &{&1, nil})
      |> Map.merge(%{
        "dependency_key" => "manifest:" <> handle["manifest_ref"],
        "kind" => "manifest",
        "parent_manifest_id" => handle["manifest_ref"],
        "content_hash" => handle["manifest_digest"],
        "role" => "transitive"
      })

  defp version_row(version),
    do:
      Map.new(@row, &{&1, nil})
      |> Map.merge(%{
        "dependency_key" =>
          version.stored["kind"] <> ":" <> version.id <> ":" <> version.stored["projection_id"],
        "kind" => version.stored["kind"],
        "derivative_version_id" => version.id,
        "content_hash" => version.stored["value_hash"],
        "role" => "transitive",
        "projection_id" => version.stored["projection_id"],
        "projection_hash" => version.stored["projection_hash"]
      })

  defp bind_chain(f) do
    assert {:ok, input} = commit(f, wire(f, :inputs), 0)
    assert {:ok, messages} = commit(f, wire(f, :messages, handle(input.ack)), 1)
    assert {:ok, binding} = commit(f, wire(f, :bind, handle(messages.ack)), 2)
    %{input: input, messages: messages, binding: binding}
  end

  defp reserve_and_consume(f, binding) do
    Store.transaction(fn ->
      consent =
        Repo.insert!(%StageConsent{
          id: Ecto.UUID.generate(),
          workspace_id: Store.workspace(),
          stage_config_id: f.pin["id"],
          revision: 1,
          state: "active",
          inserted_at: Store.now()
        })

      id = Ecto.UUID.generate()

      Repo.insert!(%StageAttempt{
        id: id,
        workspace_id: Store.workspace(),
        operation_id: f.auth.operation_id,
        logical_call_id: f.logical_call,
        ordinal: 1,
        stage_config_id: f.pin["id"],
        consent_id: consent.id,
        model_request_id: nil,
        worker_request_id: "metadata-only-reserved-" <> id,
        payload_hash: binding.page["raw_body_sha256"],
        manifest_id: f.auth.manifest_id,
        semantic_generation: f.auth.semantic_generation,
        authorization_generation: f.auth.authorization_generation,
        cancel_epoch: f.auth.cancel_epoch,
        deadline_at: f.auth.deadline_at,
        state: "reserved",
        inserted_at: Store.now(),
        updated_at: Store.now()
      })

      attempt = %{
        "attempt_id" => id,
        "logical_call_id" => f.logical_call,
        "context_manifest_ref" => binding.ack["context_manifest_ref"],
        "payload_sha256" => binding.page["raw_body_sha256"]
      }

      with :ok <- ObservationLedger.consume_binding(f.auth, attempt),
           do: {:ok, %{attempt_id: id, attempt: attempt}}
    end)
  end

  defp wire(f, kind, base \\ nil, options \\ []) do
    {seam, phase, transform, entries} =
      case kind do
        :inputs ->
          {"llm.context.v1", "inputs", "graphiti_builder_v1",
           [entry(f, "deterministic_output", %{"query" => @input_marker}, "graphiti_context_v1")]}

        :messages ->
          {"llm.messages.v1", "inputs", "graphiti_builder_v1",
           [
             entry(
               f,
               "rendered_message",
               %{"role" => "user", "content" => @message_marker},
               "messages_v1"
             )
           ]}

        :bind ->
          {"http.serialized.v1", "attempt_bind", "official_openai_chat_v1",
           [
             entry(
               f,
               "rendered_message",
               %{"role" => "user", "content" => @message_marker},
               "messages_v1"
             )
           ]}

        :physical ->
          raw = Keyword.fetch!(options, :response)
          receipt = Keyword.fetch!(options, :receipt)

          {"llm.response.v1", "derived", "model_response_v1",
           [
             entry(
               f,
               "deterministic_output",
               %{
                 "attempt_id" => receipt,
                 "http_status" => 200,
                 "body_bytes" => byte_size(raw),
                 "body_sha256" => Contracts.sha256(raw)
               },
               "identity_v1",
               receipt
             )
             |> Map.put("object_id", receipt)
           ]}

        :logical ->
          {"llm.response.v1", "derived", "model_response_v1",
           [entry(f, "deterministic_output", %{"result" => @response_marker}, "identity_v1")]}
      end

    raw =
      if kind == :bind,
        do:
          Contracts.canonical_json(%{
            "model" => f.pin["model"],
            "messages" => Enum.map(entries, & &1["value"]),
            "temperature" => 1,
            "max_tokens" => f.pin["max_output_tokens"],
            "response_format" => f.descriptor["physical_profile"]["response_format"]
          })

    page = %{
      "job_id" => f.auth.operation_id,
      "partition_id" => f.auth.partition_id,
      "lease_id" => f.auth.lease_id,
      "cancel_epoch" => f.auth.cancel_epoch,
      "semantic_generation" => f.auth.semantic_generation,
      "authorization_generation" => f.auth.authorization_generation,
      "operation_manifest_ref" => f.auth.manifest_id,
      "operation_manifest_digest" => f.auth.manifest_digest,
      "context_id" => Ecto.UUID.generate(),
      "logical_call_id" => f.logical_call,
      "stage_id" => f.pin["id"],
      "config_digest" => f.pin["config_digest"],
      "schema_digest" => f.descriptor["schema_digest"],
      "prompt_name" => f.descriptor["prompt_name"],
      "phase" => phase,
      "seam_id" => seam,
      "transform_id" => transform,
      "entries" => entries,
      "page_index" => 0,
      "previous_page_digest" => nil,
      "final" => true,
      "base_context_ref" => if(base, do: base["manifest_ref"]),
      "base_context_digest" => if(base, do: base["manifest_digest"]),
      "parent_contexts" => Keyword.get(options, :parents, []),
      "raw_body_sha256" => if(raw, do: Contracts.sha256(raw)),
      "rendered_projection_digest" => Contracts.digest(entries)
    }

    assert :ok = Protocol.validate_payload("context_page", page)
    page
  end

  defp entry(f, kind, value, projection, receipt \\ nil),
    do: %{
      "entry_id" => Ecto.UUID.generate(),
      "kind" => kind,
      "object_id" => f.logical_call,
      "version_ref" => nil,
      "predecessor_version_ref" => nil,
      "value" => value,
      "value_hash" => Contracts.digest(value),
      "projection_id" => projection,
      "projection_hash" => Contracts.digest(value),
      "parent_manifest_ref" => f.auth.manifest_id,
      "parent_manifest_digest" => f.auth.manifest_digest,
      "receipt_ref" => receipt
    }

  defp handle(%{"context_manifest_ref" => id, "context_manifest_digest" => digest}),
    do: %{"manifest_ref" => id, "manifest_digest" => digest}

  defp handle(%{"manifest_id" => id, "digest" => digest}),
    do: %{"manifest_ref" => id, "manifest_digest" => digest}

  defp extraction_pin do
    pin = %{
      "id" => Ecto.UUID.generate(),
      "stage" => "extraction",
      "provider" => "ollama",
      "model" => "public-synthetic-metadata-only-v1",
      "endpoint" => "http://127.0.0.1:11434/v1/chat/completions",
      "route_id" => "graphiti_extraction",
      "credential_ref" => nil,
      "prompt_digest" => SchemaPolicy.prompt_policy_digest("extraction"),
      "schema_digest" => SchemaPolicy.digest(),
      "consent_revision" => 1,
      "input_rate" => 0,
      "output_rate" => 0,
      "max_output_tokens" => 100,
      "timeout_ms" => 1000
    }

    Map.put(pin, "config_digest", Stages.fingerprint(pin))
  end

  defp artifact_counts, do: Map.new(@artifacts, &{&1, count_rows(&1)})

  defp count_rows(table),
    do: Repo.query!("SELECT count(*) FROM " <> table, []).rows |> hd() |> hd()

  defp assert_sql_denied(sql, params, message) do
    assert {:error, error} = Repo.query(sql, params)
    assert Exception.message(error) =~ message
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("public-synthetic-observation-ledger"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]
end
