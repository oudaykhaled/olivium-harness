defmodule HarnessForge.Graphiti.SchemaPolicyTest do
  use ExUnit.Case, async: true
  alias HarnessForge.{Contracts, Graphiti.SchemaPolicy, Models.Stages}

  defp pin(stage \\ "extraction") do
    jev = stage in ~w(node_dedupe edge_dedupe)

    endpoint =
      cond do
        jev -> "https://api.typesafe.ai/v1/systemone"
        stage == "embedder" -> "http://127.0.0.1:11434/v1/embeddings"
        true -> "http://127.0.0.1:11434/v1/chat/completions"
      end

    value = %{
      "id" => Ecto.UUID.generate(),
      "stage" => stage,
      "provider" => if(jev, do: "jev", else: "ollama"),
      "model" => "synthetic-pinned-model",
      "endpoint" => endpoint,
      "route_id" => "graphiti_" <> stage,
      "credential_ref" => nil,
      "prompt_digest" => SchemaPolicy.prompt_policy_digest(stage),
      "schema_digest" => SchemaPolicy.digest(),
      "consent_revision" => 1,
      "input_rate" => if(jev, do: 1, else: 0),
      "output_rate" => if(jev, do: 1, else: 0),
      "max_output_tokens" => 1024,
      "timeout_ms" => 60000
    }

    Map.put(value, "config_digest", Stages.fingerprint(value))
  end

  defp repin(pin, key, value) do
    pin = Map.put(pin, key, value)
    Map.put(pin, "config_digest", Stages.fingerprint(pin))
  end

  test "root bootstrap context forms cannot authorize a provider body or an attempt bind" do
    p = pin()

    common = %{
      "stage_id" => p["id"],
      "config_digest" => p["config_digest"],
      "prompt_name" => "graphiti.bootstrap.v1",
      "seam_id" => "graphiti.bootstrap.v1",
      "schema_digest" => SchemaPolicy.bootstrap_schema_digest(),
      "base_context_ref" => nil,
      "base_context_digest" => nil,
      "receipt_ref" => nil,
      "receipt_digest" => nil,
      "raw_body_sha256" => nil,
      "rendered_projection_digest" => nil
    }

    inputs = Map.merge(common, %{"graph_kind" => "inputs", "transform_id" => nil})

    derived =
      Map.merge(common, %{
        "graph_kind" => "derived",
        "transform_id" => "root_inventory_bootstrap_v1",
        "base_context_ref" => Ecto.UUID.generate(),
        "base_context_digest" => String.duplicate("1", 64)
      })

    wire =
      Map.merge(common, %{
        "phase" => "inputs",
        "transform_id" => "root_inventory_bootstrap_v1",
        "page_index" => 0,
        "previous_page_digest" => nil,
        "final" => true,
        "parent_contexts" => [],
        "rendered_projection_digest" => Contracts.digest([])
      })

    for form <- [inputs, derived, wire], do: assert(:ok == SchemaPolicy.validate_context(p, form))

    for {key, value} <- [
          {"schema_digest", SchemaPolicy.digest()},
          {"seam_id", "graphiti.save.v1"},
          {"transform_id", "unknown"},
          {"graph_kind", "attempt_bind"},
          {"raw_body_sha256", String.duplicate("2", 64)},
          {"receipt_ref", Ecto.UUID.generate()},
          {"parent_contexts", [%{"manifest_ref" => Ecto.UUID.generate()}]},
          {"rendered_projection_digest", nil}
        ] do
      assert {:error, _} = SchemaPolicy.validate_context(p, Map.put(wire, key, value))
    end

    assert {:error, _} =
             SchemaPolicy.validate_context(
               p,
               Map.put(inputs, "transform_id", "root_inventory_bootstrap_v1")
             )

    assert {:error, _} = SchemaPolicy.validate_context(pin("summary"), wire)
    assert {:error, _} = SchemaPolicy.entry(p, "graphiti.bootstrap.v1")
    assert {:error, _} = SchemaPolicy.validate_body(p, "graphiti.bootstrap.v1", "{}", [])
    assert SchemaPolicy.bootstrap_schema()["items"]["additionalProperties"] == false
    assert SchemaPolicy.bootstrap_prompt_policy()["provider_attempt"] == false
  end

  test "the exported native catalogue has a closed route set and separate per-call hashes" do
    assert {:ok, catalogue} = SchemaPolicy.catalogue()
    assert length(catalogue["entries"]) == 19
    assert catalogue["versions"]["graphiti-core"] == "0.31.2"
    assert catalogue["versions"]["openai"] == "3.42.1"
    assert catalogue["route_policy"]["catalogue_membership_releases_routes"] == false

    for entry <- catalogue["entries"] do
      assert entry["schema_digest"] == Contracts.digest(entry["schema"])
      refute entry["schema_digest"] == SchemaPolicy.digest()
      assert :ok = SchemaPolicy.validate_pin(pin(entry["stage"]))
    end

    assert {:ok, none} = SchemaPolicy.entry(pin("summary"), "extract_nodes.extract_summary")
    assert none["schema_kind"] == "static_none" and none["schema"] == %{}
    assert none["physical_profile"]["response_format"] == %{"type" => "json_object"}
    assert {:error, _} = SchemaPolicy.entry(pin(), "extract_nodes.extract_attributes")
    assert {:error, _} = SchemaPolicy.entry(pin(), "extract_nodes.extract_message")

    assert {:error, _} =
             SchemaPolicy.entry(
               pin("summary"),
               "extract_nodes.extract_entity_summaries_from_episodes"
             )
  end

  test "stage config cannot substitute an actual schema for the catalogue or cross routes" do
    p = pin()
    assert :ok = SchemaPolicy.validate_pin(p)
    {:ok, entry} = SchemaPolicy.entry(p, "extract_nodes.extract_text")

    assert {:error, _} =
             SchemaPolicy.validate_pin(repin(p, "schema_digest", entry["schema_digest"]))

    assert {:error, _} =
             SchemaPolicy.validate_pin(repin(p, "prompt_digest", String.duplicate("0", 64)))

    assert {:error, _} = SchemaPolicy.validate_pin(repin(p, "route_id", "unreviewed_route"))
    assert {:error, _} = SchemaPolicy.validate_pin(repin(p, "provider", "anthropic"))

    context = %{
      "stage_id" => p["id"],
      "config_digest" => p["config_digest"],
      "graph_kind" => "inputs",
      "prompt_name" => "extract_nodes.extract_text",
      "seam_id" => "llm.context.v1",
      "schema_digest" => entry["schema_digest"],
      "transform_id" => nil
    }

    assert :ok = SchemaPolicy.validate_context(p, context)

    for {key, value} <- [
          {"schema_digest", SchemaPolicy.digest()},
          {"seam_id", "graphiti.save.v1"},
          {"prompt_name", "dedupe_nodes.nodes"},
          {"stage_id", Ecto.UUID.generate()},
          {"transform_id", "unknown_transform"}
        ] do
      assert {:error, _} = SchemaPolicy.validate_context(p, Map.put(context, key, value))
    end
  end

  test "actual OpenAI envelope keeps native format and measured messages with no downgrade or extras" do
    p = pin()
    {:ok, entry} = SchemaPolicy.entry(p, "extract_nodes.extract_text")
    messages = [%{"role" => "user", "content" => "Public synthetic company decision"}]

    body = %{
      "model" => p["model"],
      "messages" => messages,
      "max_tokens" => 512,
      "temperature" => 1,
      "response_format" => entry["physical_profile"]["response_format"]
    }

    raw = Jason.encode!(body)
    assert :ok = SchemaPolicy.validate_body(p, entry["prompt_name"], raw, messages)
    refute Map.has_key?(body["response_format"]["json_schema"], "strict")

    for changed <- [
          Map.put(body, "stream", false),
          Map.put(body, "max_tokens", 1025),
          Map.put(body, "model", "different-model"),
          Map.put(body, "temperature", 0),
          Map.put(body, "response_format", %{"type" => "json_object"}),
          put_in(body, ["response_format", "json_schema", "strict"], true)
        ] do
      assert {:error, _} =
               SchemaPolicy.validate_body(
                 p,
                 entry["prompt_name"],
                 Jason.encode!(changed),
                 messages
               )
    end

    assert {:error, _} =
             SchemaPolicy.validate_body(
               p,
               entry["prompt_name"],
               raw,
               Enum.reverse([%{"role" => "system", "content" => "Extra"} | messages])
             )

    duplicated = "{\"model\":\"substitution\"," <> String.trim_leading(raw, "{")
    assert {:error, _} = SchemaPolicy.validate_body(p, entry["prompt_name"], duplicated, messages)
  end

  test "Jev and embeddings accept their native physical envelopes without invented schema or token fields" do
    # Exact bytes captured from the pinned client's offline public SDK fixture.
    # No request is dispatched by this validator test.
    raw = File.read!(Path.expand("../fixtures/graphiti/native_jev_request.json", __DIR__))
    body = Jason.decode!(raw)
    p = repin(pin("node_dedupe"), "model", body["model"])

    projection = [Map.take(body, ~w(state questions))]

    assert :ok =
             SchemaPolicy.validate_body(p, "dedupe_nodes.nodes", raw, projection)

    for questions <- [[], ["synthetic question"], %{}] do
      changed = Map.put(body, "questions", questions)

      assert {:error, _} =
               SchemaPolicy.validate_body(p, "dedupe_nodes.nodes", Jason.encode!(changed), [
                 Map.take(changed, ~w(state questions))
               ])
    end

    for key <- ~w(response_format max_tokens temperature stream) do
      assert {:error, _} =
               SchemaPolicy.validate_body(
                 p,
                 "dedupe_nodes.nodes",
                 Jason.encode!(Map.put(body, key, nil)),
                 projection
               )
    end

    assert {:error, _} =
             SchemaPolicy.validate_body(p, "dedupe_nodes.nodes", Jason.encode!(body), [
               %{"state" => "other", "questions" => body["questions"]}
             ])

    p = pin("embedder")
    input = ["public synthetic text"]
    body = %{"model" => p["model"], "input" => input, "encoding_format" => "base64"}
    assert :ok = SchemaPolicy.validate_body(p, "embedder.create", Jason.encode!(body), [input])

    assert {:error, _} =
             SchemaPolicy.validate_body(
               p,
               "embedder.create",
               Jason.encode!(Map.put(body, "dimensions", 1024)),
               [input]
             )

    assert {:error, _} =
             SchemaPolicy.validate_body(
               p,
               "embedder.create",
               Jason.encode!(Map.put(body, "encoding_format", "float")),
               [input]
             )

    assert {:error, _} =
             SchemaPolicy.validate_body(p, "embedder.create", Jason.encode!(body), [
               ["changed input"]
             ])
  end
end
