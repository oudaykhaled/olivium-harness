defmodule HarnessForge.ModelsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Models, Evidence, Audit}
  alias HarnessForge.Models.{Configuration, Ledger, Proposal, Request}

  setup do
    previous = Application.get_env(:harness_forge, :model_test_plug)
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})
    directory = Path.join(File.cwd!(), ".models-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic fixture",
        "provider" => "local",
        "directory" => directory
      })

    {:ok, source} =
      Evidence.import_markdown(connection["id"], %{
        "external_id" => "synthetic.md",
        "title" => "Public synthetic fixture",
        "body" => "Café uses explicit approvals."
      })

    on_exit(fn ->
      File.rm_rf!(directory)

      if previous,
        do: Application.put_env(:harness_forge, :model_test_plug, previous),
        else: Application.delete_env(:harness_forge, :model_test_plug)

      System.delete_env("HARNESSFORGE_SYNTHETIC_KEY")
    end)

    %{source: source, connection: connection}
  end

  test "model starts unselected and cloud disabled; raw credentials and unsafe endpoints fail" do
    assert %{
             "availability" => "unavailable",
             "reason" => "model_not_selected",
             "local_only" => true
           } = Models.status()

    for endpoint <- [
          "http://example.com:11434",
          "http://127.0.0.1:11434/api",
          "http://127.0.0.1:11434?x=y",
          "http://user@localhost:11434",
          "http://127.0.0.1.evil:11434",
          "https://127.0.0.1:11434",
          "http://127.1:11434"
        ] do
      assert {:error, :unsafe_model_endpoint} = Models.configure(%{"endpoint" => endpoint})
    end

    assert {:error, :invalid_model_configuration} = Models.configure(%{"token" => "sk-secret"})

    assert {:ok, %{"endpoint" => "http://127.0.0.1:11434"}} =
             Models.configure(%{
               "model" => "synthetic:fixture",
               "endpoint" => "http://localhost:11434"
             })

    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
    assert %{"reason" => "model_service_unavailable"} = Models.status()
  end

  test "local Ollama request proposes exact captured citations and never approves", %{
    source: source
  } do
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    stub_ollama(source, valid_output(source))
    assert %{"availability" => "available"} = Models.status()

    assert {:ok,
            %{
              "claims" => [claim],
              "status" => "proposed",
              "usage_status" => "reported",
              "billing_status" => "local_unpriced"
            }} = Models.propose(source["id"])

    assert claim["status"] == "proposed"
    assert hd(claim["citations"])["snippet"] == "Café"
    assert {:ok, []} = Evidence.approved_claims()
  end

  test "unknown authority fields, invented references and forged UTF-8 spans reject all claims",
       %{source: source} do
    valid = valid_output(source)
    citation = hd(hd(valid["claims"])["citations"])

    bad_citations = [
      Map.put(citation, "source_id", Ecto.UUID.generate()),
      Map.put(citation, "revision_id", Ecto.UUID.generate()),
      Map.put(citation, "snippet", "forged"),
      Map.put(citation, "end_byte", 4),
      Map.put(citation, "start_byte", -1),
      Map.put(citation, "end_byte", 999)
    ]

    for bad <- bad_citations do
      assert {:error, :invalid_model_output} =
               Proposal.validate(
                 Jason.encode!(%{"claims" => [%{"text" => "Claim", "citations" => [bad]}]}),
                 source
               )
    end

    assert {:error, :invalid_model_output} =
             Proposal.validate(Jason.encode!(Map.put(valid, "approve", true)), source)

    assert {:error, :invalid_model_output} =
             Proposal.validate(
               Jason.encode!(%{"claims" => [Map.put(hd(valid["claims"]), "status", "approved")]}),
               source
             )

    assert {:error, :invalid_model_output} =
             Proposal.validate("{\"claims\":[],\"claims\":[]}", source)

    assert {:error, :invalid_model_output} =
             Proposal.validate(String.duplicate("x", 131_073), source)

    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    stub_ollama(source, Map.put(valid, "permission", "allow"))
    assert {:error, :invalid_model_output} = Models.propose(source["id"])
    assert {:ok, []} = Evidence.list_claims()
  end

  test "cloud calls require persisted destination, categories, source scope and env reference", %{
    source: source
  } do
    cloud = cloud_config(source)
    assert {:ok, _} = Models.configure(Map.put(cloud, "cloud_consent", nil))
    {:ok, _} = Models.start_run("cloud-denied")
    assert {:error, :cloud_consent_required} = Models.infer(request("cloud-denied", "1", source))
    assert {:ok, []} = Models.list_requests("cloud-denied")
    assert {:ok, _} = Models.configure(cloud)
    System.put_env("HARNESSFORGE_SYNTHETIC_KEY", "sk-synthetic-do-not-persist")

    wrong_scope =
      request("cloud-denied", "2", source) |> Map.put("data_categories", ["unconsented"])

    assert {:error, :cloud_consent_required} = Models.infer(wrong_scope)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "api.openai.com"
      assert conn.request_path == "/v1/chat/completions"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer sk-synthetic-do-not-persist"
             ]

      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(bytes)
      assert body["store"] == false
      assert body["response_format"]["json_schema"]["strict"] == true
      refute Map.has_key?(body, "tools")

      Req.Test.json(conn, %{
        "choices" => [
          %{
            "message" => %{"content" => Jason.encode!(valid_output(source))},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 18, "completion_tokens" => 40}
      })
    end)

    assert {:ok, %{"billing_status" => "estimated"}} =
             Models.infer(request("cloud-denied", "3", source))

    assert {:ok, events} = Audit.list_events()
    assert {:ok, requests} = Models.list_requests("cloud-denied")
    refute Jason.encode!(events) =~ "sk-synthetic"
    refute Jason.encode!(requests) =~ "sk-synthetic"
    refute Jason.encode!(requests) =~ "Café"
    refute Jason.encode!(Configuration.get()) =~ "sk-synthetic"
  end

  test "cloud estimates cannot imply a free paid call", %{source: source} do
    {:ok, _} = Models.configure(cloud_config(source) |> Map.put("input_microusd_per_million", 0))
    {:ok, _} = Models.start_run("missing-estimate")

    assert {:error, :cloud_cost_estimate_required} =
             Models.infer(request("missing-estimate", "1", source))
  end

  test "timeouts and redirects never retry; unknown usage retains reservation and fences same request",
       %{source: source} do
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" -> tags(conn)
        "/api/generate" -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    {:ok, _} = Models.start_run("uncertain")
    req = request("uncertain", "once", source)
    assert {:error, :model_service_unavailable} = Models.infer(req)
    assert {:error, :request_already_dispatched} = Models.infer(req)

    assert {:error, :request_outcome_unknown} =
             Models.infer(%{req | "request_id" => "blind-retry"})

    assert {:ok,
            [
              %{
                "state" => "uncertain",
                "usage_status" => "unknown",
                "billing_status" => "unknown"
              } = entry
            ]} = Models.list_requests("uncertain")

    assert {:ok, %{"reserved_requests" => 1, "reserved_tokens" => tokens}} =
             Models.budget("uncertain")

    assert tokens == entry["reserved_tokens"] and tokens > 0

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          tags(conn)

        "/api/generate" ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://evil.invalid")
          |> Plug.Conn.send_resp(307, "")
      end
    end)

    {:ok, _} = Models.start_run("redirect-denial")

    assert {:error, :model_redirect_denied} =
             Models.infer(%{req | "request_id" => "redirect", "run_id" => "redirect-denial"})
  end

  test "run limits are immutable and token, request and advisory cost reservations deny before transport",
       %{source: source} do
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    {:ok, _} = Models.start_run("tiny", %{"max_tokens" => 1, "max_requests" => 1})
    assert {:error, :invalid_budget} = Models.start_run("tiny", %{"max_tokens" => 999_999})
    assert {:ok, %{"max_tokens" => 1, "max_requests" => 1}} = Models.budget("tiny")
    assert {:error, :budget_exhausted} = Models.infer(request("tiny", "1", source))
    assert {:ok, []} = Models.list_requests("tiny")
    {:ok, _} = Models.configure(cloud_config(source))
    System.put_env("HARNESSFORGE_SYNTHETIC_KEY", "sk-synthetic")
    {:ok, _} = Models.start_run("cost", %{"max_estimated_microusd" => 1})
    assert {:error, :budget_exhausted} = Models.infer(request("cost", "1", source))
  end

  test "concurrent calls share one atomic request budget", %{source: source} do
    {:ok, _} = Models.start_run("concurrent", %{"max_requests" => 1})
    config = Map.put(Configuration.get(), "model", "synthetic:fixture")

    outcomes =
      1..8
      |> Task.async_stream(
        fn index ->
          req =
            request("concurrent", Integer.to_string(index), source)
            |> Map.put("prompt", "Synthetic #{index}")

          Ledger.reserve(req, config, 30)
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
    assert Enum.count(outcomes, &(&1 == {:error, :budget_exhausted})) == 7
    assert {:ok, %{"reserved_requests" => 1}} = Models.budget("concurrent")
  end

  test "crashed or killed dispatch stays fenced and cannot become zero usage", %{source: source} do
    {:ok, _} = Models.start_run("crash")
    config = Map.put(Configuration.get(), "model", "synthetic:fixture")
    req = request("crash", "same", source)
    assert {:ok, _} = Ledger.reserve(req, config, 20)
    assert {:error, :request_already_dispatched} = Ledger.reserve(req, config, 20)

    assert {:ok, [%{"state" => "dispatched", "usage_status" => "unknown", "input_tokens" => nil}]} =
             Models.list_requests("crash")

    assert Repo.aggregate(Request, :count) == 1
  end

  test "reported usage reconciles while unknown successful usage keeps reservation", %{
    source: source
  } do
    {:ok, _} = Models.start_run("reported")
    config = Map.put(Configuration.get(), "model", "synthetic:fixture")
    req = request("reported", "1", source)
    {:ok, reservation} = Ledger.reserve(req, config, 30)

    assert {:ok, :reconciled} =
             Ledger.reconcile(reservation, {:ok, %{input_tokens: 5, output_tokens: 7}}, config)

    assert {:ok, %{"reserved_tokens" => 12}} = Models.budget("reported")

    assert {:ok, :reconciled} =
             Ledger.reconcile(reservation, {:ok, %{input_tokens: 5, output_tokens: 7}}, config)

    assert {:ok, %{"reserved_tokens" => 12}} = Models.budget("reported")
    {:ok, next} = Ledger.reserve(%{req | "request_id" => "2"}, config, 30)

    assert {:ok, :uncertain} =
             Ledger.reconcile(next, {:ok, %{input_tokens: nil, output_tokens: nil}}, config)

    assert {:ok, %{"reserved_tokens" => retained}} = Models.budget("reported")
    assert retained == 12 + next["reserved_tokens"]
  end

  test "remote Ollama cloud models cannot bypass consent and response bytes are bounded", %{
    source: source
  } do
    {:ok, _} = Models.configure(%{"model" => "synthetic-cloud"})
    {:ok, _} = Models.start_run("cloud-model")
    assert {:error, :cloud_model_denied} = Models.infer(request("cloud-model", "1", source))
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            "models" => [%{"name" => "synthetic:fixture", "remote_host" => "https://ollama.com"}]
          })
      end
    end)

    assert %{"reason" => "cloud_model_denied"} = Models.status()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" -> tags(conn)
        "/api/generate" -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 262_145))
      end
    end)

    assert {:error, :model_response_too_large} = Models.infer(request("cloud-model", "2", source))
  end

  test "revoked source connections deny egress before reservation", %{
    source: source,
    connection: connection
  } do
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    {:ok, _} = Models.start_run("revoked")
    {:ok, _} = Evidence.revoke_connection(connection["id"])
    assert {:error, :source_unavailable} = Models.infer(request("revoked", "1", source))
    assert {:ok, []} = Models.list_requests("revoked")
  end

  test "unreported usage remains unknown at both caller and ledger boundaries", %{source: source} do
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    {:ok, _} = Models.start_run("unknown-success")

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" -> tags(conn)
        "/api/generate" -> Req.Test.json(conn, %{"response" => "{\"claims\":[]}", "done" => true})
      end
    end)

    assert {:ok,
            %{"usage_status" => "unknown", "billing_status" => "unknown", "input_tokens" => nil}} =
             Models.infer(request("unknown-success", "1", source))

    assert {:ok, [%{"state" => "uncertain", "billing_status" => "unknown"}]} =
             Models.list_requests("unknown-success")
  end

  defp request(run, id, source),
    do: %{
      "run_id" => run,
      "request_id" => id,
      "prompt" => "Synthetic only",
      "source_ids" => [source["id"]],
      "data_categories" => ["source_body"],
      "max_output_tokens" => 128
    }

  defp valid_output(source),
    do: %{
      "claims" => [
        %{
          "text" => "Use explicit approvals",
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
    }

  defp cloud_config(source),
    do: %{
      "provider" => "openai",
      "endpoint" => "https://api.openai.com/v1",
      "model" => "synthetic-fixture-only",
      "credential_env" => "HARNESSFORGE_SYNTHETIC_KEY",
      "input_microusd_per_million" => 1_000_000,
      "output_microusd_per_million" => 1_000_000,
      "cloud_consent" => %{
        "provider" => "openai",
        "endpoint" => "https://api.openai.com/v1",
        "source_ids" => [source["id"]],
        "data_categories" => ["source_body"]
      }
    }

  defp tags(conn), do: Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})

  defp stub_ollama(_source, output) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          tags(conn)

        "/api/generate" ->
          {:ok, bytes, conn} = Plug.Conn.read_body(conn)
          body = Jason.decode!(bytes)
          assert body["stream"] == false
          assert body["options"]["temperature"] == 0
          assert body["format"] == Proposal.schema()

          Req.Test.json(conn, %{
            "response" => Jason.encode!(output),
            "done" => true,
            "prompt_eval_count" => 25,
            "eval_count" => 50
          })
      end
    end)
  end
end
