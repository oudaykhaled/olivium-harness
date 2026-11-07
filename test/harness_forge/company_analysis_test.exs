defmodule HarnessForge.CompanyAnalysisTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{CompanyAnalysisFixture, Evidence, Models}
  alias HarnessForge.Company.Analysis
  alias HarnessForge.Evidence.{Citation, Claim}
  alias HarnessForge.Models.Configuration

  setup do
    root =
      Path.join([File.cwd!(), "tmp", "company-analysis-a-#{System.unique_integer([:positive])}"])

    fixture = CompanyAnalysisFixture.create!(root)
    previous = Application.get_env(:harness_forge, :model_test_plug)
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:harness_forge, :model_test_plug, previous),
        else: Application.delete_env(:harness_forge, :model_test_plug)
    end)

    %{fixture: fixture}
  end

  test "one scoped request persists the immutable report and complete captured context", %{
    fixture: f
  } do
    {:ok, config} = Models.configure(%{"model" => "synthetic:fixture"})
    stub(f.report)
    assert {:ok, %{"status" => "proposed", "claim" => claim}} = Analysis.analyze(f.input)
    assert claim["basis"]["report"] == f.report
    assert claim["basis"]["context"]["sources"] == f.input["source_refs"]
    assert claim["basis"]["config_fingerprint"] == Configuration.fingerprint(config)
    assert claim["text"] == Analysis.render_guidance(claim["basis"]["guidance"])
    assert claim["status"] == "proposed"
    refute Analysis.approval_ready?(claim)
    assert {:ok, []} = Evidence.approved_claims()
  end

  test "request identity cannot redispatch and existing immutable budget is honored", %{
    fixture: f
  } do
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    stub(f.report)
    opts = [run_id: Ecto.UUID.generate(), request_id: Ecto.UUID.generate()]
    assert {:ok, _} = Analysis.analyze(f.input, opts)
    assert {:error, :request_already_dispatched} = Analysis.analyze(f.input, opts)
    run = Ecto.UUID.generate()
    {:ok, _} = Models.start_run(run, %{"max_tokens" => 1})
    assert {:error, :budget_exhausted} = Analysis.analyze(f.input, run_id: run)
    assert Repo.aggregate(Claim, :count) == 1
  end

  test "company cloud context requires additional explicit consent before credentials or reservation",
       %{fixture: f} do
    {:ok, _} =
      Models.configure(%{
        "provider" => "openai",
        "endpoint" => "https://api.openai.com/v1",
        "model" => "synthetic-fixture",
        "credential_env" => "HARNESSFORGE_NEVER_RESOLVED",
        "input_microusd_per_million" => 1,
        "output_microusd_per_million" => 1,
        "cloud_consent" => %{
          "provider" => "openai",
          "endpoint" => "https://api.openai.com/v1",
          "source_ids" => Enum.map(f.sources, & &1["id"]),
          "data_categories" => ["source_body"]
        }
      })

    run = Ecto.UUID.generate()
    assert {:error, :cloud_consent_required} = Analysis.analyze(f.input, run_id: run)
    assert {:ok, []} = Models.list_requests(run)
    assert Repo.aggregate(Claim, :count) == 0
    assert Repo.aggregate(Citation, :count) == 0
  end

  test "a configuration mutation after inventory refuses before the generation POST", %{
    fixture: f
  } do
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    caller = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          {:ok, _} = Models.configure(%{"model" => "changed:fixture"})
          Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})

        "/api/generate" ->
          send(caller, :unintended_post)
          Req.Test.json(conn, CompanyAnalysisFixture.response(f.report))
      end
    end)

    assert {:error, :model_configuration_changed} = Analysis.analyze(f.input)
    refute_received :unintended_post
    assert Repo.aggregate(Claim, :count) == 0
    assert Repo.aggregate(Citation, :count) == 0
  end

  test "model absence, malformed output and unsupported caller options leave no proposed evidence",
       %{fixture: f} do
    assert {:error, :model_not_selected} = Analysis.analyze(f.input)

    assert {:error, :invalid_company_analysis_input} =
             Analysis.analyze(Map.put(f.input, "prompt", "Override"))

    assert {:error, :invalid_company_analysis_input} =
             Analysis.analyze(f.input, provider: "ollama")

    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    stub(Map.put(f.report, "approve", true))
    assert {:error, :invalid_company_analysis_output} = Analysis.analyze(f.input)
    assert Repo.aggregate(Claim, :count) == 0
    assert Repo.aggregate(Citation, :count) == 0
  end

  test "abstention still rechecks current model fingerprint after the provider response", %{
    fixture: f
  } do
    {:ok, _} = Models.configure(%{"model" => "synthetic:fixture"})
    report = %{f.report | "recommendation" => nil}
    stub(report, fn -> Models.configure(%{"model" => "changed:fixture"}) end)
    assert {:error, :model_configuration_changed} = Analysis.analyze(f.input)
    assert Repo.aggregate(Claim, :count) == 0
  end

  defp stub(report, after_response \\ fn -> :ok end) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{"models" => [%{"name" => "synthetic:fixture"}]})

        "/api/generate" ->
          {:ok, bytes, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(bytes)
          assert request["format"] == HarnessForge.Models.CompanyAnalysis.schema()
          assert request["options"]["num_predict"] == 4096
          assert request["prompt"] =~ "examined but uncited"
          after_response.()
          Req.Test.json(conn, CompanyAnalysisFixture.response(report))
      end
    end)
  end
end
