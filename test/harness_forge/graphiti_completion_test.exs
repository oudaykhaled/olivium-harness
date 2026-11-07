defmodule HarnessForge.Graphiti.CompletionTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Graphiti.{Completion, CompletionCommitment, Protocol, SchemaPolicy}
  alias HarnessForge.Models.{StageAuthority, Stages}

  @moduledoc """
  Pure request/reference/value checks and synthetic-authority refusal only.
  These fixtures establish no live Runtime capability, independent measurement,
  model settlement or successful publication. Root qualifies that path separately.
  """

  setup do
    pin = %{
      "id" => Ecto.UUID.generate(),
      "stage" => "extraction",
      "provider" => "ollama",
      "model" => "public-garden-completion-fixture",
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
      scope_ref: "public_completion_garden",
      manifest_id: Ecto.UUID.generate(),
      manifest_digest: Contracts.sha256("public source certificate"),
      stage_pins: [pin],
      semantic_generation: 1,
      authorization_generation: 1,
      cancel_epoch: 0,
      deadline_at: DateTime.add(Store.now(), 60, :second),
      caller: [],
      operation_type: "ingest",
      partition_id: Ecto.UUID.generate(),
      worker_session_id: "metadata-only-completion-session",
      lease_id: Ecto.UUID.generate(),
      corpus_id: Ecto.UUID.generate(),
      partition_lock_version: 1,
      source_lock_digest: Contracts.sha256("public source set"),
      backend_pin_digest: Contracts.sha256("public runtime bundle")
    }

    body = "Public garden: café seedlings."

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

    receipts = [Ecto.UUID.generate(), Ecto.UUID.generate()]

    result = %{
      "job_id" => auth.operation_id,
      "state" => "completed",
      "generation" => 1,
      "closure_digest" => auth.manifest_digest,
      "receipt_count" => length(receipts),
      "receipt_digest" => Contracts.digest(receipts),
      "result" => Map.take(args, ~w(binding_id episode_uuid))
    }

    {:ok, digest} = CompletionCommitment.digest(result)

    ref = %{
      "id" => Ecto.UUID.generate(),
      "inventory_revision" => 0,
      "writer_id" => Contracts.sha256("public writer"),
      "worker_image_id" => "sha256:" <> Contracts.sha256("public image"),
      "receipt_ids" => receipts,
      "job_digest" => Contracts.digest(job),
      "completion_digest" => digest,
      "base_inventory" => %{
        "inventory_revision" => 0,
        "inventory_manifest_id" => nil,
        "inventory_manifest_digest" => nil
      }
    }

    assert :ok = Protocol.validate_payload("job", job)
    %{auth: auth, job: job, result: result, ref: ref}
  end

  test "first-intent request binds the complete root control and exact terminal result", f do
    assert :ok = Completion.validate_request(f.auth, f.job, f.result)

    for {key, value} <- [
          {"job_id", Ecto.UUID.generate()},
          {"scope_ref", "other_garden"},
          {"partition_id", Ecto.UUID.generate()},
          {"worker_session_id", "session:other"},
          {"lease_id", Ecto.UUID.generate()},
          {"cancel_epoch", 1},
          {"semantic_generation", 2},
          {"authorization_generation", 2},
          {"closure_ref", Ecto.UUID.generate()},
          {"closure_digest", Contracts.sha256("other source")},
          {"stage_set_digest", Contracts.sha256("other stage")}
        ] do
      assert {:error, :closure_incomplete} =
               Completion.validate_request(f.auth, Map.put(f.job, key, value), f.result)
    end

    for {key, value} <- [
          {"job_id", Ecto.UUID.generate()},
          {"state", "failed"},
          {"generation", 2},
          {"closure_digest", Contracts.sha256("other source")},
          {"receipt_count", 0},
          {"receipt_count", 257}
        ] do
      assert {:error, :closure_incomplete} =
               Completion.validate_request(f.auth, f.job, Map.put(f.result, key, value))
    end

    assert {:error, :closure_incomplete} =
             Completion.validate_request(
               f.auth,
               f.job,
               put_in(f.result, ["result", "episode_uuid"], Ecto.UUID.generate())
             )

    assert {:error, :closure_incomplete} =
             Completion.validate_request(
               f.auth,
               f.job,
               put_in(f.result, ["result", "binding_id"], Ecto.UUID.generate())
             )
  end

  test "bounded prior selection is structural while non-ingest operations stay denied", f do
    assert :ok =
             Completion.validate_request(
               f.auth,
               put_in(f.job, ["args", "prior_episode_ids"], [Ecto.UUID.generate()]),
               f.result
             )

    for type <- ~w(search remove synthesis) do
      assert {:error, :closure_incomplete} =
               Completion.validate_request(%{f.auth | operation_type: type}, f.job, f.result)

      assert {:error, :closure_incomplete} =
               Completion.publish(%{f.auth | operation_type: type}, f.job, f.result)
    end

    for invalid <- [nil, [], %{}, %{"op" => "ingest"}] do
      assert {:error, :closure_incomplete} =
               Completion.validate_request(f.auth, invalid, f.result)
    end
  end

  test "base inventory binds revision and exact manifest pair without conferring authority", f do
    base = %{
      "inventory_revision" => 1,
      "inventory_manifest_id" => Ecto.UUID.generate(),
      "inventory_manifest_digest" => Contracts.sha256("public prior certificate")
    }

    ref = f.ref |> Map.put("base_inventory", base) |> Map.put("inventory_revision", 1)
    assert :ok = Completion.validate_reference(ref, f.job, f.result)

    for invalid <- [
          Map.put(base, "inventory_revision", -1),
          Map.put(base, "inventory_manifest_id", nil),
          Map.put(base, "inventory_manifest_digest", nil),
          Map.put(base, "inventory_revision", 0),
          Map.put(base, "extra", true)
        ] do
      refute Completion.valid_base?(invalid)
    end

    assert {:error, :closure_incomplete} =
             Completion.validate_reference(Map.put(ref, "inventory_revision", 2), f.job, f.result)

    assert {:error, :closure_incomplete} =
             Completion.validate_reference(Map.delete(ref, "base_inventory"), f.job, f.result)
  end

  test "reference shape binds exact job and completion commitments but is not authority", f do
    assert :ok = Completion.validate_reference(f.ref, f.job, f.result)

    for {key, value} <- [
          {"id", "not-a-uuid"},
          {"inventory_revision", 1},
          {"writer_id", "mutable-name"},
          {"worker_image_id", "worker:latest"},
          {"worker_image_id", Contracts.sha256("unprefixed image")},
          {"job_digest", Contracts.sha256("other job")},
          {"completion_digest", Contracts.sha256("other result")}
        ] do
      assert {:error, :closure_incomplete} =
               Completion.validate_reference(Map.put(f.ref, key, value), f.job, f.result)
    end

    assert {:error, :closure_incomplete} =
             Completion.validate_reference(Map.put(f.ref, "extra", true), f.job, f.result)

    assert {:error, :closure_incomplete} =
             Completion.validate_reference(Map.delete(f.ref, "writer_id"), f.job, f.result)

    assert {:error, :closure_incomplete} = Completion.validate_reference(nil, f.job, f.result)

    assert {:error, :closure_incomplete} =
             Completion.validate_reference(
               f.ref,
               put_in(f.job, ["args", "body"], "changed public garden"),
               f.result
             )
  end

  test "receipt order, uniqueness and exact count cannot be reconstructed or truncated", f do
    assert {:error, :closure_incomplete} =
             Completion.validate_reference(
               Map.put(f.ref, "receipt_ids", Enum.reverse(f.ref["receipt_ids"])),
               f.job,
               f.result
             )

    for ids <- [
          [],
          [hd(f.ref["receipt_ids"])],
          List.duplicate(hd(f.ref["receipt_ids"]), 2),
          ["invalid", Ecto.UUID.generate()]
        ] do
      assert {:error, :closure_incomplete} =
               Completion.validate_reference(Map.put(f.ref, "receipt_ids", ids), f.job, f.result)
    end

    many = Enum.map(1..257, fn _ -> Ecto.UUID.generate() end)
    result = %{f.result | "receipt_count" => 257, "receipt_digest" => Contracts.digest(many)}
    {:ok, digest} = CompletionCommitment.digest(result)
    ref = %{f.ref | "receipt_ids" => many, "completion_digest" => digest}
    assert {:error, :closure_incomplete} = Completion.validate_reference(ref, f.job, result)
  end

  test "all four native classes retain typed stable identities without aliases" do
    id = Ecto.UUID.generate()

    for {type, kind} <- [
          {"EpisodicNode", "deterministic_output"},
          {"EntityNode", "deterministic_output"},
          {"EntityEdge", "edge"},
          {"EpisodicEdge", "deterministic_output"}
        ] do
      record = object(type, id)
      assert {:ok, {^kind, identity}} = Completion.native_identity(record)
      assert identity == type <> ":" <> id
    end

    for record <- [
          nil,
          %{},
          object("UnknownNode", id),
          object("EntityNode", "bad"),
          Map.put(object("EntityNode", id), "extra", true),
          Map.put(object("EntityNode", id), "vector_commitments", [])
        ] do
      assert {:error, :closure_incomplete} = Completion.native_identity(record)
    end
  end

  test "native comparison uses canonical full values and vector commitments" do
    record = object("EntityNode", Ecto.UUID.generate())
    version = version(record)
    assert :ok = Completion.compare_native(version, record, "public_completion_garden")

    for path <- [
          ["fields", "summary"],
          ["fields", "name"],
          ["fields", "group_id"],
          ["vector_commitments", "name_embedding", "sha256"]
        ] do
      changed = put_in(record, path, "changed")

      assert {:error, :closure_incomplete} =
               Completion.compare_native(version, changed, "public_completion_garden")
    end

    changed = put_in(record, ["fields", "attributes"], %{"public" => "changed"})

    assert {:error, :closure_incomplete} =
             Completion.compare_native(version, changed, "public_completion_garden")

    assert {:error, :closure_incomplete} =
             Completion.compare_native(version, record, "other_garden")
  end

  test "latest denied, metadata-only or altered versions never match an older value" do
    record = object("EntityNode", Ecto.UUID.generate())
    version = version(record)

    for changed <- [
          Map.put(version, "state", "denied"),
          Map.put(version, "value_json", nil),
          Map.put(version, "value_hash", Contracts.sha256("other value")),
          Map.put(version, "object_kind", "summary"),
          Map.put(version, "object_id", "EntityNode:" <> Ecto.UUID.generate()),
          Map.put(version, "value_json", " " <> version["value_json"]),
          Map.put(version, "value_json", "{\"duplicate\":1,\"duplicate\":2}")
        ] do
      assert {:error, :closure_incomplete} =
               Completion.compare_native(changed, record, "public_completion_garden")
    end

    assert :ok =
             Completion.compare_native(
               Map.put(version, "state", "published"),
               record,
               "public_completion_garden"
             )
  end

  test "synthetic structurally valid controls cannot publish or write provenance", f do
    before = counts()
    assert {:error, _} = Completion.publish(f.auth, f.job, f.result)
    assert {:error, :closure_incomplete} = Completion.publish(nil, f.job, f.result)
    assert counts() == before
  end

  test "bounded dependency deduplication preserves order and rejects conflicting payloads" do
    fields =
      ~w(dependency_key kind source_id revision_id content_hash role episode_binding_id derivative_version_id projection_id projection_hash parent_manifest_id)

    first =
      Map.new(fields, &{&1, nil})
      |> Map.merge(%{
        "dependency_key" => "manifest:" <> Ecto.UUID.generate(),
        "kind" => "manifest",
        "content_hash" => Contracts.sha256("public parent"),
        "role" => "transitive"
      })

    second = Map.put(first, "dependency_key", "manifest:" <> Ecto.UUID.generate())

    assert {:ok, [^first, ^second]} =
             Completion.unique_dependencies([first, first, second, first])

    for changed <- [
          Map.put(first, "content_hash", Contracts.sha256("changed parent")),
          Map.put(first, "role", "uncited"),
          Map.put(first, "projection_id", "identity_v1")
        ] do
      assert {:error, :closure_incomplete} =
               Completion.unique_dependencies([first, second, changed])
    end

    assert {:ok, []} = Completion.unique_dependencies([])

    assert {:error, :closure_incomplete} =
             Completion.unique_dependencies(List.duplicate(first, 101))

    assert {:error, :closure_incomplete} =
             Completion.unique_dependencies([Map.delete(first, "role")])

    assert {:error, :closure_incomplete} = Completion.unique_dependencies(nil)
  end

  defp object(type, id) do
    %{
      "object_type" => type,
      "fields" => %{
        "uuid" => id,
        "group_id" => "public_completion_garden",
        "name" => "Café seedlings",
        "summary" => "Public garden fixture",
        "attributes" => %{},
        "created_at" => "2026-01-01T12:00:00+00:00"
      },
      "vector_commitments" => %{
        "name_embedding" => %{"dimensions" => 2, "sha256" => Contracts.sha256("synthetic vector")}
      }
    }
  end

  defp version(record) do
    {:ok, {kind, identity}} = Completion.native_identity(record)

    %{
      "id" => Ecto.UUID.generate(),
      "object_kind" => kind,
      "object_id" => identity,
      "version" => 1,
      "value_json" => Contracts.canonical_json(record),
      "value_hash" => Contracts.digest(record),
      "state" => "staging"
    }
  end

  defp counts do
    for table <-
          ~w(graph_partition_controls graph_episode_bindings graph_derivative_versions dependency_manifests origin_dependencies graph_manifest_builds graph_manifest_pages stage_operations),
        into: %{} do
      %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM " <> table)
      {table, count}
    end
  end
end
