defmodule HarnessForge.Graphiti.SearchIntentTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Repo}
  alias HarnessForge.Evidence.Store
  alias HarnessForge.Graphiti.{SchemaPolicy, SearchIntent}
  alias HarnessForge.Models.{StageAuthority, Stages}

  @moduledoc "Metadata shape and negative authority tests, not live preparation or provider qualification."

  setup do
    pins =
      for stage <- ~w(extraction summary node_dedupe edge_dedupe embedder) do
        endpoint = if stage == "embedder", do: "/v1/embeddings", else: "/v1/chat/completions"

        pin = %{
          "id" => Ecto.UUID.generate(),
          "stage" => stage,
          "provider" => "ollama",
          "model" => "public-search-garden-v1",
          "endpoint" => "http://127.0.0.1:11434" <> endpoint,
          "route_id" => "graphiti_" <> stage,
          "credential_ref" => nil,
          "prompt_digest" => SchemaPolicy.prompt_policy_digest(stage),
          "schema_digest" => SchemaPolicy.digest(),
          "consent_revision" => 1,
          "input_rate" => 0,
          "output_rate" => 0,
          "max_output_tokens" => 100,
          "timeout_ms" => 1000
        }

        Map.put(pin, "config_digest", Stages.fingerprint(pin))
      end

    auth = %StageAuthority{
      workspace_id: Store.workspace(),
      deadline_at: DateTime.add(Store.now(), 60, :second),
      caller: [],
      operation_type: "search",
      operation_id: Ecto.UUID.generate(),
      partition_id: Ecto.UUID.generate(),
      lease_id: Ecto.UUID.generate(),
      worker_session_id: "metadata-only-public-search",
      corpus_id: Ecto.UUID.generate(),
      manifest_id: Ecto.UUID.generate(),
      manifest_digest: Contracts.sha256("public S"),
      semantic_generation: 1,
      authorization_generation: 1,
      cancel_epoch: 0,
      partition_lock_version: 1,
      source_lock_digest: Contracts.sha256("public sources"),
      backend_pin_digest: Contracts.sha256("public runtime"),
      scope_ref: "public_search_garden",
      stage_pins: pins
    }

    job = %{
      "op" => "search",
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
      "args" => %{
        "query" => "  Seedlings\nneed water?  ",
        "limit" => 10,
        "recipe_id" => "edge_hybrid_rrf_v1"
      }
    }

    scope = %{
      "corpus_id" => auth.corpus_id,
      "project_id" => Ecto.UUID.generate(),
      "goal_id" => Ecto.UUID.generate(),
      "goal_hash" => Contracts.sha256("public goal"),
      "semantic_generation" => 1,
      "authorization_generation" => 1,
      "profile" => %{
        "id" => Ecto.UUID.generate(),
        "content_hash" => Contracts.sha256("public profile")
      },
      "project" => %{
        "id" => Ecto.UUID.generate(),
        "content_hash" => Contracts.sha256("public project")
      }
    }

    %{auth: auth, job: job, scope: scope}
  end

  test "shape binds full control and five pins without conferring authority", f do
    assert :ok = SearchIntent.validate_shape(f.auth, f.job)

    for {key, value} <- [
          {"job_id", Ecto.UUID.generate()},
          {"scope_ref", "other"},
          {"cancel_epoch", 1},
          {"closure_digest", Contracts.sha256("other")},
          {"stage_set_digest", Contracts.sha256("other")},
          {"worker_session_id", "other"}
        ] do
      assert {:error, :closure_incomplete} =
               SearchIntent.validate_shape(f.auth, Map.put(f.job, key, value))
    end

    assert {:error, :closure_incomplete} =
             SearchIntent.validate_shape(%{f.auth | stage_pins: []}, f.job)

    for query <- [" ", String.duplicate("a", 257), String.duplicate("🌱", 257)] do
      assert {:error, :closure_incomplete} =
               SearchIntent.validate_shape(f.auth, put_in(f.job, ["args", "query"], query))
    end

    for limit <- [0, 11, 100, 1.0] do
      assert {:error, :closure_incomplete} =
               SearchIntent.validate_shape(f.auth, put_in(f.job, ["args", "limit"], limit))
    end
  end

  test "query input preserves original bytes and only native newline normalization is applied",
       f do
    assert SearchIntent.input(f.job) == Map.put(f.job["args"], "group_id", f.auth.scope_ref)
    assert SearchIntent.normalized_input(f.job) == ["  Seedlings need water?  "]

    refute SearchIntent.normalized_input(f.job) == [
             String.trim(hd(SearchIntent.normalized_input(f.job)))
           ]

    refute SearchIntent.valid_input?(Map.put(SearchIntent.input(f.job), "query_vector", []))
  end

  test "scope pins retain workspace goal profile and project identity", f do
    pins = SearchIntent.scope_pins(f.scope)
    assert pins["workspace_id"] == Store.workspace()

    for changed <- [
          Map.put(f.scope, "goal_hash", Contracts.sha256("changed")),
          put_in(f.scope, ["profile", "content_hash"], Contracts.sha256("changed")),
          put_in(f.scope, ["project", "content_hash"], Contracts.sha256("changed"))
        ] do
      refute Contracts.digest(SearchIntent.scope_pins(changed)) == Contracts.digest(pins)
    end
  end

  test "synthetic authority cannot prepare register or revive an intent and creates no rows", f do
    {:ok, before} = Repo.query("SELECT count(*) FROM graph_derivative_versions", [])
    assert {:error, :closure_incomplete} = SearchIntent.prepare(f.auth, f.job, f.scope)
    assert {:error, :closure_incomplete} = SearchIntent.validate_prepared(f.auth, f.job)
    assert {:error, :closure_incomplete} = SearchIntent.validate_current(f.auth, f.job)
    {:ok, after_count} = Repo.query("SELECT count(*) FROM graph_derivative_versions", [])
    assert before.rows == after_count.rows
  end
end
