defmodule HarnessForge.ChatModelsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Evidence, Models}
  alias HarnessForge.Models.{Configuration, Profile, Proposal}

  @providers ~w(ollama openai openai_responses anthropic)
  @credential "HARNESSFORGE_CHAT_MODEL_FIXTURE_KEY"

  setup do
    previous = Application.get_env(:harness_forge, :model_test_plug)
    old_credential = System.get_env(@credential)
    directory = Path.join(File.cwd!(), ".chat-model-test-" <> Ecto.UUID.generate())
    File.mkdir_p!(directory)
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})
    System.put_env(@credential, "synthetic-chat-fixture-only")

    {:ok, connection} =
      Evidence.connect(%{
        "provider" => "local",
        "name" => "Chat fixture",
        "directory" => directory
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "chat-fixture.md",
        "title" => "Synthetic connector evidence",
        "body" => "Synthetic connector evidence requires explicit review."
      })

    on_exit(fn ->
      File.rm_rf!(directory)

      if previous,
        do: Application.put_env(:harness_forge, :model_test_plug, previous),
        else: Application.delete_env(:harness_forge, :model_test_plug)

      if old_credential,
        do: System.put_env(@credential, old_credential),
        else: System.delete_env(@credential)
    end)

    Req.Test.verify_on_exit!()
    %{source: source}
  end

  test "canonical profiles are server-owned and preserve the proposal contract" do
    assert Profile.system(%{}) == Proposal.system()
    assert Profile.system(%{"purpose" => "proposal"}) == Proposal.system()
    assert Profile.schema(%{}) == Proposal.schema()
    assert Profile.name(%{}) == "proposed_claims"

    assert Profile.schema(%{"purpose" => "chat"}) == %{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["answer", "citation_ids"],
             "properties" => %{
               "answer" => %{"type" => "string", "minLength" => 1, "maxLength" => 8000},
               "citation_ids" => %{
                 "type" => "array",
                 "uniqueItems" => true,
                 "minItems" => 1,
                 "maxItems" => 12,
                 "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 20}
               }
             }
           }

    assert Profile.name(%{"purpose" => "chat"}) == "harnessforge_chat"
    system = Profile.system(%{"purpose" => "chat"})
    assert system =~ "untrusted data" and system =~ "read-only chat" and system =~ "abstain"
    assert system =~ "credentials" and system =~ "E#" and system =~ "execute code"
  end

  for provider <- @providers do
    test "#{provider} sends the bounded chat profile over its real adapter wire", %{
      source: source
    } do
      provider = unquote(provider)
      configure(provider, source)
      run = provider <> "-chat-wire"
      {:ok, _} = Models.start_run(run)
      req = request(run, source)
      expect_available(provider)

      Req.Test.expect(__MODULE__, fn conn ->
        body = body(conn)
        assert_profile(provider, body, req)
        assert_no_tools(provider, body)
        Req.Test.json(conn, response(provider, output()))
      end)

      assert {:ok, %{"text" => text, "usage_status" => "reported"}} = Models.infer(req)
      assert text == output()
      assert {:error, :request_already_dispatched} = Models.infer(req)
      assert {:ok, [%{"state" => "completed"}]} = Models.list_requests(run)
      assert {:ok, []} = Evidence.list_claims()
    end

    test "#{provider} keeps omitted and explicit proposal profiles wire-compatible", %{
      source: source
    } do
      provider = unquote(provider)
      configure(provider, source)

      for {purpose, index} <- [{:omitted, 0}, {"proposal", 1}] do
        run = provider <> "-proposal-wire-#{index}"
        {:ok, _} = Models.start_run(run)
        req = request(run, source) |> Map.delete("purpose")
        req = if purpose == :omitted, do: req, else: Map.put(req, "purpose", purpose)
        expect_available(provider)

        Req.Test.expect(__MODULE__, fn conn ->
          body = body(conn)
          assert_profile(provider, body, req)
          assert_no_tools(provider, body)
          Req.Test.json(conn, response(provider, ~s({"claims":[]})))
        end)

        assert {:ok, _} = Models.infer(req)
      end
    end
  end

  test "invalid purposes, profile overrides and missing chat categories cannot dispatch", %{
    source: source
  } do
    Req.Test.stub(__MODULE__, fn _ -> flunk("invalid requests cannot reach transport") end)

    for provider <- @providers do
      configure(provider, source)
      run = provider <> "-invalid-profile"
      {:ok, _} = Models.start_run(run)
      req = request(run, source)

      invalid =
        Enum.map([nil, "Chat", "runtime", :chat, %{}], &Map.put(req, "purpose", &1)) ++
          Enum.map(~w(system schema name response_format), &Map.put(req, &1, %{})) ++
          Enum.map([[], ["source_body"], ["chat_context"]], &Map.put(req, "data_categories", &1))

      for value <- invalid do
        assert {:error, :invalid_model_request} = Models.infer(value)
      end

      assert {:ok, []} = Models.list_requests(run)
    end
  end

  test "proposal-only cloud consent cannot authorize chat context or auto-expand consent", %{
    source: source
  } do
    Req.Test.stub(__MODULE__, fn _ -> flunk("unconsented chat cannot reach transport") end)

    for provider <- @providers -- ["ollama"] do
      config = config(provider, source)
      proposal_only = put_in(config, ["cloud_consent", "data_categories"], ["source_body"])
      {:ok, _} = Models.configure(proposal_only)
      run = provider <> "-chat-consent"
      {:ok, _} = Models.start_run(run)
      assert {:error, :cloud_consent_required} = Models.infer(request(run, source))
      assert Configuration.get()["cloud_consent"] == proposal_only["cloud_consent"]
      assert {:ok, []} = Models.list_requests(run)

      {:ok, _} = Models.configure(Map.put(config, "cloud_consent", nil))
      assert {:error, :cloud_consent_required} = Models.infer(request(run, source))
      assert {:ok, []} = Models.list_requests(run)
    end
  end

  test "chat timeouts retain selected-profile reservations and reject blind retry", %{
    source: source
  } do
    for provider <- @providers do
      configure(provider, source)
      run = provider <> "-chat-uncertain"
      {:ok, _} = Models.start_run(run)
      req = request(run, source)
      expect_available(provider)
      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
      assert {:error, :model_service_unavailable} = Models.infer(req, timeout: 1)
      assert {:error, :request_already_dispatched} = Models.infer(req)

      assert {:error, :request_outcome_unknown} =
               Models.infer(Map.put(req, "request_id", "new-id"))

      bound =
        byte_size(req["prompt"]) + byte_size(Profile.system(req)) +
          byte_size(Contracts.canonical_json(Profile.schema(req))) + 1024 +
          req["max_output_tokens"]

      assert {:ok, %{"reserved_tokens" => ^bound}} = Models.budget(run)

      assert {:ok, [%{"state" => "uncertain", "billing_status" => "unknown"}]} =
               Models.list_requests(run)
    end
  end

  test "explicit default cannot bypass a legacy proposal's uncertain retry fence", %{
    source: source
  } do
    configure("openai_responses", source)
    run = "proposal-default-retry-fence"
    {:ok, _} = Models.start_run(run)
    req = request(run, source) |> Map.delete("purpose")
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :model_service_unavailable} = Models.infer(req, timeout: 1)

    assert {:error, :request_outcome_unknown} =
             Models.infer(
               req
               |> Map.put("purpose", "proposal")
               |> Map.put("request_id", "new-id")
             )
  end

  test "chat shares hard request, token and cloud cost limits before dispatch", %{source: source} do
    for provider <- @providers do
      configure(provider, source)
      run = provider <> "-chat-request-budget"
      {:ok, _} = Models.start_run(run, %{"max_requests" => 1})
      req = request(run, source)
      expect_available(provider)
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, response(provider, output())))
      assert {:ok, _} = Models.infer(req)
      assert {:error, :budget_exhausted} = Models.infer(Map.put(req, "request_id", "over-budget"))

      limits =
        if provider == "ollama",
          do: [{"tokens", %{"max_tokens" => 1}}],
          else: [{"tokens", %{"max_tokens" => 1}}, {"cost", %{"max_estimated_microusd" => 1}}]

      for {name, limit} <- limits do
        run = provider <> "-chat-budget-" <> name
        {:ok, _} = Models.start_run(run, limit)
        assert {:error, :budget_exhausted} = Models.infer(request(run, source))
        assert {:ok, []} = Models.list_requests(run)
      end
    end
  end

  defp configure(provider, source),
    do: assert({:ok, _} = Models.configure(config(provider, source)))

  defp config("ollama", _source), do: %{"provider" => "ollama", "model" => "synthetic:fixture"}

  defp config(provider, source) do
    endpoint =
      if provider == "anthropic",
        do: "https://api.anthropic.com/v1",
        else: "https://api.openai.com/v1"

    %{
      "provider" => provider,
      "endpoint" => endpoint,
      "model" => "synthetic-fixture-only",
      "credential_env" => @credential,
      "input_microusd_per_million" => 1_000_000,
      "output_microusd_per_million" => 1_000_000,
      "cloud_consent" => %{
        "provider" => provider,
        "endpoint" => endpoint,
        "source_ids" => [source["id"]],
        "data_categories" => ["source_body", "chat_context"]
      }
    }
  end

  defp request(run, source),
    do: %{
      "run_id" => run,
      "request_id" => "one",
      "purpose" => "chat",
      "prompt" =>
        ~s({"question":"What requires review?","excerpts":[{"id":"E1","body":"Synthetic connector evidence requires explicit review."}]}),
      "source_ids" => [source["id"]],
      "data_categories" => ["source_body", "chat_context"],
      "max_output_tokens" => 128
    }

  defp expect_available("ollama") do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET" and conn.request_path == "/api/tags"
      Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})
    end)
  end

  defp expect_available(_), do: :ok

  defp assert_profile("ollama", body, request) do
    assert body["system"] == Profile.system(request)
    assert body["format"] == Profile.schema(request)
    assert body["prompt"] == request["prompt"]
    assert body["options"]["num_predict"] == 128
  end

  defp assert_profile("openai", body, request) do
    assert hd(body["messages"])["content"] == Profile.system(request)
    assert List.last(body["messages"])["content"] == request["prompt"]
    format = body["response_format"]["json_schema"]
    assert format["name"] == Profile.name(request) and format["strict"] == true
    assert_wire_schema(format["schema"], request, "openai")
  end

  defp assert_profile("openai_responses", body, request) do
    assert body["instructions"] == Profile.system(request)
    assert hd(body["input"])["content"] == request["prompt"]
    format = body["text"]["format"]
    assert format["name"] == Profile.name(request) and format["strict"] == true
    assert_wire_schema(format["schema"], request, "openai_responses")
  end

  defp assert_profile("anthropic", body, request) do
    assert body["system"] == Profile.system(request)
    assert hd(body["messages"])["content"] == request["prompt"]
    assert body["output_config"]["format"]["type"] == "json_schema"
    assert_wire_schema(body["output_config"]["format"]["schema"], request, "anthropic")
  end

  defp assert_wire_schema(schema, %{"purpose" => "chat"}, provider) do
    assert schema["additionalProperties"] == false
    assert schema["required"] == ["answer", "citation_ids"]
    assert schema["properties"]["answer"]["type"] == "string"
    assert schema["properties"]["citation_ids"]["minItems"] == 1
    refute Jason.encode!(schema) =~ "uniqueItems"

    if provider == "anthropic" do
      for key <- ~w(minLength maxLength maxItems), do: refute(Jason.encode!(schema) =~ key)
    else
      assert schema["properties"]["answer"]["maxLength"] == 8000
      assert schema["properties"]["citation_ids"]["maxItems"] == 12
      assert schema["properties"]["citation_ids"]["items"]["maxLength"] == 20
    end
  end

  defp assert_wire_schema(schema, _request, "anthropic") do
    assert schema["required"] == ["claims"]
    assert schema["additionalProperties"] == false
    refute Jason.encode!(schema) =~ "maxLength"
    refute Jason.encode!(schema) =~ "maxItems"
  end

  defp assert_wire_schema(schema, _request, _provider), do: assert(schema == Proposal.schema())

  defp assert_no_tools(provider, body) do
    assert body["stream"] == false
    if provider in ["openai", "openai_responses"], do: assert(body["store"] == false)

    if provider == "openai_responses" do
      assert body["tools"] == [] and body["tool_choice"] == "none"
    else
      refute Map.has_key?(body, "tools")
    end
  end

  defp body(conn) do
    {:ok, bytes, _} = Plug.Conn.read_body(conn)
    Jason.decode!(bytes)
  end

  defp output,
    do:
      ~s({"answer":"Synthetic connector evidence requires explicit review.","citation_ids":["E1"]})

  defp response("ollama", text),
    do: %{"done" => true, "response" => text, "prompt_eval_count" => 20, "eval_count" => 10}

  defp response("openai", text),
    do: %{
      "choices" => [%{"message" => %{"content" => text}, "finish_reason" => "stop"}],
      "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 10}
    }

  defp response("openai_responses", text),
    do: %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ],
      "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
    }

  defp response("anthropic", text),
    do: %{
      "type" => "message",
      "role" => "assistant",
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
    }
end
