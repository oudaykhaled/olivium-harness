defmodule HarnessForge.SlackConnectorTest do
  use HarnessForge.DataCase, async: false
  import ExUnit.CaptureLog
  alias HarnessForge.Connectors.Slack
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Evidence
  alias HarnessForge.Evidence.{Connection, Revision, Store}

  @credential "HARNESSFORGE_TEST_SLACK_TOKEN"

  setup do
    Req.Test.verify_on_exit!()
    System.put_env(@credential, "synthetic-slack-secret")
    on_exit(fn -> System.delete_env(@credential) end)
    :ok
  end

  test "adapter emits the frozen document contract using verified workspace metadata" do
    id = Ecto.UUID.generate()
    expect_scope()
    expect_messages("history", [message("1761912001.000001")])

    assert {:ok, %{"items" => [document], "complete" => true}} =
             Slack.fetch_page(config(), nil, %{
               "connection_id" => id,
               "request_options" => [plug: {Req.Test, __MODULE__}]
             })

    assert document["external_id"] == "slack:#{id}:C123456:1761912001.000001"
    assert document["metadata"]["team_domain"] == "synthetic"

    assert document["source_url"] ==
             "https://synthetic.slack.com/archives/C123456/p1761912001000001"
  end

  test "configuration contains one workspace/channel and an environment reference only" do
    assert {:ok, _} = Slack.validate_config(config())

    for changes <- [
          %{"endpoint" => "https://slack.com/"},
          %{"endpoint" => "https://slack.com.evil.invalid"},
          %{"channel_id" => "D123456"},
          %{"channel_id" => "C123/other"},
          %{"team_id" => "../T123"},
          %{"credential_ref" => nil},
          %{"credential_ref" => "xoxp-raw-secret"},
          %{"token" => "raw-secret"}
        ] do
      assert {:error, %Error{code: "invalid_connector_config"}} =
               Slack.validate_config(Map.merge(config(), changes))
    end

    connection = connect()
    assert connection["config"]["credential_ref"] == @credential
    refute inspect(connection) =~ "synthetic-slack-secret"
    assert Slack.capabilities()["page_size"] == 15
    assert Slack.capabilities()["threaded_replies"]
    refute Slack.capabilities()["direct_messages"]
  end

  test "history and replies resume independently and sources remain idempotent" do
    connection = connect()
    parent = Map.put(message("1761912001.000001", "Synthetic parent"), "reply_count", 2)
    expect_scope()
    expect_messages("history", [message("1761912003.000001"), parent], "history-2")
    assert {:ok, %{"imported" => 2, "complete" => false}} = sync(connection)

    expect_scope()

    expect_messages("replies", [parent, reply("1761912002.000001")], "thread-2", fn params ->
      assert params["ts"] == "1761912001.000001"
      refute Map.has_key?(params, "cursor")
    end)

    assert {:ok, %{"imported" => 1, "unchanged" => 1, "complete" => false}} = sync(connection)

    expect_scope()

    expect_messages("replies", [reply("1761912002.000002")], nil, fn params ->
      assert params["cursor"] == "thread-2"
    end)

    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(connection)

    expect_scope()

    expect_messages("history", [message("1761912000.000001")], nil, fn params ->
      assert params["cursor"] == "history-2"
    end)

    assert {:ok, %{"imported" => 1, "complete" => true}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).sync_complete
    assert {:ok, sources} = Evidence.list_sources()
    assert length(sources) == 5
    source = Enum.find(sources, &String.ends_with?(&1["external_id"], "1761912002.000002"))
    assert source["external_id"] == "slack:#{connection["id"]}:C123456:1761912002.000002"
    revision = source["latest_revision"]

    assert revision["source_url"] ==
             "https://synthetic.slack.com/archives/C123456/p1761912002000002"

    assert revision["source_updated_at"] == "2025-10-31T12:00:02.000002Z"
    assert revision["metadata"]["message_ts"] == "1761912002.000002"
    assert revision["metadata"]["thread_ts"] == "1761912001.000001"
    assert revision["metadata"]["team_id"] == "T123456"
    assert revision["metadata"]["channel_id"] == "C123456"
    assert revision["metadata"]["kind"] == "reply"
    assert {:ok, []} = Evidence.approved_claims()

    expect_scope()
    expect_messages("history", [message("1761912003.000001"), parent])
    assert {:ok, %{"imported" => 0, "unchanged" => 2, "complete" => false}} = sync(connection)
    assert Repo.aggregate(Store.scoped(Revision), :count) == 5
  end

  test "each resumed fetch verifies the current credential workspace before reading messages" do
    connection = connect()
    expect_scope()
    expect_messages("history", [message("1761912003.000001")], "history-2")
    assert {:ok, _} = sync(connection)
    cursor = Repo.get!(Connection, connection["id"]).cursor
    System.put_env(@credential, "changed-synthetic-secret")
    expect_team("T999999")
    assert {:error, %Error{code: "scope_violation"}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).cursor == cursor
    assert {:ok, [_]} = Evidence.list_sources()
  end

  test "selected channel validation rejects a different channel, DM and foreign context" do
    for changed <- [
          %{"id" => "C999999"},
          %{"is_im" => true},
          %{"is_mpim" => true},
          %{"context_team_id" => "T999999"}
        ] do
      connection = connect()
      expect_team()
      expect_channel(changed)
      assert {:error, %Error{code: "scope_violation"}} = sync(connection)
    end

    assert {:ok, []} = Evidence.list_sources()
  end

  test "a mismatched channel in one message rejects the complete page" do
    connection = connect()
    expect_scope()
    bad = Map.put(message("1761912001.000001"), "channel", "C999999")
    expect_messages("history", [message("1761912002.000001"), bad])
    assert {:error, %Error{code: "scope_violation"}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).cursor == nil
    assert {:ok, []} = Evidence.list_sources()
  end

  test "a wrong thread cannot be imported using broad credentials" do
    connection = connect()
    expect_scope()
    expect_messages("history", [Map.put(message("1761912001.000001"), "reply_count", 1)])
    assert {:ok, _} = sync(connection)
    cursor = Repo.get!(Connection, connection["id"]).cursor
    expect_scope()

    expect_messages("replies", [
      Map.put(reply("1761912002.000001"), "thread_ts", "1761912000.000001")
    ])

    assert {:error, %Error{code: "scope_violation"}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).cursor == cursor
    assert {:ok, [_]} = Evidence.list_sources()
  end

  test "edited timestamp preserves raw provider value and creates a new revision" do
    connection = connect()
    original = message("1761912001.000001", "Original decision")
    expect_scope()
    expect_messages("history", [original])
    assert {:ok, %{"complete" => true}} = sync(connection)

    expect_scope()

    edited =
      original
      |> Map.put("text", "Edited decision")
      |> Map.put("edited", %{"ts" => "1761912002.123456"})

    expect_messages("history", [edited])
    assert {:ok, %{"imported" => 1, "complete" => true}} = sync(connection)
    assert {:ok, [source]} = Evidence.list_sources()
    assert source["latest_revision"]["source_updated_at"] == "2025-10-31T12:00:02.123456Z"
    assert source["latest_revision"]["metadata"]["edited_ts"] == "1761912002.123456"
    assert Repo.aggregate(Store.scoped(Revision), :count) == 2
  end

  test "HTTP 200 invalid_auth revokes a connection without exposing the response" do
    connection = connect()

    Req.Test.expect(
      __MODULE__,
      &Req.Test.json(&1, %{
        "ok" => false,
        "error" => "invalid_auth",
        "private" => "raw-provider-secret"
      })
    )

    assert {:error, %Error{code: "source_access_denied"} = error} = sync(connection)
    refute inspect(error) =~ "raw-provider-secret"
    assert Repo.get!(Connection, connection["id"]).status == "revoked"
    assert {:error, :connection_revoked} = sync(connection)
  end

  test "Slack permission revocation immediately removes approved citation eligibility" do
    connection = connect()
    expect_scope()
    expect_messages("history", [message("1761912001.000001", "Synthetic decision evidence")])
    assert {:ok, _} = sync(connection)
    assert {:ok, [source]} = Evidence.list_sources()
    assert {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, 9)

    assert {:ok, claim} =
             Evidence.create_claim(%{"text" => "Synthetic claim", "citations" => [citation]})

    assert {:ok, _} =
             HarnessForge.Decisions.decide(claim["id"], %{
               "actor" => "synthetic",
               "decision" => "approve",
               "expected_revision_hash" => claim["revision_hash"]
             })

    assert {:ok, [_]} = Evidence.approved_claims()

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"ok" => false, "error" => "token_revoked"}))
    assert {:error, %Error{code: "source_access_denied"}} = sync(connection)
    assert {:ok, []} = Evidence.approved_claims()
    assert {:ok, []} = Evidence.search("Synthetic")
    assert {:ok, %{"latest_revision" => nil}} = Evidence.get_source(source["id"])
  end

  test "HTTP 200 missing_scope is denial while unexpected provider errors stay sanitized" do
    for {provider_error, expected} <- [
          {"missing_scope", "source_access_denied"},
          {"unknown-sensitive-provider-error", "provider_request_rejected"}
        ] do
      connection = connect()
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"ok" => false, "error" => provider_error}))
      assert {:error, %Error{code: ^expected} = error} = sync(connection)
      refute inspect(error) =~ provider_error
    end
  end

  test "rate limits preserve cursor and never retry or sleep" do
    for status <- [429, 200] do
      connection = connect()

      Req.Test.expect(__MODULE__, fn conn ->
        conn = Plug.Conn.put_resp_header(conn, "retry-after", "120")

        if status == 200,
          do: Req.Test.json(conn, %{"ok" => false, "error" => "ratelimited"}),
          else: Plug.Conn.send_resp(conn, 429, "raw-provider-secret")
      end)

      assert {:error,
              %Error{code: "rate_limited", retryable: true, details: ["retry_after_seconds:120"]}} =
               sync(connection)

      stored = Repo.get!(Connection, connection["id"])
      assert stored.status == "active"
      assert stored.sync_state == "rate_limited"
      assert stored.cursor == nil
    end
  end

  test "missing secret prevents all network calls" do
    connection = connect()
    System.delete_env(@credential)
    assert {:error, %Error{code: "credential_unavailable"}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).sync_state == "credential_unavailable"
  end

  test "credential, raw response and exception details are absent from logs and errors" do
    connection = connect()
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 500, "raw-provider-secret"))

    logs =
      capture_log(fn ->
        assert {:error, %Error{code: "provider_unavailable"} = error} = sync(connection)
        refute inspect(error) =~ "raw-provider-secret"
        refute inspect(error) =~ "synthetic-slack-secret"
      end)

    refute logs =~ "raw-provider-secret"
    refute logs =~ "synthetic-slack-secret"
  end

  test "repeated and malformed cursors never advance or commit messages" do
    connection = connect()
    expect_scope()
    expect_messages("history", [message("1761912003.000001")], "same-cursor")
    assert {:ok, _} = sync(connection)
    before = Repo.get!(Connection, connection["id"]).cursor

    for token <- ["same-cursor", "https://evil.invalid/steal", 99] do
      expect_scope()
      expect_messages("history", [message("1761912002.000001")], token)
      assert {:error, %Error{}} = sync(connection)
      assert Repo.get!(Connection, connection["id"]).cursor == before
    end

    assert {:ok, [_]} = Evidence.list_sources()
  end

  test "cursor scope tampering is rejected before issuing a request" do
    connection = connect()
    expect_scope()
    expect_messages("history", [message("1761912003.000001")], "next")
    assert {:ok, _} = sync(connection)
    stored = Repo.get!(Connection, connection["id"])

    cursor =
      stored.cursor |> Jason.decode!() |> Map.put("channel_id", "C999999") |> Jason.encode!()

    stored |> Ecto.Changeset.change(cursor: cursor) |> Repo.update!()
    assert {:error, %Error{code: "invalid_cursor"}} = sync(connection)
  end

  test "limited retention and has_more without a cursor never claim complete history" do
    for fields <- [
          %{"is_limited" => true},
          %{"has_more" => true},
          %{"has_more" => false, "response_metadata" => nil}
        ] do
      connection = connect()
      expect_scope()

      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(
          &1,
          Map.merge(
            %{"ok" => true, "messages" => [message("1761912003.000001")], "has_more" => false},
            fields
          )
        )
      )

      assert {:error, %Error{}} = sync(connection)
      assert Repo.get!(Connection, connection["id"]).cursor == nil
      refute Repo.get!(Connection, connection["id"]).sync_complete
    end

    assert {:ok, []} = Evidence.list_sources()
  end

  test "oversized text causes atomic rollback of the whole page and index" do
    connection = connect()
    expect_scope()

    expect_messages("history", [
      message("1761912002.000001", "Searchable synthetic decision"),
      message("1761912001.000001", String.duplicate("x", 1_048_577))
    ])

    assert {:error, :file_too_large} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).cursor == nil
    assert {:ok, []} = Evidence.list_sources()
    assert {:ok, []} = Evidence.search("Searchable")
    assert Repo.aggregate(Store.scoped(Revision), :count) == 0
  end

  test "non-progressing page timestamps fail safely" do
    connection = connect()
    expect_scope()
    expect_messages("history", [message("1761912003.000001")], "next")
    assert {:ok, _} = sync(connection)
    before = Repo.get!(Connection, connection["id"]).cursor
    expect_scope()
    expect_messages("history", [message("1761912003.000001")])
    assert {:error, %Error{code: "invalid_provider_response"}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).cursor == before
  end

  defp config,
    do: %{
      "endpoint" => "https://slack.com",
      "team_id" => "T123456",
      "channel_id" => "C123456",
      "credential_ref" => @credential
    }

  defp connect do
    {:ok, connection} =
      Evidence.connect(%{
        "provider" => "slack",
        "name" => "Synthetic selected Slack channel",
        "config" => config()
      })

    connection
  end

  defp sync(connection), do: Evidence.sync(connection["id"], plug: {Req.Test, __MODULE__})

  defp expect_scope do
    expect_team()
    expect_channel()
  end

  defp expect_team(team \\ "T123456") do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.host == "slack.com"
      assert conn.request_path == "/api/team.info"
      assert Plug.Conn.fetch_query_params(conn).query_params == %{}

      assert Plug.Conn.get_req_header(conn, "authorization") in [
               ["Bearer synthetic-slack-secret"],
               ["Bearer changed-synthetic-secret"]
             ]

      Req.Test.json(conn, %{"ok" => true, "team" => %{"id" => team, "domain" => "synthetic"}})
    end)
  end

  defp expect_channel(changes \\ %{}) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/conversations.info"
      assert Plug.Conn.fetch_query_params(conn).query_params["channel"] == "C123456"

      channel =
        Map.merge(
          %{
            "id" => "C123456",
            "is_channel" => true,
            "is_im" => false,
            "is_mpim" => false,
            "context_team_id" => "T123456"
          },
          changes
        )

      Req.Test.json(conn, %{"ok" => true, "channel" => channel})
    end)
  end

  defp expect_messages(kind, messages, next \\ nil, check \\ fn _ -> :ok end) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/conversations." <> kind
      params = Plug.Conn.fetch_query_params(conn).query_params
      assert params["channel"] == "C123456"
      assert params["limit"] == "15"
      check.(params)

      Req.Test.json(conn, %{
        "ok" => true,
        "messages" => messages,
        "has_more" => not is_nil(next),
        "response_metadata" => %{"next_cursor" => next || ""}
      })
    end)
  end

  defp message(ts, text \\ "Synthetic message"),
    do: %{"type" => "message", "ts" => ts, "text" => text}

  defp reply(ts), do: Map.put(message(ts, "Synthetic reply"), "thread_ts", "1761912001.000001")
end
