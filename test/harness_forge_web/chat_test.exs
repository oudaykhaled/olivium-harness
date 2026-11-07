defmodule HarnessForgeWeb.ChatTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias HarnessForge.{Demo, Evidence, Models}
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    {:ok, _} = Demo.load()
    {:ok, sources} = Evidence.list_sources()
    conn = %{conn | host: "localhost", port: 4002}

    {:ok, view, _} =
      live(init_test_session(conn, %{"operator_auth" => OperatorSession.new_auth()}), "/")

    {:ok, conn: conn, view: view, source: hd(sources)}
  end

  test "authenticated chat searches captured evidence and exposes every connector", %{view: view} do
    view |> element("#nav-chat") |> render_click()
    assert has_element?(view, "#chat-panel", "Your connector assistant")

    for provider <- ~w(local github github_projects jira slack confluence) do
      assert has_element?(view, "#chat-connector-#{provider}")
    end

    assert has_element?(view, "#chat-panel", "Codex")
    assert has_element?(view, "#chat-panel", "Claude")
    assert has_element?(view, "#chat-panel", "Anthropic")
    {:ok, before_claims} = Evidence.list_claims()

    view
    |> form("#chat-form", %{
      "chat" => %{"question" => "What tests are required?", "mode" => "evidence"}
    })
    |> render_submit()

    assert render_async(view) =~ "LOCAL EVIDENCE SEARCH"
    assert has_element?(view, "#chat-transcript", "Supporting evidence")
    assert has_element?(view, "#chat-transcript", "matching captured excerpts")
    assert has_element?(view, "#chat-transcript blockquote", "table-driven tests")
    assert {:ok, ^before_claims} = Evidence.list_claims()

    view |> element("#chat-clear") |> render_click()
    refute has_element?(view, "#chat-transcript article")
    assert has_element?(view, "#chat-transcript", "What would you like to find?")
  end

  test "model unavailable and malformed submissions stay explicit without inference", %{
    view: view
  } do
    view |> element("#nav-chat") |> render_click()

    view
    |> form("#chat-form", %{
      "chat" => %{"question" => "What tests are required?", "mode" => "model"}
    })
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#chat-error", "Configure an available model")
    refute has_element?(view, "#chat-transcript article")

    render_submit(view, "chat_send", %{"chat" => %{"question" => "", "mode" => "evidence"}})
    assert has_element?(view, "#chat-error", "Enter a question")

    render_submit(view, "chat_send", %{
      "chat" => %{"question" => "What tests are required?", "mode" => "launch-codex"}
    })

    assert has_element?(view, "#chat-error", "Choose evidence search")
  end

  test "chat text is escaped and cleared when its source is withdrawn", %{
    view: view,
    source: source
  } do
    view |> element("#nav-chat") |> render_click()
    question = "<img src=x onerror=alert(1)> What tests are required?"

    view
    |> form("#chat-form", %{"chat" => %{"question" => question, "mode" => "evidence"}})
    |> render_submit()

    html = render_async(view)
    assert html =~ "&lt;img"
    refute has_element?(view, "#chat-transcript img")
    assert has_element?(view, "#chat-transcript blockquote")

    {:ok, _} = Evidence.revoke_connection(source["connection_id"])
    send(view.pid, :refresh_evaluations)
    refute render(view) =~ "&lt;img"
    refute has_element?(view, "#chat-transcript article")
    assert has_element?(view, "#chat-error", "conversation was cleared")
  end

  test "chat context consent is separate and never automatically added", %{
    view: view,
    source: source
  } do
    view |> element("#nav-connections") |> render_click()
    render_change(view, "model_changed", %{"model" => %{"provider" => "anthropic"}})
    assert has_element?(view, "#model-chat-consent")

    attrs = %{
      "provider" => "anthropic",
      "model" => "fixture-chat-model",
      "credential_env" => "HARNESSFORGE_CHAT_SURFACE_KEY",
      "input_price" => "1",
      "output_price" => "1",
      "source_ids" => [source["id"]],
      "cloud_consent_ack" => "true"
    }

    render_submit(view, "model_configure", %{"model" => attrs})
    assert Models.status()["cloud_consent"]["data_categories"] == ["source_body"]

    render_submit(view, "model_configure", %{
      "model" => Map.put(attrs, "chat_consent_ack", "true")
    })

    assert Models.status()["cloud_consent"]["data_categories"] == ["source_body", "chat_context"]
    assert has_element?(view, "#notice", "No inference was started")
  end

  test "connector sync is explicit and queues only its existing identity", %{
    view: view,
    source: source
  } do
    view |> element("#nav-chat") |> render_click()
    id = source["connection_id"]
    assert has_element?(view, "#chat-sync-#{id}")
    view |> element("#chat-sync-#{id}") |> render_click()
    assert has_element?(view, "#notice", "Selected connector sync queued")

    jobs =
      HarnessForge.Repo.all(Oban.Job)
      |> Enum.filter(&(&1.worker == "HarnessForge.Jobs.Operation" and &1.args["id"] == id))

    assert [%Oban.Job{args: args}] = jobs

    assert Map.keys(args) |> Enum.sort() == ~w(action id workspace_id)
    assert args["action"] == "sync"
    assert args["id"] == id
  end

  test "chat uses the existing login boundary", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/")
  end

  test "Phoenix parameter logging redacts chat questions", _context do
    params = %{"chat" => %{"question" => "CHAT_LOG_CANARY"}, "question" => "CHAT_LOG_CANARY"}
    filtered = Phoenix.Logger.filter_values(params)
    refute inspect(filtered) =~ "CHAT_LOG_CANARY"
    assert filtered["chat"] == "[FILTERED]"
    assert filtered["question"] == "[FILTERED]"
  end

  test "AI answers render citations and clearing cancels an in-flight follow-up", %{
    view: view,
    source: source
  } do
    previous_plug = Application.get_env(:harness_forge, :model_test_plug)
    previous_key = System.get_env("HARNESSFORGE_CHAT_UI_KEY")
    Application.put_env(:harness_forge, :model_test_plug, {Req.Test, __MODULE__})
    System.put_env("HARNESSFORGE_CHAT_UI_KEY", "synthetic-chat-ui-key")

    on_exit(fn ->
      if previous_plug,
        do: Application.put_env(:harness_forge, :model_test_plug, previous_plug),
        else: Application.delete_env(:harness_forge, :model_test_plug)

      if previous_key,
        do: System.put_env("HARNESSFORGE_CHAT_UI_KEY", previous_key),
        else: System.delete_env("HARNESSFORGE_CHAT_UI_KEY")
    end)

    {:ok, _} =
      Models.configure(%{
        "provider" => "openai_responses",
        "endpoint" => "https://api.openai.com/v1",
        "model" => "synthetic-chat-model",
        "credential_env" => "HARNESSFORGE_CHAT_UI_KEY",
        "input_microusd_per_million" => 1_000_000,
        "output_microusd_per_million" => 1_000_000,
        "cloud_consent" => %{
          "provider" => "openai_responses",
          "endpoint" => "https://api.openai.com/v1",
          "source_ids" => [source["id"]],
          "data_categories" => ~w(source_body chat_context)
        }
      })

    Req.Test.allow(__MODULE__, self(), view.pid)
    Req.Test.expect(__MODULE__, &chat_response/1)
    view |> element("#nav-chat") |> render_click()

    view
    |> form("#chat-form", %{
      "chat" => %{"question" => "What tests are required?", "mode" => "model"}
    })
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#chat-transcript", "AI ANSWER")
    assert has_element?(view, "#chat-transcript", "Review the testing guidance.")
    assert has_element?(view, "#chat-transcript blockquote")

    owner = self()

    Req.Test.expect(__MODULE__, fn conn ->
      send(owner, {:follow_up_started, self()})

      receive do
        :release_follow_up -> chat_response(conn)
      after
        5_000 -> raise "The UI did not cancel its pending request"
      end
    end)

    view
    |> form("#chat-form", %{"chat" => %{"question" => "And boundary tests?", "mode" => "model"}})
    |> render_submit()

    assert_receive {:follow_up_started, pending}, 2_000
    assert has_element?(view, "#chat-pending")
    view |> element("#chat-clear") |> render_click()
    send(pending, :release_follow_up)
    render_async(view)
    refute has_element?(view, "#chat-transcript article")
    refute has_element?(view, "#chat-pending")
    Req.Test.verify!(__MODULE__)
  end

  defp chat_response(conn) do
    Req.Test.json(conn, %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{
              "type" => "output_text",
              "text" =>
                Jason.encode!(%{
                  "answer" => "Review the testing guidance.",
                  "citation_ids" => ["E1"]
                })
            }
          ]
        }
      ],
      "usage" => %{"input_tokens" => 100, "output_tokens" => 20}
    })
  end
end
