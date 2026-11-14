defmodule HarnessForge.CloudModelConnectorsTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{Audit, Evidence, Models, Privacy, Repo}
  alias HarnessForge.Models.{Configuration, Proposal}

  @providers ~w(openai_responses anthropic)
  @credential "HARNESSFORGE_CLOUD_FIXTURE_KEY"

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: tags[:committed] != true)
    previous = Application.get_env(:harness_forge, :model_test_plug)
    old_root = Application.get_env(:harness_forge, :workspace_root)
    old_id = Application.get_env(:harness_forge, :workspace_id)
    old_credential = System.get_env(@credential)
    id = Ecto.UUID.generate()
    base = Path.join(File.cwd!(), ".cloud-model-test-" <> id)
    root = Path.join(base, "workspace")
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, id)
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})
    System.put_env(@credential, "synthetic-never-persist")

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic model scope",
        "provider" => "local",
        "directory" => root
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "fixture.md",
        "title" => "Synthetic evidence",
        "body" => "Café requires explicit review."
      })

    on_exit(fn ->
      Application.put_env(:harness_forge, :workspace_root, old_root)
      Application.put_env(:harness_forge, :workspace_id, old_id)

      if previous,
        do: Application.put_env(:harness_forge, :model_test_plug, previous),
        else: Application.delete_env(:harness_forge, :model_test_plug)

      if old_credential,
        do: System.put_env(@credential, old_credential),
        else: System.delete_env(@credential)

      File.rm_rf!(base)
    end)

    Req.Test.verify_on_exit!()
    %{source: source, root: root, base: base}
  end

  test "fixed destinations and provider-bound consent reject alternate routes and raw keys", %{
    source: source
  } do
    for provider <- @providers do
      config = config(provider, source)
      assert {:ok, _} = Models.configure(config)

      assert %{
               "provider" => ^provider,
               "compatibility" => "fixture_tested_live_unverified",
               "availability" => "available"
             } = Models.status()

      for endpoint <-
            [
              endpoint(provider) <> "/",
              endpoint(provider) <> "?x=1",
              "http://api.openai.com/v1",
              "https://api.openai.com.evil.invalid/v1",
              "https://user@api.openai.com/v1",
              "https://api.anthropic.com:443/v1"
            ] -- [endpoint(provider)] do
        assert {:error, :unsafe_model_endpoint} =
                 Models.configure(Map.put(config, "endpoint", endpoint))
      end

      assert {:error, :invalid_model_configuration} =
               Models.configure(Map.put(config, "credential_env", "sk-raw-secret"))

      assert {:error, :invalid_model_configuration} =
               Models.configure(Map.put(config, "api_key", "raw"))

      assert {:error, :invalid_cloud_consent} =
               Models.configure(put_in(config, ["cloud_consent", "provider"], "different"))

      assert {:error, :invalid_cloud_consent} =
               Models.configure(
                 put_in(config, ["cloud_consent", "endpoint"], "https://evil.invalid")
               )
    end
  end

  test "OpenAI Responses proposes captured citations through metering without double-counted reasoning",
       %{source: source} do
    configure("openai_responses", source)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "api.openai.com" and conn.request_path == "/v1/responses" and
               conn.method == "POST"

      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-never-persist"]
      body = body(conn)
      assert body["store"] == false and body["stream"] == false
      assert body["tools"] == [] and body["tool_choice"] == "none"

      assert body["text"]["format"] == %{
               "name" => "proposed_claims",
               "type" => "json_schema",
               "strict" => true,
               "schema" => Proposal.schema()
             }

      assert body["instructions"] == Proposal.system()
      assert Jason.decode!(hd(body["input"])["content"])["source_id"] == source["id"]
      Req.Test.json(conn, response("openai_responses", output(source)))
    end)

    assert {:ok,
            %{
              "claims" => [claim],
              "status" => "proposed",
              "input_tokens" => 18,
              "output_tokens" => 40,
              "billing_status" => "estimated"
            }} = Models.propose(source["id"], run_id: "responses-happy", request_id: "one")

    assert claim["status"] == "proposed" and hd(claim["citations"])["snippet"] == "Café"
    assert {:ok, []} = Evidence.approved_claims()

    assert {:ok, %{"reserved_tokens" => 58, "reserved_estimated_microusd" => 58}} =
             Models.budget("responses-happy")

    assert {:ok,
            [
              %{
                "provider" => "openai_responses",
                "billing_status" => "estimated",
                "state" => "completed"
              }
            ]} = Models.list_requests("responses-happy")

    assert {:error, :request_already_dispatched} =
             Models.propose(source["id"], run_id: "responses-happy", request_id: "one")

    assert_redacted("responses-happy")
  end

  test "Anthropic Messages proposes with constrained JSON and includes cache tokens in input total",
       %{source: source} do
    configure("anthropic", source)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "api.anthropic.com" and conn.request_path == "/v1/messages" and
               conn.method == "POST"

      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["synthetic-never-persist"]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2026-10-21"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      body = body(conn)
      assert body["stream"] == false and body["system"] == Proposal.system()
      assert body["max_tokens"] == Proposal.default_output_tokens()
      refute Map.has_key?(body, "tools")
      refute Map.has_key?(body, "temperature")
      schema = body["output_config"]["format"]["schema"]
      assert schema["additionalProperties"] == false
      assert schema["properties"]["claims"]["items"]["properties"]["citations"]["minItems"] == 1
      refute Jason.encode!(schema) =~ "maxLength"
      refute Jason.encode!(schema) =~ "maxItems"
      Req.Test.json(conn, response("anthropic", output(source)))
    end)

    assert {:ok,
            %{
              "claims" => [claim],
              "input_tokens" => 30,
              "output_tokens" => 40,
              "usage_status" => "reported",
              "billing_status" => "estimated"
            }} = Models.propose(source["id"], run_id: "anthropic-happy")

    assert claim["status"] == "proposed"
    assert {:ok, []} = Evidence.approved_claims()

    assert {:ok, %{"reserved_tokens" => 70, "reserved_estimated_microusd" => 70}} =
             Models.budget("anthropic-happy")

    assert_redacted("anthropic-happy")
  end

  test "cloud consent and declared rates fence dispatch before a reservation", %{source: source} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("denied requests must never reach transport") end)

    for provider <- @providers do
      config = config(provider, source)
      {:ok, _} = Models.configure(Map.put(config, "cloud_consent", nil))
      {:ok, _} = Models.start_run(provider <> "-consent")
      req = request(provider <> "-consent", "one", source)
      assert {:error, :cloud_consent_required} = Models.infer(req)
      assert {:ok, []} = Models.list_requests(req["run_id"])
      configure(provider, source)

      assert {:error, :cloud_consent_required} =
               Models.infer(Map.put(req, "data_categories", ["unconsented"]))

      assert {:error, :cloud_consent_required} =
               Models.infer(Map.put(req, "source_ids", [Ecto.UUID.generate()]))

      {:ok, _} = Models.configure(Map.put(config, "output_microusd_per_million", 0))
      assert {:error, :cloud_cost_estimate_required} = Models.infer(req)
      assert {:ok, []} = Models.list_requests(req["run_id"])
    end
  end

  test "missing, oversized and multiline credential values fail before reservation", %{
    source: source
  } do
    Req.Test.stub(__MODULE__, fn _ -> flunk("invalid credentials must never reach transport") end)

    for provider <- @providers do
      configure(provider, source)
      run = provider <> "-credentials"
      {:ok, _} = Models.start_run(run)

      for value <- [nil, "", "key\r\nInjected: value", "key\n", String.duplicate("k", 16_385)] do
        if is_nil(value),
          do: System.delete_env(@credential),
          else: System.put_env(@credential, value)

        assert {:error, :credential_unavailable} = Models.infer(request(run, "one", source))
        assert {:ok, []} = Models.list_requests(run)
      end

      System.put_env(@credential, "synthetic-never-persist")
    end
  end

  test "HTTP errors and redirects preserve reservations without retrying or exposing bodies", %{
    source: source
  } do
    errors = [
      {401, :model_authentication_denied},
      {403, :model_authentication_denied},
      {404, :model_unavailable},
      {429, :model_rate_limited},
      {503, :model_service_unavailable},
      {307, :model_redirect_denied}
    ]

    for provider <- @providers, {status, expected} <- errors do
      configure(provider, source)
      run = "#{provider}-http-#{status}"
      {:ok, _} = Models.start_run(run)
      req = request(run, "once", source)

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.invalid")
        |> Plug.Conn.send_resp(status, "synthetic-never-persist-private-body")
      end)

      assert {:error, ^expected} = Models.infer(req)
      assert {:error, :request_already_dispatched} = Models.infer(req)

      assert {:error, :request_outcome_unknown} =
               Models.infer(Map.put(req, "request_id", "blind-retry"))

      assert_reserved(run)
      assert_redacted(run)
    end
  end

  test "transport failure is uncertain and never redispatched", %{source: source} do
    for provider <- @providers do
      configure(provider, source)
      run = provider <> "-timeout"
      {:ok, _} = Models.start_run(run)
      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
      req = request(run, "one", source)
      assert {:error, :model_service_unavailable} = Models.infer(req, timeout: 1)
      assert {:error, :request_outcome_unknown} = Models.infer(Map.put(req, "request_id", "two"))
      assert_reserved(run)
    end
  end

  test "HTTP 200 provider error envelopes fail safely and cannot masquerade as successful text",
       %{source: source} do
    for provider <- @providers,
        {type, reason} <- [
          {"authentication_error", :model_authentication_denied},
          {"rate_limit_error", :model_rate_limited},
          {"new_unknown_error", :model_service_unavailable}
        ] do
      configure(provider, source)
      run = provider <> "-" <> type
      {:ok, _} = Models.start_run(run)

      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(&1, %{
          "type" => "error",
          "error" => %{"type" => type, "message" => "synthetic-never-persist-private-body"}
        })
      )

      assert {:error, ^reason} = Models.infer(request(run, "one", source))
      assert_reserved(run)
      assert_redacted(run)
    end
  end

  test "Responses rejects partial, refused, tool and malformed output envelopes", %{
    source: source
  } do
    configure("openai_responses", source)
    valid = response("openai_responses", output(source))

    values = [
      Map.put(valid, "status", "incomplete"),
      Map.put(valid, "incomplete_details", %{"reason" => "max_output_tokens"}),
      Map.put(valid, "output", []),
      Map.put(valid, "output", [%{"type" => "function_call", "name" => "approve"}]),
      put_in(valid, ["output", Access.at(1), "status"], "in_progress"),
      put_in(valid, ["output", Access.at(1), "content"], [
        %{"type" => "refusal", "refusal" => "no"}
      ]),
      Map.put(valid, "output", [
        %{"type" => "message", "role" => "user", "status" => "completed", "content" => []}
      ])
    ]

    for {value, index} <- Enum.with_index(values) do
      run = "responses-envelope-#{index}"
      {:ok, _} = Models.start_run(run)
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, value))
      assert {:error, :invalid_provider_response} = Models.infer(request(run, "one", source))
      assert_reserved(run)
    end

    assert {:ok, []} = Evidence.list_claims()
  end

  test "Anthropic ignores thinking blocks that precede the answer", %{source: source} do
    configure("anthropic", source)
    text = output(source)

    for {blocks, index} <-
          Enum.with_index([
            [
              %{"type" => "thinking", "thinking" => "hidden"},
              %{"type" => "text", "text" => text}
            ],
            [%{"type" => "redacted_thinking", "data" => "x"}, %{"type" => "text", "text" => text}]
          ]) do
      value = Map.put(response("anthropic", text), "content", blocks)
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, value))

      assert {:ok, %{"claims" => [%{"status" => "proposed"}]}} =
               Models.propose(source["id"], run_id: "anthropic-thinking-#{index}")
    end

    assert {:ok, []} = Evidence.approved_claims()
  end

  test "Anthropic rejects truncated, refused and nontext content even with a successful HTTP status",
       %{source: source} do
    configure("anthropic", source)
    valid = response("anthropic", output(source))

    values =
      Enum.map(~w(max_tokens refusal tool_use pause_turn), &Map.put(valid, "stop_reason", &1)) ++
        [
          Map.put(valid, "content", []),
          Map.put(valid, "content", [%{"type" => "tool_use", "name" => "approve"}]),
          Map.put(valid, "content", [%{"type" => "thinking", "thinking" => "hidden"}]),
          Map.put(valid, "content", [%{"type" => "text", "text" => nil}])
        ]

    for {value, index} <- Enum.with_index(values) do
      run = "anthropic-envelope-#{index}"
      {:ok, _} = Models.start_run(run)
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, value))
      assert {:error, :invalid_provider_response} = Models.infer(request(run, "one", source))
      assert_reserved(run)
    end

    assert {:ok, []} = Evidence.list_claims()
  end

  test "missing or malformed usage retains full token and cost reservations", %{source: source} do
    for provider <- @providers,
        {usage, index} <-
          Enum.with_index([
            nil,
            %{},
            %{"input_tokens" => 12, "output_tokens" => "unknown"},
            %{"input_tokens" => 12, "output_tokens" => 3, "cache_read_input_tokens" => nil}
          ]) do
      configure(provider, source)
      run = "#{provider}-unknown-#{index}"
      {:ok, _} = Models.start_run(run)
      value = Map.put(response(provider, output(source)), "usage", usage)
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, value))
      assert {:ok, result} = Models.infer(request(run, "one", source))

      if provider == "openai_responses" and index == 3 do
        assert result["usage_status"] == "reported"
      else
        assert result["usage_status"] == "unknown" and result["billing_status"] == "unknown"
        assert result["input_tokens"] == nil and result["output_tokens"] == nil
        assert_reserved(run)
      end
    end
  end

  test "response, text and token limits are enforced without losing reported overruns", %{
    source: source
  } do
    for provider <- @providers do
      configure(provider, source)
      run = provider <> "-oversize"
      {:ok, _} = Models.start_run(run)
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, String.duplicate("x", 262_145)))
      assert {:error, :model_response_too_large} = Models.infer(request(run, "one", source))
      assert_reserved(run)

      run = provider <> "-text-limit"
      {:ok, _} = Models.start_run(run)

      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(&1, response(provider, String.duplicate("x", 131_073)))
      )

      assert {:error, :model_output_limit_exceeded} = Models.infer(request(run, "one", source))

      run = provider <> "-output-tokens"
      {:ok, _} = Models.start_run(run)
      value = put_in(response(provider, output(source)), ["usage", "output_tokens"], 129)
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, value))
      assert {:error, :model_output_limit_exceeded} = Models.infer(request(run, "one", source))

      assert {:ok,
              [
                %{
                  "output_tokens" => 129,
                  "usage_status" => "reported",
                  "billing_status" => "estimated"
                }
              ]} = Models.list_requests(run)
    end
  end

  test "malformed JSON and invented authority cannot persist proposals", %{source: source} do
    for provider <- @providers do
      configure(provider, source)
      run = provider <> "-authority"
      forged = output(source) |> Jason.decode!() |> Map.put("approve", true) |> Jason.encode!()
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, response(provider, forged)))
      assert {:error, :invalid_model_output} = Models.propose(source["id"], run_id: run)
      assert {:ok, []} = Evidence.list_claims()
      assert {:ok, []} = Evidence.approved_claims()

      run = provider <> "-json"
      {:ok, _} = Models.start_run(run)
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, "not-json-private-body"))
      assert {:error, :invalid_provider_response} = Models.infer(request(run, "one", source))
      assert_reserved(run)
    end
  end

  test "request and cost limits deny both cloud providers before transport", %{source: source} do
    Req.Test.stub(__MODULE__, fn _ -> flunk("exhausted budgets must not dispatch") end)

    for provider <- @providers do
      configure(provider, source)

      for {name, limits} <- [
            {"tokens", %{"max_tokens" => 1}},
            {"cost", %{"max_estimated_microusd" => 1}}
          ] do
        run = provider <> "-budget-" <> name
        {:ok, _} = Models.start_run(run, limits)
        assert {:error, :budget_exhausted} = Models.infer(request(run, "one", source))
        assert {:ok, []} = Models.list_requests(run)
      end
    end
  end

  test "source purge withdraws new cloud provider consent through the real privacy workflow", %{
    source: source,
    root: root
  } do
    for provider <- @providers do
      {:ok, connection} =
        Evidence.connect(%{"provider" => "local", "name" => provider, "directory" => root})

      {:ok, target} =
        Evidence.import_markdown(connection["id"], %{
          "external_id" => provider <> ".md",
          "body" => "Synthetic removable evidence",
          "title" => provider
        })

      configure(provider, target)
      assert {:ok, %{"state" => "completed"}} = Privacy.purge_source(target["id"], target["id"])
      assert Configuration.get()["cloud_consent"] == nil
      assert Configuration.get()["provider"] == "ollama"
      assert Configuration.get()["credential_env"] == nil
      assert {:error, :not_found} = Evidence.get_source(target["id"])
      assert {:ok, _} = Evidence.get_source(source["id"])
    end
  end

  @tag :committed
  test "backup restore withdraws both cloud provider configurations and never copies API credentials",
       %{source: source, base: base} do
    try do
      for provider <- @providers do
        configure(provider, source)
        backup = Path.join(base, provider <> "-backup")
        restored = Path.join(base, provider <> "-restored")
        assert {:ok, _} = Privacy.backup(backup)

        assert {:ok, %{"state" => "quarantined", "approvals_restored" => false}} =
                 Privacy.restore(backup, restored)

        {:ok, db} = Exqlite.Sqlite3.open(Path.join(restored, "data.sqlite3"))
        {:ok, statement} = Exqlite.Sqlite3.prepare(db, "SELECT count(*) FROM model_settings")
        assert {:ok, [[0]]} = Exqlite.Sqlite3.fetch_all(db, statement)
        :ok = Exqlite.Sqlite3.release(db, statement)
        :ok = Exqlite.Sqlite3.close(db)
        refute File.read!(Path.join(backup, "data.sqlite3")) =~ "synthetic-never-persist"
        refute File.read!(Path.join(restored, "data.sqlite3")) =~ "synthetic-never-persist"
      end
    after
      # This test needs committed data for VACUUM INTO. Remove its isolated
      # workspace through the real purge path before later backup tests run.
      assert {:ok, _} =
               Privacy.purge_workspace(Application.fetch_env!(:harness_forge, :workspace_id))
    end
  end

  defp config(provider, source) do
    %{
      "provider" => provider,
      "endpoint" => endpoint(provider),
      "model" => "synthetic-fixture-only",
      "credential_env" => @credential,
      "input_microusd_per_million" => 1_000_000,
      "output_microusd_per_million" => 1_000_000,
      "cloud_consent" => %{
        "provider" => provider,
        "endpoint" => endpoint(provider),
        "source_ids" => [source["id"]],
        "data_categories" => ["source_body"]
      }
    }
  end

  defp configure(provider, source),
    do: assert({:ok, _} = Models.configure(config(provider, source)))

  defp endpoint("anthropic"), do: "https://api.anthropic.com/v1"
  defp endpoint(_), do: "https://api.openai.com/v1"

  defp request(run, id, source),
    do: %{
      "run_id" => run,
      "request_id" => id,
      "prompt" => "Synthetic only",
      "source_ids" => [source["id"]],
      "data_categories" => ["source_body"],
      "max_output_tokens" => 128
    }

  defp output(source),
    do:
      Jason.encode!(%{
        "claims" => [
          %{
            "text" => "Require explicit review",
            "citations" => [
              %{
                "source_id" => source["id"],
                "revision_id" => source["latest_revision"]["id"],
                "start_byte" => 0,
                "end_byte" => 5,
                "snippet" => "Café"
              }
            ]
          }
        ]
      })

  defp response("openai_responses", text) do
    %{
      "id" => "resp_synthetic",
      "status" => "completed",
      "error" => nil,
      "incomplete_details" => nil,
      "output" => [
        %{"type" => "reasoning", "summary" => []},
        %{
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ],
      "usage" => %{
        "input_tokens" => 18,
        "output_tokens" => 40,
        "output_tokens_details" => %{"reasoning_tokens" => 10}
      }
    }
  end

  defp response("anthropic", text),
    do: %{
      "id" => "msg_synthetic",
      "type" => "message",
      "role" => "assistant",
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{
        "input_tokens" => 18,
        "cache_read_input_tokens" => 7,
        "cache_creation_input_tokens" => 5,
        "output_tokens" => 40
      }
    }

  defp body(conn) do
    {:ok, bytes, _} = Plug.Conn.read_body(conn)
    Jason.decode!(bytes)
  end

  defp assert_reserved(run) do
    assert {:ok,
            [
              %{
                "state" => "uncertain",
                "usage_status" => "unknown",
                "billing_status" => "unknown"
              } = entry
            ]} = Models.list_requests(run)

    assert {:ok, budget} = Models.budget(run)
    assert budget["reserved_tokens"] == entry["reserved_tokens"] and entry["reserved_tokens"] > 0

    assert budget["reserved_estimated_microusd"] == entry["reserved_estimated_microusd"] and
             entry["reserved_estimated_microusd"] > 0
  end

  defp assert_redacted(run) do
    {:ok, requests} = Models.list_requests(run)
    {:ok, events} = Audit.list_events()
    stored = Jason.encode!([requests, events, Configuration.get()])
    refute stored =~ "synthetic-never-persist"
    refute stored =~ "private-body"
    refute stored =~ "Synthetic only"
  end
end
