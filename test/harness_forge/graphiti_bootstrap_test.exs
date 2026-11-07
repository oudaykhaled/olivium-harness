defmodule HarnessForge.Graphiti.BootstrapTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Contracts
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Graphiti.{Bootstrap, SchemaPolicy}
  alias HarnessForge.Models.{StageAuthority, Stages}

  @moduledoc "Pure identity/packet refusal only; no fabricated live bootstrap authority."

  test "bootstrap typed IDs preserve native kind while scalar versions remain exact" do
    for {type, wire, kind} <- [
          {"EpisodicNode", "episode", "deterministic_output"},
          {"EntityNode", "deterministic_output", "deterministic_output"},
          {"EntityEdge", "edge", "edge"},
          {"EpisodicEdge", "deterministic_output", "deterministic_output"}
        ] do
      id = Ecto.UUID.generate()

      entry = %{
        "kind" => wire,
        "object_id" => type <> ":" <> id,
        "projection_id" => "identity_v1",
        "value" => %{
          "object_type" => type,
          "fields" => %{"uuid" => id},
          "vector_commitments" => %{}
        }
      }

      assert {:ok, {^kind, object}} = Bootstrap.entry_identity(entry)
      assert object == type <> ":" <> id

      assert {:error, :closure_incomplete} =
               Bootstrap.entry_identity(Map.put(entry, "object_id", id))

      assert {:error, :closure_incomplete} =
               Bootstrap.entry_identity(Map.put(entry, "kind", "summary"))
    end

    for kind <- ~w(summary attribute) do
      object = "EntityNode:" <> Ecto.UUID.generate()

      assert {:ok, {^kind, ^object}} =
               Bootstrap.entry_identity(%{
                 "kind" => kind,
                 "object_id" => object,
                 "projection_id" => "identity_v1",
                 "value" => "public value"
               })
    end
  end

  test "projected bootstrap is restricted to actual vectorless loader views" do
    id = Ecto.UUID.generate()

    entry = %{
      "kind" => "deterministic_output",
      "object_id" => "EntityNode:" <> id,
      "projection_id" => "native_loader_no_vector_v1",
      "value" => %{
        "object_type" => "EntityNode",
        "fields" => %{"uuid" => id},
        "vector_commitments" => %{}
      }
    }

    assert {:ok, {"deterministic_output", _}} = Bootstrap.entry_identity(entry)

    assert {:error, :closure_incomplete} =
             Bootstrap.entry_identity(
               put_in(entry, ["value", "vector_commitments"], %{"name_embedding" => %{}})
             )

    assert {:error, :closure_incomplete} =
             Bootstrap.entry_identity(Map.put(entry, "projection_id", "unknown"))

    for invalid <- [nil, %{}, %{"kind" => "rendered_message", "value" => "public"}] do
      assert {:error, :closure_incomplete} = Bootstrap.entry_identity(invalid)
    end
  end

  test "hashes and IDs never confer packet or execution authority" do
    fake = %{
      "job_id" => Ecto.UUID.generate(),
      "rendered_projection_digest" => Contracts.digest([])
    }

    assert {:error, :closure_incomplete} = Bootstrap.validate_packet(nil, %{}, fake)
    assert {:error, :closure_incomplete} = Bootstrap.observe(nil, %{}, fake)
  end

  test "structural wire validation uses the closed bootstrap schema without server-P transform rules" do
    # A structural packet fixture is not a registered job or Runtime capability.
    pin = %{
      "id" => Ecto.UUID.generate(),
      "stage" => "extraction",
      "provider" => "ollama",
      "model" => "public-garden-bootstrap",
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
      deadline_at: DateTime.add(Store.now(), 60, :second),
      caller: [],
      operation_type: "ingest",
      operation_id: Ecto.UUID.generate(),
      partition_id: Ecto.UUID.generate(),
      lease_id: Ecto.UUID.generate(),
      manifest_id: Ecto.UUID.generate(),
      manifest_digest: Contracts.sha256("public S"),
      semantic_generation: 1,
      authorization_generation: 1,
      cancel_epoch: 0,
      scope_ref: "public_bootstrap_garden",
      stage_pins: [pin]
    }

    body = "Public seedlings."

    args = %{
      "binding_id" => Ecto.UUID.generate(),
      "episode_uuid" => Ecto.UUID.generate(),
      "revision_id" => Ecto.UUID.generate(),
      "body_hash" => Contracts.sha256(body),
      "window_start" => 0,
      "window_end" => byte_size(body),
      "body" => body,
      "reference_time" => "2026-01-01T00:00:00Z",
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
      "worker_session_id" => "public-metadata-session",
      "deadline_ms" => 1000,
      "args" => args
    }

    value = %{
      "object_type" => "EpisodicNode",
      "fields" => %{"uuid" => args["episode_uuid"], "group_id" => auth.scope_ref},
      "vector_commitments" => %{}
    }

    entry = %{
      "entry_id" => Ecto.UUID.generate(),
      "kind" => "episode",
      "object_id" => "EpisodicNode:" <> args["episode_uuid"],
      "version_ref" => nil,
      "predecessor_version_ref" => nil,
      "value_hash" => Contracts.digest(value),
      "value" => value,
      "projection_id" => "identity_v1",
      "projection_hash" => Contracts.digest(value),
      "parent_manifest_ref" => auth.manifest_id,
      "parent_manifest_digest" => auth.manifest_digest,
      "receipt_ref" => nil
    }

    page = %{
      "job_id" => auth.operation_id,
      "partition_id" => auth.partition_id,
      "lease_id" => auth.lease_id,
      "cancel_epoch" => 0,
      "semantic_generation" => 1,
      "authorization_generation" => 1,
      "operation_manifest_ref" => auth.manifest_id,
      "operation_manifest_digest" => auth.manifest_digest,
      "context_id" => Ecto.UUID.generate(),
      "logical_call_id" => Ecto.UUID.generate(),
      "phase" => "inputs",
      "seam_id" => "graphiti.bootstrap.v1",
      "stage_id" => pin["id"],
      "prompt_name" => "graphiti.bootstrap.v1",
      "config_digest" => pin["config_digest"],
      "schema_digest" => SchemaPolicy.bootstrap_schema_digest(),
      "page_index" => 0,
      "previous_page_digest" => nil,
      "final" => true,
      "entries" => [entry],
      "base_context_ref" => nil,
      "base_context_digest" => nil,
      "parent_contexts" => [],
      "raw_body_sha256" => nil,
      "rendered_projection_digest" => Contracts.digest([entry]),
      "transform_id" => "root_inventory_bootstrap_v1"
    }

    assert :ok = Bootstrap.validate_packet(auth, job, page)

    for changed <- [
          Map.put(page, "schema_digest", SchemaPolicy.digest()),
          Map.put(page, "transform_id", "identity_v1"),
          Map.put(page, "prompt_name", "unknown"),
          Map.put(page, "final", false)
        ] do
      assert {:error, :closure_incomplete} = Bootstrap.validate_packet(auth, job, changed)
    end
  end
end
