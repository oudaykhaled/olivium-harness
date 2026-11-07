defmodule HarnessForgeWeb.CodingConnectionsTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{Decisions, Demo, Evidence, Harnesses, Models, Workspaces}
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    {:ok, _} = Demo.load()
    {:ok, claims} = Evidence.list_claims()
    claim = Enum.find(claims, &(not String.starts_with?(&1["text"], "IGNORE")))

    {:ok, _} =
      Decisions.decide(claim["id"], %{
        "actor" => Workspaces.operator(),
        "decision" => "approve",
        "expected_revision_hash" => claim["revision_hash"]
      })

    {:ok, sources} = Evidence.list_sources()
    conn = %{conn | host: "localhost", port: 4002}

    {:ok, view, _} =
      live(init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}), "/")

    {:ok, view: view, source: hd(sources)}
  end

  test "portal builds real Codex and Claude native packages from approved evidence", %{view: view} do
    view |> element("#nav-package") |> render_click()

    for target <- ~w(codex claude_code) do
      view
      |> form("#build-form", %{
        "package" => %{
          "name" => "browser-#{target}",
          "version" => "0.1.0",
          "runtime" => target,
          "runtime_version" => "unqualified"
        }
      })
      |> render_submit()

      {:ok, artifacts} = Harnesses.list_artifacts()

      artifact =
        Enum.find(artifacts, &(get_in(&1, ["spec", "metadata", "name"]) == "browser-#{target}"))

      assert artifact["manifest"]["adapter"]["name"] == target
      assert has_element?(view, "#artifact-#{artifact["digest"]}", target)
    end
  end

  test "cloud setup persists exact provider consent and decimal prices without dispatch", %{
    view: view,
    source: source
  } do
    view |> element("#nav-connections") |> render_click()

    for provider <- ~w(openai_responses anthropic openai) do
      render_change(view, "model_changed", %{"model" => %{"provider" => provider}})
      assert has_element?(view, "#model-key")

      view
      |> form("#model-form", %{
        "model" => %{
          "provider" => provider,
          "model" => "fixture-model",
          "credential_env" => "HARNESSFORGE_SURFACE_KEY",
          "input_price" => "1.25",
          "output_price" => "2.500001",
          "source_ids" => [source["id"]],
          "cloud_consent_ack" => "true"
        }
      })
      |> render_submit()

      assert has_element?(view, "#notice", "No inference was started")
      config = HarnessForge.Models.Configuration.get()
      assert config["provider"] == provider
      assert config["cloud_consent"]["source_ids"] == [source["id"]]
      assert config["cloud_consent"]["provider"] == provider
      assert config["cloud_consent"]["data_categories"] == ["source_body"]
      assert config["input_microusd_per_million"] == 1_250_000
      assert config["output_microusd_per_million"] == 2_500_001
      assert Models.status()["compatibility"] == "fixture_tested_live_unverified"
    end
  end

  test "saving a cloud provider without consent leaves egress disabled and raw keys rejected", %{
    view: view
  } do
    view |> element("#nav-connections") |> render_click()

    attrs = %{
      "provider" => "anthropic",
      "model" => "fixture-model",
      "credential_env" => "HARNESSFORGE_SURFACE_KEY",
      "input_price" => "1",
      "output_price" => "1"
    }

    render_submit(view, "model_configure", %{"model" => attrs})
    assert HarnessForge.Models.Configuration.get()["cloud_consent"] == nil
    assert Models.status()["reason"] == "cloud_consent_required"

    render_submit(view, "model_configure", %{
      "model" => Map.put(attrs, "credential_env", "sk-ant-do-not-store")
    })

    assert has_element?(view, "#error", "API key reference")
    refute render(view) =~ "sk-ant-do-not-store"
  end
end
