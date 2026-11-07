defmodule HarnessForge.Graphiti.RootObserverTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.Contracts
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Graphiti.{Protocol, RootObserver, SchemaPolicy, SearchIntent}
  alias HarnessForge.Models.{StageAuthority, Stages}

  @moduledoc """
  Pure packet/identity checks and refusal tests only. Synthetic control IDs are
  neither live Runtime authority nor a validated source intent. These tests do
  not mock either proof, invoke a worker/provider, or establish successful ingest.
  """

  setup do
    pin = %{
      "id" => Ecto.UUID.generate(),
      "stage" => "extraction",
      "provider" => "ollama",
      "model" => "public-packet-fixture-v1",
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

    pin = Map.put(pin, "config_digest", Stages.fingerprint(pin))

    auth = %StageAuthority{
      workspace_id: Store.workspace(),
      operation_id: Ecto.UUID.generate(),
      scope_ref: "public_packet_group",
      manifest_id: Ecto.UUID.generate(),
      manifest_digest: Contracts.sha256("synthetic certificate"),
      stage_pins: [pin],
      semantic_generation: 1,
      authorization_generation: 1,
      cancel_epoch: 0,
      deadline_at: DateTime.add(Store.now(), 60, :second),
      caller: [],
      partition_id: Ecto.UUID.generate(),
      lease_id: Ecto.UUID.generate(),
      worker_session_id: "metadata-only-packet-session",
      corpus_id: Ecto.UUID.generate(),
      operation_type: "ingest",
      partition_lock_version: 1,
      source_lock_digest: Contracts.sha256("source scope"),
      backend_pin_digest: Contracts.sha256("runtime bundle")
    }

    body = "Public synthetic café garden."

    args = %{
      "binding_id" => Ecto.UUID.generate(),
      "episode_uuid" => Ecto.UUID.generate(),
      "revision_id" => Ecto.UUID.generate(),
      "body_hash" => Contracts.sha256(body),
      "window_start" => 0,
      "window_end" => byte_size(body),
      "body" => body,
      "reference_time" => "2026-01-01T12:00:00Z",
      "time_basis" => "event",
      "prior_episode_ids" => []
    }

    job = %{
      "op" => "ingest",
      "job_id" => auth.operation_id,
      "idempotency_key" => Ecto.UUID.generate(),
      "scope_ref" => auth.scope_ref,
      "semantic_generation" => 1,
      "authorization_generation" => 1,
      "cancel_epoch" => 0,
      "closure_ref" => auth.manifest_id,
      "closure_digest" => auth.manifest_digest,
      "stage_set_digest" => StageAuthority.stage_set_digest(auth),
      "partition_id" => auth.partition_id,
      "lease_id" => auth.lease_id,
      "worker_session_id" => auth.worker_session_id,
      "deadline_ms" => 1000,
      "args" => args
    }

    assert :ok = Protocol.validate_payload("job", job)
    %{auth: auth, pin: pin, job: job, call: Ecto.UUID.generate()}
  end

  test "qualified packets bind the complete job control stage prompt and actual schema", f do
    page = model_page(f)
    assert :ok = RootObserver.validate_packet(f.auth, f.job, page)

    for {key, value} <- [
          {"job_id", Ecto.UUID.generate()},
          {"partition_id", Ecto.UUID.generate()},
          {"lease_id", Ecto.UUID.generate()},
          {"cancel_epoch", 1},
          {"semantic_generation", 2},
          {"authorization_generation", 2},
          {"operation_manifest_ref", Ecto.UUID.generate()},
          {"operation_manifest_digest", Contracts.sha256("substitution")},
          {"stage_id", Ecto.UUID.generate()},
          {"config_digest", Contracts.sha256("other config")},
          {"schema_digest", SchemaPolicy.digest()},
          {"prompt_name", "unknown.prompt"},
          {"seam_id", "graphiti.save.v1"},
          {"transform_id", "graphiti_save_v1"}
        ] do
      assert {:error, :closure_incomplete} =
               RootObserver.validate_packet(f.auth, f.job, Map.put(page, key, value))
    end

    for {key, value} <- [
          {"worker_session_id", "session:other"},
          {"scope_ref", "other_group"},
          {"closure_ref", Ecto.UUID.generate()},
          {"stage_set_digest", Contracts.sha256("other stage set")}
        ] do
      assert {:error, :closure_incomplete} =
               RootObserver.validate_packet(f.auth, Map.put(f.job, key, value), page)
    end
  end

  test "search packet accepts exact outer intent and native-normalized embedding only", f do
    pins =
      Enum.map(~w(extraction summary node_dedupe edge_dedupe embedder), fn stage ->
        pin =
          Map.merge(f.pin, %{
            "id" => Ecto.UUID.generate(),
            "stage" => stage,
            "route_id" => "graphiti_" <> stage,
            "prompt_digest" => SchemaPolicy.prompt_policy_digest(stage),
            "endpoint" =>
              "http://127.0.0.1:11434" <>
                if(stage == "embedder", do: "/v1/embeddings", else: "/v1/chat/completions")
          })

        Map.put(pin, "config_digest", Stages.fingerprint(pin))
      end)

    auth = %{f.auth | operation_type: "search", stage_pins: pins}
    pin = Enum.find(pins, &(&1["stage"] == "embedder"))

    job =
      f.job
      |> Map.put("op", "search")
      |> Map.put("stage_set_digest", StageAuthority.stage_set_digest(auth))
      |> Map.put("args", %{
        "query" => "  Public\nseedlings  ",
        "limit" => 10,
        "recipe_id" => "edge_hybrid_rrf_v1"
      })

    g = %{f | auth: auth, pin: pin, job: job}

    outer =
      model_page(f)
      |> Map.merge(%{
        "stage_id" => pin["id"],
        "config_digest" => pin["config_digest"],
        "schema_digest" => SchemaPolicy.search_schema_digest(),
        "prompt_name" => "graphiti.search.v1",
        "seam_id" => "graphiti.search.v1",
        "transform_id" => "root_search_intent_v1"
      })

    entries = [entry(g, "deterministic_output", SearchIntent.input(job), "identity_v1")]

    outer =
      Map.merge(outer, %{
        "entries" => entries,
        "rendered_projection_digest" => Contracts.digest(entries)
      })

    assert :ok = RootObserver.validate_packet(auth, job, outer)

    assert {:error, :closure_incomplete} =
             RootObserver.validate_packet(auth, put_in(job, ["args", "limit"], 11), outer)

    for value <- [
          %{
            "query" => "substituted",
            "limit" => 10,
            "recipe_id" => "edge_hybrid_rrf_v1",
            "group_id" => auth.scope_ref
          },
          Map.put(SearchIntent.input(job), "query_vector", [])
        ] do
      entries = [entry(g, "deterministic_output", value, "identity_v1")]

      changed =
        Map.merge(outer, %{
          "entries" => entries,
          "rendered_projection_digest" => Contracts.digest(entries)
        })

      assert {:error, :closure_incomplete} = RootObserver.validate_packet(auth, job, changed)
    end

    embed =
      packet(g, "embedder.create", "embedder.input.v1", "inputs", "identity_v1", [
        entry(g, "embed_input", SearchIntent.normalized_input(job), "embed_text_v1")
      ])

    assert :ok = RootObserver.validate_packet(auth, job, embed)

    for value <- [
          ["  Public\nseedlings  "],
          ["Public seedlings"],
          ["arbitrary query"],
          ["  Public seedlings  ", "extra"]
        ] do
      entries = [entry(g, "embed_input", value, "embed_text_v1")]

      assert {:error, :closure_incomplete} =
               RootObserver.validate_packet(
                 auth,
                 job,
                 Map.merge(embed, %{
                   "entries" => entries,
                   "rendered_projection_digest" => Contracts.digest(entries)
                 })
               )
    end

    assert {:error, :closure_incomplete} =
             RootObserver.validate_packet(
               auth,
               job,
               save_packet(f, %{"before" => %{}, "after" => %{}, "result" => nil})
             )
  end

  test "entry hashes and ordered whole-entry projection are mandatory without silent reordering",
       f do
    entries = [
      entry(
        f,
        "rendered_message",
        %{"role" => "system", "content" => "Public instructions"},
        "messages_v1"
      ),
      entry(
        f,
        "rendered_message",
        %{"role" => "user", "content" => "Public garden"},
        "messages_v1"
      )
    ]

    page =
      packet(
        f,
        "extract_nodes.extract_text",
        "llm.messages.v1",
        "inputs",
        "graphiti_builder_v1",
        entries
      )

    assert :ok = RootObserver.validate_packet(f.auth, f.job, page)

    assert {:error, :closure_incomplete} =
             RootObserver.validate_packet(
               f.auth,
               f.job,
               put_in(page, ["entries", Access.at(0), "value"], %{"content" => "changed"})
             )

    assert {:error, :closure_incomplete} =
             RootObserver.validate_packet(
               f.auth,
               f.job,
               put_in(
                 page,
                 ["entries", Access.at(0), "projection_hash"],
                 Contracts.sha256("changed projection")
               )
             )

    reversed = Map.put(page, "entries", Enum.reverse(entries))
    assert :ok = Protocol.validate_payload("context_page", reversed)
    assert {:error, :closure_incomplete} = RootObserver.validate_packet(f.auth, f.job, reversed)
    assert :ok = RootObserver.validate_packet(f.auth, f.job, rehash(reversed))
  end

  test "native snapshot and derivative identities preserve object type and UUID", f do
    episode = episode(f)

    page =
      packet(
        f,
        "graphiti.extract_nodes.v1",
        "graphiti.extract_nodes.v1",
        "inputs",
        "graphiti_extract_nodes_v1",
        [entry(f, "episode", episode, "identity_v1", f.job["args"]["episode_uuid"])]
      )

    id = f.job["args"]["episode_uuid"]

    assert {:ok, {"deterministic_output", "EpisodicNode:" <> ^id, true}} =
             RootObserver.entry_identity(page, hd(page["entries"]), 0)

    assert :ok = RootObserver.validate_packet(f.auth, f.job, page)

    node_id = Ecto.UUID.generate()

    node =
      native("EntityNode", %{
        "uuid" => node_id,
        "group_id" => f.auth.scope_ref,
        "summary" => "Public summary",
        "attributes" => %{}
      })

    snapshot = entry(f, "deterministic_output", node, "identity_v1", node_id)

    assert {:ok, {"deterministic_output", "EntityNode:" <> ^node_id, true}} =
             RootObserver.entry_identity(page, snapshot, 0)

    for kind <- ~w(summary attribute) do
      value = if kind == "summary", do: "Public summary", else: %{}

      assert {:ok, {^kind, "EntityNode:" <> ^node_id, true}} =
               RootObserver.entry_identity(page, entry(f, kind, value, "identity_v1", node_id), 1)
    end

    forged = Map.put(snapshot, "object_id", Ecto.UUID.generate())
    assert {:error, :closure_incomplete} = RootObserver.entry_identity(page, forged, 0)

    assert {:error, :closure_incomplete} =
             RootObserver.entry_identity(page, Map.put(snapshot, "kind", "edge"), 0)
  end

  test "rendered messages with one logical object ID have distinct context and ordinal identities",
       f do
    page = model_page(f)
    message = entry(f, "rendered_message", %{"content" => "Public message"}, "messages_v1")

    assert {:ok, {"rendered_message", first, false}} =
             RootObserver.entry_identity(page, message, 0)

    assert {:ok, {"rendered_message", second, false}} =
             RootObserver.entry_identity(page, message, 1)

    assert first != second

    assert {:ok, {"rendered_message", ^first, false}} =
             RootObserver.entry_identity(page, message, 0)

    assert {:ok, {"rendered_message", next_context, false}} =
             RootObserver.entry_identity(
               Map.put(page, "context_id", Ecto.UUID.generate()),
               message,
               0
             )

    assert next_context != first
    assert {:error, :closure_incomplete} = RootObserver.entry_identity(page, message, -1)
  end

  test "episode source snapshot cannot substitute root content name revision group reference time or UUID",
       f do
    fields = episode(f)["fields"]
    assert RootObserver.episode_job?(fields, f.job)

    for {key, value} <- [
          {"content", "Different public text"},
          {"name", Ecto.UUID.generate()},
          {"source_description", Ecto.UUID.generate()},
          {"group_id", "foreign_group"},
          {"valid_at", "2026-01-02T12:00:00Z"},
          {"uuid", Ecto.UUID.generate()},
          {"source", "json"}
        ] do
      changed = Map.put(fields, key, value)
      refute RootObserver.episode_job?(changed, f.job)
      value = native("EpisodicNode", changed)

      page =
        packet(
          f,
          "graphiti.extract_nodes.v1",
          "graphiti.extract_nodes.v1",
          "inputs",
          "graphiti_extract_nodes_v1",
          [entry(f, "episode", value, "identity_v1", changed["uuid"])]
        )

      assert {:error, :closure_incomplete} = RootObserver.validate_packet(f.auth, f.job, page)
    end
  end

  test "loader views use a separate operation-local stored identity", f do
    uuid = Ecto.UUID.generate()

    value = %{
      "object_type" => "EntityNode",
      "fields" => %{"uuid" => uuid, "attributes" => %{}},
      "vector_commitments" => %{}
    }

    entry = %{
      "kind" => "deterministic_output",
      "object_id" => "loader_view:EntityNode:" <> uuid,
      "projection_id" => "identity_v1",
      "value" => value
    }

    page = %{"job_id" => f.auth.operation_id}

    assert {:ok, {"deterministic_output", identity, true}} =
             RootObserver.entry_identity(page, entry, 0)

    assert identity == "loader_view:" <> f.auth.operation_id <> ":EntityNode:" <> uuid

    assert {:ok, {"deterministic_output", other, true}} =
             RootObserver.entry_identity(%{"job_id" => Ecto.UUID.generate()}, entry, 0)

    refute identity == other

    assert {:error, :closure_incomplete} =
             RootObserver.entry_identity(
               page,
               Map.put(entry, "projection_id", "native_loader_no_vector_v1"),
               0
             )

    assert {:error, :closure_incomplete} =
             RootObserver.entry_identity(
               page,
               put_in(entry, ["value", "vector_commitments"], %{"name_embedding" => %{}}),
               0
             )
  end

  test "summary and attributes bind their full node snapshot while native attribute return can precede assignment",
       f do
    id = Ecto.UUID.generate()

    node =
      native("EntityNode", %{
        "uuid" => id,
        "group_id" => f.auth.scope_ref,
        "summary" => "Public summary",
        "attributes" => %{"owner" => "old"}
      })

    snapshot = entry(f, "deterministic_output", node, "identity_v1", id)
    summary = entry(f, "summary", "Public summary", "identity_v1", id)
    attribute = entry(f, "attribute", %{"owner" => "old"}, "identity_v1", id)

    page =
      packet(
        f,
        "graphiti.extract_nodes.v1",
        "graphiti.extract_nodes.v1",
        "inputs",
        "graphiti_extract_nodes_v1",
        [snapshot, summary, attribute]
      )

    assert :ok = RootObserver.validate_packet(f.auth, f.job, page)
    wrong = entry(f, "summary", "Different summary", "identity_v1", id)

    assert {:error, :closure_incomplete} =
             RootObserver.validate_packet(
               f.auth,
               f.job,
               rehash(Map.put(page, "entries", [snapshot, wrong, attribute]))
             )

    result = %{"owner" => "new"}
    returned = entry(f, "attribute", result, "identity_v1", id)

    detail =
      entry(
        f,
        "deterministic_output",
        %{"before" => %{}, "after" => %{}, "result" => result},
        "identity_v1"
      )

    override =
      packet(
        f,
        "graphiti.attributes.v1",
        "graphiti.attributes.v1",
        "derived",
        "graphiti_attribute_overlay_v1",
        [snapshot, returned, detail]
      )

    assert :ok = RootObserver.validate_packet(f.auth, f.job, override)
    missing_snapshot = rehash(Map.put(override, "entries", [returned, detail]))

    assert {:error, :closure_incomplete} =
             RootObserver.validate_packet(f.auth, f.job, missing_snapshot)
  end

  test "duplicate stable objects and unsupported split wire pages fail closed", f do
    id = f.job["args"]["episode_uuid"]
    first = entry(f, "episode", episode(f), "identity_v1", id)
    second = Map.put(first, "entry_id", Ecto.UUID.generate())

    page =
      packet(
        f,
        "graphiti.extract_nodes.v1",
        "graphiti.extract_nodes.v1",
        "inputs",
        "graphiti_extract_nodes_v1",
        [first, second]
      )

    assert :ok = Protocol.validate_payload("context_page", page)
    assert {:error, :closure_incomplete} = RootObserver.validate_packet(f.auth, f.job, page)
    page = model_page(f)

    for changed <- [
          Map.put(page, "final", false),
          Map.merge(page, %{
            "page_index" => 1,
            "previous_page_digest" => Contracts.sha256("previous")
          })
        ] do
      assert {:error, :closure_incomplete} = RootObserver.validate_packet(f.auth, f.job, changed)
    end
  end

  test "metadata controls and caller-owned transactions cannot create an observed ACK or any version",
       f do
    page = model_page(f)

    tables =
      ~w(dependency_manifests graph_manifest_builds graph_manifest_pages graph_derivative_versions origin_dependencies graph_observation_calls graph_observation_events model_requests)

    before = counts(tables)
    # No fake Runtime owner is installed. The explicit caller transaction must
    # also be refused before outside-lock proof I/O, independently of sandbox.
    assert {:error, reason} = RootObserver.observe(f.auth, f.job, page)
    assert reason in [:closure_incomplete, :worker_lost]

    assert {:error, :closure_incomplete} =
             Store.transaction(fn ->
               RootObserver.observe(f.auth, f.job, page)
             end)

    assert {:error, :closure_incomplete} =
             RootObserver.observe(%{f.auth | operation_type: "search"}, f.job, page)

    assert {:error, :closure_incomplete} =
             RootObserver.observe(%{f.auth | operation_type: "remove"}, f.job, page)

    assert {:error, :closure_incomplete} = RootObserver.observe(%{}, f.job, page)
    assert counts(tables) == before
  end

  test "concrete save descriptors bind exact native class method UUID and registered return kind",
       f do
    uuid = f.job["args"]["episode_uuid"]
    object = episode(f)

    descriptor = %{
      "format" => "native-save-completion-v1",
      "method" => "EpisodicNode.save",
      "return_kind" => "neo4j-eager-uuid",
      "returned_uuid" => uuid
    }

    detail = %{
      "before" => %{"object" => object},
      "after" => %{"object" => object},
      "result" => descriptor
    }

    page = save_packet(f, detail)
    assert :ok = RootObserver.validate_packet(f.auth, f.job, page)

    for changed <- [
          Map.put(descriptor, "returned_uuid", Ecto.UUID.generate()),
          Map.put(descriptor, "method", "EntityNode.save"),
          Map.put(descriptor, "return_kind", "none"),
          Map.put(descriptor, "format", "unknown-descriptor"),
          Map.put(descriptor, "driver_internals", "forbidden"),
          Map.delete(descriptor, "returned_uuid"),
          "opaque eager result string",
          nil
        ] do
      assert {:error, :closure_incomplete} =
               RootObserver.validate_packet(
                 f.auth,
                 f.job,
                 save_packet(f, Map.put(detail, "result", changed))
               )
    end
  end

  test "bulk None descriptor and structured domain return are separate bounded save cases", f do
    object = episode(f)

    descriptor = %{
      "format" => "native-save-completion-v1",
      "method" => "add_nodes_and_edges_bulk",
      "return_kind" => "none",
      "returned_uuid" => nil
    }

    after_args = %{
      "episodic_nodes" => [object],
      "entity_nodes" => [],
      "entity_edges" => [],
      "episodic_edges" => []
    }

    detail = %{"before" => after_args, "after" => after_args, "result" => descriptor}
    assert :ok = RootObserver.validate_packet(f.auth, f.job, save_packet(f, detail))

    assert {:error, :closure_incomplete} =
             RootObserver.validate_packet(
               f.auth,
               f.job,
               save_packet(
                 f,
                 Map.put(
                   detail,
                   "result",
                   Map.put(descriptor, "returned_uuid", f.job["args"]["episode_uuid"])
                 )
               )
             )

    assert {:error, :closure_incomplete} =
             RootObserver.validate_packet(
               f.auth,
               f.job,
               save_packet(f, Map.put(detail, "after", %{}))
             )

    structured = %{
      "before" => %{"episode" => object},
      "after" => %{"episode" => object},
      "result" => [[], object]
    }

    assert :ok = RootObserver.validate_packet(f.auth, f.job, save_packet(f, structured))

    for result <- [%{"arbitrary" => "native return"}, [], [object], [[], "opaque result"]] do
      assert {:error, :closure_incomplete} =
               RootObserver.validate_packet(
                 f.auth,
                 f.job,
                 save_packet(f, Map.put(structured, "result", result))
               )
    end
  end

  defp model_page(f),
    do:
      packet(f, "extract_nodes.extract_text", "llm.context.v1", "inputs", "graphiti_builder_v1", [
        entry(
          f,
          "deterministic_output",
          %{"episode_content" => f.job["args"]["body"]},
          "graphiti_context_v1"
        )
      ])

  defp save_packet(f, detail),
    do:
      packet(f, "graphiti.save.v1", "graphiti.save.v1", "derived", "graphiti_save_v1", [
        entry(f, "deterministic_output", detail, "identity_v1")
      ])

  defp packet(f, prompt, seam, phase, transform, entries) do
    {:ok, descriptor} = SchemaPolicy.entry(f.pin, prompt)

    %{
      "job_id" => f.auth.operation_id,
      "partition_id" => f.auth.partition_id,
      "lease_id" => f.auth.lease_id,
      "cancel_epoch" => f.auth.cancel_epoch,
      "semantic_generation" => f.auth.semantic_generation,
      "authorization_generation" => f.auth.authorization_generation,
      "operation_manifest_ref" => f.auth.manifest_id,
      "operation_manifest_digest" => f.auth.manifest_digest,
      "context_id" => Ecto.UUID.generate(),
      "logical_call_id" => f.call,
      "stage_id" => f.pin["id"],
      "config_digest" => f.pin["config_digest"],
      "schema_digest" => descriptor["schema_digest"],
      "prompt_name" => prompt,
      "phase" => phase,
      "seam_id" => seam,
      "transform_id" => transform,
      "entries" => entries,
      "page_index" => 0,
      "previous_page_digest" => nil,
      "final" => true,
      "base_context_ref" => nil,
      "base_context_digest" => nil,
      "parent_contexts" => [],
      "raw_body_sha256" => nil,
      "rendered_projection_digest" => Contracts.digest(entries)
    }
  end

  defp entry(f, kind, value, projection, object \\ nil),
    do: %{
      "entry_id" => Ecto.UUID.generate(),
      "kind" => kind,
      "object_id" => object || f.call,
      "version_ref" => nil,
      "predecessor_version_ref" => nil,
      "value" => value,
      "value_hash" => Contracts.digest(value),
      "projection_id" => projection,
      "projection_hash" => Contracts.digest(value),
      "parent_manifest_ref" => f.auth.manifest_id,
      "parent_manifest_digest" => f.auth.manifest_digest,
      "receipt_ref" => nil
    }

  defp episode(f),
    do:
      native("EpisodicNode", %{
        "uuid" => f.job["args"]["episode_uuid"],
        "name" => f.job["args"]["binding_id"],
        "group_id" => f.auth.scope_ref,
        "content" => f.job["args"]["body"],
        "source" => "text",
        "source_description" => f.job["args"]["revision_id"],
        "valid_at" => f.job["args"]["reference_time"],
        "created_at" => "2026-01-01T12:00:00Z",
        "labels" => [],
        "entity_edges" => []
      })

  defp native(type, fields),
    do: %{"object_type" => type, "fields" => fields, "vector_commitments" => %{}}

  defp rehash(page),
    do: Map.put(page, "rendered_projection_digest", Contracts.digest(page["entries"]))

  defp counts(tables),
    do:
      Map.new(tables, fn table ->
        [[count]] = Repo.query!("SELECT count(*) FROM " <> table, []).rows
        {table, count}
      end)
end
