defmodule HarnessForge.ConnectorsTest do
  use HarnessForge.DataCase, async: false
  import ExUnit.CaptureLog
  alias HarnessForge.{Evidence, Decisions}
  alias HarnessForge.Evidence.{Connection, Revision}
  alias HarnessForge.Connectors.{GitHub, Jira}
  alias HarnessForge.Contracts.Error

  setup do
    Req.Test.verify_on_exit!()

    for name <-
          ~w(HARNESSFORGE_TEST_JIRA_TOKEN HARNESSFORGE_TEST_JIRA_EMAIL HARNESSFORGE_TEST_GITHUB_TOKEN),
        do: System.delete_env(name)

    System.put_env("HARNESSFORGE_TEST_JIRA_TOKEN", "synthetic-jira-secret")
    System.put_env("HARNESSFORGE_TEST_JIRA_EMAIL", "synthetic@example.invalid")

    on_exit(fn ->
      for name <-
            ~w(HARNESSFORGE_TEST_JIRA_TOKEN HARNESSFORGE_TEST_JIRA_EMAIL HARNESSFORGE_TEST_GITHUB_TOKEN),
          do: System.delete_env(name)
    end)

    :ok
  end

  test "configuration selects one origin/scope and persists only credential references" do
    assert {:ok, _} = GitHub.validate_config(github_config())
    assert {:ok, _} = Jira.validate_config(jira_config())

    for change <- [
          %{"endpoint" => "https://api.github.com@evil.invalid"},
          %{"repository" => "a/b/other"},
          %{"token" => "raw-secret"},
          %{"credential_ref" => "ghp_secret-value"}
        ] do
      assert {:error, %Error{code: "invalid_connector_config"}} =
               GitHub.validate_config(Map.merge(github_config(), change))
    end

    for change <- [
          %{"endpoint" => "https://tenant.atlassian.net/"},
          %{"endpoint" => "https://localhost"},
          %{"endpoint" => "https://tenant.atlassian.net.evil.invalid"},
          %{"project" => "DEMO OR project=ALL"},
          %{"password" => "raw-secret"}
        ] do
      assert {:error, %Error{code: "invalid_connector_config"}} =
               Jira.validate_config(Map.merge(jira_config(), change))
    end

    connection = connect("jira")
    assert connection["config"]["credential_ref"] == "HARNESSFORGE_TEST_JIRA_TOKEN"
    refute inspect(connection) =~ "synthetic-jira-secret"
  end

  test "GitHub stages repo issues/PRs and paginated reviews with source provenance" do
    connection = connect("github")
    expect_repo()
    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.method == "GET"
      assert conn.request_path == "/repos/synthetic/selected/issues"
      assert conn.query_params["state"] == "all"
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      Req.Test.json(conn, [github_issue(1), github_issue(2, true)])
    end)

    assert {:ok, %{"imported" => 2, "complete" => false}} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/synthetic/selected/pulls/2/reviews"

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.com/repos/synthetic/selected/pulls/2/reviews?per_page=30&page=2>; rel="next")
      )
      |> Req.Test.json([github_review(6_135_059_991)])
    end)

    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.fetch_query_params(conn).query_params["page"] == "2"
      Req.Test.json(conn, [github_review(6_135_059_992)])
    end)

    assert {:ok, %{"imported" => 1, "complete" => true}} = sync(connection)
    assert {:ok, sources} = Evidence.list_sources()
    assert length(sources) == 5
    issue = Enum.find(sources, &(&1["title"] == "Synthetic issue 1"))
    revision = issue["latest_revision"]
    assert revision["source_url"] == "https://github.com/synthetic/selected/issues/1"
    assert revision["source_updated_at"] == "2026-10-30T12:00:00Z"
    assert revision["metadata"]["repository"] == "synthetic/selected"
    assert String.starts_with?(issue["external_id"], "github:#{connection["id"]}:")
    assert Repo.get!(Connection, connection["id"]).sync_complete

    expect_repo()
    assert {:ok, %{"unchanged" => 1}} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.fetch_query_params(conn).query_params["since"]
      Req.Test.json(conn, [github_issue(1)])
    end)

    assert {:ok, %{"unchanged" => 1, "complete" => true}} = sync(connection)
    assert Repo.aggregate(HarnessForge.Evidence.Store.scoped(Revision), :count) == 5
  end

  test "GitHub issue links advance only within selected scope" do
    connection = connect("github")
    expect_repo()
    assert {:ok, _} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.com/repos/synthetic/selected/issues?state=all&sort=updated&direction=asc&per_page=30&page=2>; rel="next")
      )
      |> Req.Test.json([github_issue(1)])
    end)

    assert {:ok, %{"complete" => false}} = sync(connection)
    assert Jason.decode!(Repo.get!(Connection, connection["id"]).cursor)["page"] == 2

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.fetch_query_params(conn).query_params["page"] == "2"
      Req.Test.json(conn, [github_issue(2)])
    end)

    assert {:ok, %{"complete" => true}} = sync(connection)
  end

  test "numeric GitHub links preserve opaque cursors through review pages and resume selected URLs" do
    connection = connect("github")
    expect_repo()
    assert {:ok, _} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.com/repositories/1234714/issues?state=all&sort=updated&direction=asc&per_page=30&page=2&after=c3ludGhldGljK2N1cnNvcg%3D%3D>; rel="next")
      )
      |> Req.Test.json([github_issue(2, true)])
    end)

    assert {:ok, %{"complete" => false, "imported" => 1}} = sync(connection)
    state = Jason.decode!(Repo.get!(Connection, connection["id"]).cursor)
    assert state["continuation"]["repository_id"] == 1_234_714
    assert state["continuation"]["after"] == "c3ludGhldGljK2N1cnNvcg=="
    assert state["continuation"]["page"] == 2

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/synthetic/selected/pulls/2/reviews"
      Req.Test.json(conn, [github_review(6_135_059_991)])
    end)

    assert {:ok, %{"complete" => false, "imported" => 1}} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/repos/synthetic/selected/issues"
      assert conn.query_params["page"] == "2"
      assert conn.query_params["after"] == "c3ludGhldGljK2N1cnNvcg=="

      assert Map.keys(conn.query_params) |> Enum.sort() ==
               ~w(after direction page per_page sort state)

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.com/repositories/1234714/issues?state=all&sort=updated&direction=asc&per_page=30&page=3&after=c2Vjb25kLWN1cnNvcg%3D%3D>; rel="next")
      )
      |> Req.Test.json([github_issue(3)])
    end)

    assert {:ok, %{"complete" => false, "imported" => 1}} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/repos/synthetic/selected/issues"
      assert conn.query_params["page"] == "3"
      assert conn.query_params["after"] == "c2Vjb25kLWN1cnNvcg=="
      Req.Test.json(conn, [])
    end)

    assert {:ok, %{"complete" => true}} = sync(connection)
    assert Jason.decode!(Repo.get!(Connection, connection["id"]).cursor)["stage"] == "repository"
  end

  test "legacy issue cursors reverify repository ID without restarting their scan" do
    connection = connect("github")
    expect_repo()
    assert {:ok, _} = sync(connection)
    original = Repo.get!(Connection, connection["id"])

    legacy =
      original.cursor
      |> Jason.decode!()
      |> Map.delete("repository_id")
      |> Map.merge(%{"page" => 4, "since" => "2026-01-01T00:00:00Z"})

    original |> Ecto.Changeset.change(cursor: Jason.encode!(legacy)) |> Repo.update!()
    expect_repo()

    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/repos/synthetic/selected/issues"
      assert conn.query_params["page"] == "4"
      assert conn.query_params["since"] == "2026-01-01T00:00:00Z"

      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.com/repositories/1234714/issues?state=all&sort=updated&direction=asc&per_page=30&page=5&since=2026-01-01T00%3A00%3A00Z&after=bGVnYWN5>; rel="next")
      )
      |> Req.Test.json([github_issue(4)])
    end)

    assert {:ok, %{"complete" => false, "imported" => 1}} = sync(connection)
    resumed = Jason.decode!(Repo.get!(Connection, connection["id"]).cursor)
    assert resumed["page"] == 5
    assert resumed["repository_id"] == 1_234_714
    assert resumed["since"] == legacy["since"]
    assert resumed["scan_started"] == legacy["scan_started"]
  end

  test "GitHub rejects unsafe numeric pagination links atomically" do
    connection = connect("github")
    expect_repo()
    assert {:ok, _} = sync(connection)
    cursor = Repo.get!(Connection, connection["id"]).cursor
    query = "state=all&sort=updated&direction=asc&per_page=30&page=2&after=c3ludGhldGlj"
    url = "https://api.github.com/repositories/1234714/issues?" <> query

    for target <- [
          String.replace(url, "/1234714/", "/9999999/"),
          String.replace(url, "api.github.com", "evil.invalid"),
          String.replace(url, "https://", "http://"),
          String.replace(url, "api.github.com", "api.github.com:8443"),
          String.replace(url, "api.github.com", "name@api.github.com"),
          String.replace(url, "/issues?", "/pulls?"),
          String.replace(url, "page=2", "page=1"),
          String.replace(url, "page=2", "page=2&page=1"),
          String.replace(url, "per_page=30", "per_page=100"),
          String.replace(url, "after=c3ludGhldGlj", "after=%0Asecret"),
          String.replace(url, "after=c3ludGhldGlj", "after="),
          url <> "&unknown=true",
          url <> "#fragment",
          url <> String.duplicate("x", 2_049)
        ] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("link", "<#{target}>; rel=\"next\"")
        |> Req.Test.json([github_issue(1)])
      end)

      assert {:error, %Error{code: "scope_violation"}} = sync(connection)
      assert Repo.get!(Connection, connection["id"]).cursor == cursor
      assert {:ok, [_]} = Evidence.list_sources()
    end
  end

  test "GitHub rejects repeated, dropped or multiple next cursors" do
    connection = connect("github")
    expect_repo()
    assert {:ok, _} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://api.github.com/repositories/1234714/issues?state=all&sort=updated&direction=asc&per_page=30&page=2&after=c3ludGhldGlj>; rel="next")
      )
      |> Req.Test.json([github_issue(1)])
    end)

    assert {:ok, _} = sync(connection)
    cursor = Repo.get!(Connection, connection["id"]).cursor

    url =
      "https://api.github.com/repositories/1234714/issues?state=all&sort=updated&direction=asc&per_page=30&page=3"

    target = "<#{url}&after=c3ludGhldGlj>; rel=\"next\""

    for link <- [target, "<#{url}>; rel=\"next\"", target <> "," <> target, "bad; rel=\"next\""] do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_header("link", link) |> Req.Test.json([github_issue(2)])
      end)

      assert {:error, %Error{code: "scope_violation"}} = sync(connection)
      assert Repo.get!(Connection, connection["id"]).cursor == cursor
      assert {:ok, sources} = Evidence.list_sources()
      assert length(sources) == 2
    end
  end

  test "a broad token cannot import a response or pagination link outside the repository" do
    System.put_env("HARNESSFORGE_TEST_GITHUB_TOKEN", "synthetic-github-secret")
    connection = connect("github", %{"credential_ref" => "HARNESSFORGE_TEST_GITHUB_TOKEN"})
    expect_repo()
    assert {:ok, _} = sync(connection)
    cursor = Repo.get!(Connection, connection["id"]).cursor

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-github-secret"]

      bad =
        Map.put(github_issue(1), "url", "https://api.github.com/repos/synthetic/outside/issues/1")

      Req.Test.json(conn, [bad])
    end)

    assert {:error, %Error{code: "scope_violation"}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).cursor == cursor
    assert {:ok, [_]} = Evidence.list_sources()

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "link",
        ~s(<https://evil.invalid/collect?per_page=30&page=2>; rel="next")
      )
      |> Req.Test.json([github_issue(1)])
    end)

    assert {:error, %Error{code: "scope_violation"}} = sync(connection)
    assert {:ok, [_]} = Evidence.list_sources()
  end

  test "rate limit surfaces retry-after, preserves cursor and makes one request" do
    connection = connect("github")

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "120")
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
      |> Plug.Conn.send_resp(403, "sensitive provider payload")
    end)

    assert {:error,
            %Error{code: "rate_limited", retryable: true, details: ["retry_after_seconds:120"]} =
              error} = sync(connection)

    refute inspect(error) =~ "sensitive"
    stored = Repo.get!(Connection, connection["id"])
    assert stored.cursor == nil
    assert stored.status == "active"
    assert stored.sync_state == "rate_limited"
    refute stored.sync_complete
  end

  test "permission denial revokes retrieval and approved citation eligibility" do
    connection = connect("github")
    expect_repo()
    assert {:ok, _} = sync(connection)
    {:ok, [source]} = Evidence.list_sources()
    {:ok, citation} = Evidence.citation(source["latest_revision"]["id"], 0, 9)

    {:ok, claim} =
      Evidence.create_claim(%{"text" => "Synthetic claim", "citations" => [citation]})

    assert {:ok, _} =
             Decisions.decide(claim["id"], %{
               "actor" => "synthetic",
               "decision" => "approve",
               "expected_revision_hash" => claim["revision_hash"]
             })

    assert {:ok, [_]} = Evidence.approved_claims()
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 403, "forbidden"))
    assert {:error, %Error{code: "source_access_denied"}} = sync(connection)
    assert {:ok, []} = Evidence.search("Synthetic")
    assert {:ok, []} = Evidence.approved_claims()
    assert {:ok, %{"latest_revision" => nil}} = Evidence.get_source(source["id"])
    assert {:ok, [%{"latest_revision" => nil}]} = Evidence.list_sources()
    assert {:error, :connection_revoked} = sync(connection)
  end

  test "redirects and not found never follow an alternate origin" do
    for {status, code} <- [{302, "redirect_rejected"}, {404, "source_access_denied"}] do
      connection = connect("github")

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.invalid/steal")
        |> Plug.Conn.send_resp(status, "raw")
      end)

      assert {:error, %Error{code: ^code}} = sync(connection)
    end
  end

  test "missing credentials are explicitly unavailable and cannot dispatch a request" do
    connection = connect("github", %{"credential_ref" => "HARNESSFORGE_TEST_GITHUB_TOKEN"})
    assert {:error, %Error{code: "credential_unavailable"}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).sync_state == "credential_unavailable"
    System.delete_env("HARNESSFORGE_TEST_JIRA_TOKEN")
    assert {:error, %Error{code: "credential_unavailable"}} = sync(connect("jira"))
  end

  test "Jira issue/changelog pages use fixed project JQL and preserve exact timestamps" do
    connection = connect("jira")

    Req.Test.expect(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/rest/api/3/search/jql"
      assert conn.query_params["jql"] == ~s(project = "DEMO" ORDER BY key ASC)

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("synthetic@example.invalid:synthetic-jira-secret")
             ]

      Req.Test.json(conn, %{
        "isLast" => false,
        "nextPageToken" => "second",
        "issues" => [jira_issue()]
      })
    end)

    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/rest/api/3/issue/DEMO-1/changelog"

      Req.Test.json(conn, %{
        "startAt" => 0,
        "total" => 2,
        "isLast" => false,
        "values" => [jira_history("501")]
      })
    end)

    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(connection)
    cursor = Repo.get!(Connection, connection["id"]).cursor
    assert Jason.decode!(cursor)["offset"] == 1

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.fetch_query_params(conn).query_params["startAt"] == "1"

      Req.Test.json(conn, %{
        "startAt" => 1,
        "total" => 2,
        "isLast" => true,
        "values" => [jira_history("502")]
      })
    end)

    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      assert Plug.Conn.fetch_query_params(conn).query_params["nextPageToken"] == "second"
      Req.Test.json(conn, %{"isLast" => true, "issues" => []})
    end)

    assert {:ok, %{"complete" => true}} = sync(connection)
    assert {:ok, sources} = Evidence.list_sources()
    assert length(sources) == 3

    assert Enum.any?(
             sources,
             &(&1["latest_revision"]["source_updated_at"] == "2026-10-30T12:00:00.000+0000")
           )

    source = Enum.find(sources, &(&1["title"] == "DEMO-1: Synthetic issue"))
    assert source["latest_revision"]["body"] =~ "Explicit approvals"
    assert source["latest_revision"]["metadata"]["changelog"] == "separate_paginated_sources"
  end

  test "Jira missing changelog page never advances a cursor or claims complete history" do
    connection = connect("jira")
    expect_jira_issue()
    assert {:ok, _} = sync(connection)
    cursor = Repo.get!(Connection, connection["id"]).cursor

    Req.Test.expect(
      __MODULE__,
      &Req.Test.json(&1, %{"startAt" => 0, "total" => 2, "isLast" => false, "values" => []})
    )

    assert {:error, %Error{code: "incomplete_history"}} = sync(connection)
    stored = Repo.get!(Connection, connection["id"])
    assert stored.cursor == cursor
    refute stored.sync_complete
    assert stored.sync_state == "incomplete_history"
    assert {:ok, [_]} = Evidence.list_sources()

    Req.Test.expect(
      __MODULE__,
      &Req.Test.json(&1, %{
        "startAt" => 0,
        "total" => 1,
        "isLast" => true,
        "values" => [jira_history("501")]
      })
    )

    assert {:ok, %{"complete" => true, "imported" => 1}} = sync(connection)
  end

  test "Jira response project must match selection even when credentials are broad" do
    connection = connect("jira")

    Req.Test.expect(__MODULE__, fn conn ->
      bad = put_in(jira_issue(), ["fields", "project", "key"], "OTHER")
      Req.Test.json(conn, %{"isLast" => true, "issues" => [bad]})
    end)

    assert {:error, %Error{code: "scope_violation"}} = sync(connection)
    assert {:ok, []} = Evidence.list_sources()
  end

  test "a partially invalid page commits neither revisions, index nor cursor" do
    connection = connect("github")
    expect_repo()
    assert {:ok, _} = sync(connection)
    cursor = Repo.get!(Connection, connection["id"]).cursor

    Req.Test.expect(__MODULE__, fn conn ->
      bad = Map.put(github_issue(2), "body", String.duplicate("x", 1_048_577))
      Req.Test.json(conn, [github_issue(1), bad])
    end)

    assert {:error, :file_too_large} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).cursor == cursor
    assert {:ok, [_]} = Evidence.list_sources()
    assert {:ok, []} = Evidence.search("decision")
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, [github_issue(1)]))
    assert {:ok, %{"imported" => 1, "complete" => true}} = sync(connection)
    assert {:ok, [_]} = Evidence.search("decision")
  end

  test "cursor replay is deduplicated and source identities include connection" do
    first = connect("github")
    second = connect("github")
    expect_repo()
    assert {:ok, _} = sync(first)
    expect_repo()
    assert {:ok, _} = sync(second)
    original_cursor = Repo.get!(Connection, first["id"]).cursor
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, [github_issue(1)]))
    assert {:ok, %{"imported" => 1}} = sync(first)

    Repo.get!(Connection, first["id"])
    |> Ecto.Changeset.change(cursor: original_cursor)
    |> Repo.update!()

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, [github_issue(1)]))
    assert {:ok, %{"unchanged" => 1, "imported" => 0}} = sync(first)
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, [github_issue(1)]))
    assert {:ok, %{"imported" => 1}} = sync(second)
    assert Repo.aggregate(HarnessForge.Evidence.Store.scoped(Revision), :count) == 4
  end

  test "raw provider errors and credentials are absent from return values and logs" do
    System.put_env("HARNESSFORGE_TEST_GITHUB_TOKEN", "synthetic-github-secret")
    connection = connect("github", %{"credential_ref" => "HARNESSFORGE_TEST_GITHUB_TOKEN"})
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 500, "raw-provider-secret"))

    logs =
      capture_log(fn ->
        assert {:error, %Error{code: "provider_unavailable"} = error} = sync(connection)
        refute inspect(error) =~ "raw-provider-secret"
        refute inspect(error) =~ "synthetic-github-secret"
      end)

    refute logs =~ "raw-provider-secret"
    refute logs =~ "synthetic-github-secret"
  end

  defp sync(connection), do: Evidence.sync(connection["id"], plug: {Req.Test, __MODULE__})

  defp connect(provider, change \\ %{}) do
    config = if provider == "github", do: github_config(), else: jira_config()

    {:ok, connection} =
      Evidence.connect(%{
        "provider" => provider,
        "name" => "Synthetic selected source",
        "config" => Map.merge(config, change)
      })

    connection
  end

  defp github_config,
    do: %{"endpoint" => "https://api.github.com", "repository" => "synthetic/selected"}

  defp jira_config,
    do: %{
      "endpoint" => "https://synthetic.atlassian.net",
      "project" => "DEMO",
      "credential_ref" => "HARNESSFORGE_TEST_JIRA_TOKEN",
      "username_ref" => "HARNESSFORGE_TEST_JIRA_EMAIL"
    }

  defp expect_repo do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/repos/synthetic/selected"

      Req.Test.json(conn, %{
        "id" => 1_234_714,
        "full_name" => "synthetic/selected",
        "html_url" => "https://github.com/synthetic/selected",
        "description" => "Synthetic repository",
        "updated_at" => "2026-10-30T12:00:00Z"
      })
    end)
  end

  defp github_issue(n, pull \\ false) do
    issue = %{
      "id" => n + 6_135_059_989,
      "number" => n,
      "title" => "Synthetic issue #{n}",
      "body" => "Explicit decision evidence",
      "state" => "closed",
      "url" => "https://api.github.com/repos/synthetic/selected/issues/#{n}",
      "html_url" =>
        "https://github.com/synthetic/selected/#{if pull, do: "pull", else: "issues"}/#{n}",
      "updated_at" => "2026-10-30T12:00:00Z"
    }

    if pull, do: Map.put(issue, "pull_request", %{}), else: issue
  end

  defp github_review(id),
    do: %{
      "id" => id,
      "html_url" => "https://github.com/synthetic/selected/pull/2#pullrequestreview-#{id}",
      "state" => "APPROVED",
      "body" => "Synthetic approval evidence",
      "submitted_at" => "2026-10-30T12:00:00Z"
    }

  defp expect_jira_issue,
    do:
      Req.Test.expect(
        __MODULE__,
        &Req.Test.json(&1, %{"isLast" => true, "issues" => [jira_issue()]})
      )

  defp jira_issue,
    do: %{
      "id" => "10001",
      "key" => "DEMO-1",
      "self" => "https://synthetic.atlassian.net/rest/api/3/issue/10001",
      "fields" => %{
        "project" => %{"key" => "DEMO"},
        "summary" => "Synthetic issue",
        "updated" => "2026-10-30T12:00:00.000+0000",
        "description" => %{
          "type" => "doc",
          "version" => 1,
          "content" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "text" => "Explicit approvals"}]
            }
          ]
        }
      }
    }

  defp jira_history(id),
    do: %{
      "id" => id,
      "created" => "2026-10-30T12:00:00.000+0000",
      "items" => [%{"field" => "status", "fromString" => "Open", "toString" => "Done"}]
    }
end
