defmodule HarnessForge.AccountsTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Accounts, Audit, Evidence, Privacy, Workspaces}
  alias HarnessForge.Connectors.ServiceAccount
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Evidence.{Connection, Revision, Source}

  @ref "HARNESSFORGE_TEST_SERVICE_TOKEN"
  @username_ref "HARNESSFORGE_TEST_SERVICE_USERNAME"
  @secret "synthetic-service-secret"
  @services ~w(github github_projects slack jira confluence)

  setup do
    Req.Test.verify_on_exit!()
    prior = Map.new([@ref, @username_ref], &{&1, System.get_env(&1)})
    System.put_env(@ref, @secret)
    System.put_env(@username_ref, "synthetic@example.invalid")
    old_plug = Application.get_env(:harness_forge, :account_test_plug)
    Application.put_env(:harness_forge, :account_test_plug, {Req.Test, __MODULE__})

    on_exit(fn ->
      Enum.each(prior, fn {ref, value} ->
        if value, do: System.put_env(ref, value), else: System.delete_env(ref)
      end)

      if old_plug,
        do: Application.put_env(:harness_forge, :account_test_plug, old_plug),
        else: Application.delete_env(:harness_forge, :account_test_plug)
    end)

    :ok
  end

  for service <- @services do
    test "#{service}: verifies credentials before persistence and queries bounded metadata" do
      service = unquote(service)
      stub(service)
      source_count = Repo.aggregate(Source, :count)
      revision_count = Repo.aggregate(Revision, :count)
      assert {:ok, connection} = Accounts.connect(attrs(service))
      assert connection["status"] == "active"
      assert connection["credential_available"]
      assert {:ok, reply} = Accounts.query(operation(service), %{"limit" => 10})
      assert reply["mode"] == "live"
      assert reply["provider"] == service
      assert reply["citations"] == []
      assert length(reply["rows"]) == 1
      assert reply["coverage"]["requested"] == 10
      assert reply["coverage"]["returned"] == 1
      assert Accounts.valid?(reply)
      refute inspect(reply) =~ @secret
      refute inspect(reply) =~ "BODY_MUST_NOT_ESCAPE"
      assert Repo.aggregate(Source, :count) == source_count
      assert Repo.aggregate(Revision, :count) == revision_count
      assert {:ok, catalog} = Accounts.catalog()
      row = Enum.find(catalog, &(&1["service"] == service))
      assert row["state"] == "configured"
      refute row["network_checked"]
      assert [^connection] = row["connections"]
      refute inspect(catalog) =~ @secret
      refute inspect(catalog) =~ @ref
      assert {:ok, events} = Audit.list_events()
      event = Enum.find(events, &(&1["action"] == "connection.created"))
      assert event["details"] == %{"connection_id" => connection["id"]}
    end
  end

  test "strict account input rejects raw credentials arbitrary endpoints and transport overrides" do
    for input <- [
          nil,
          %{},
          %{"service" => "unregistered", "credential_ref" => @ref},
          %{"service" => "github", "credential_ref" => "ghp_rawsecret"},
          Map.put(attrs("github"), "token", @secret),
          Map.put(attrs("github"), "endpoint", "https://evil.invalid"),
          Map.put(attrs("github"), "username_ref", @username_ref),
          Map.put(attrs("jira"), "endpoint", "https://synthetic.atlassian.net/redirect"),
          Map.put(attrs("jira"), "endpoint", "http://synthetic.atlassian.net"),
          Map.put(
            attrs("confluence"),
            "endpoint",
            "https://synthetic.atlassian.net.evil.invalid"
          ),
          Map.put(attrs("slack"), "request_options", %{"url" => "https://evil.invalid"})
        ] do
      assert {:error, %Error{code: "invalid_connector_config"}} = Accounts.connect(input)
    end

    assert {:error, :invalid_account_query} = Accounts.connect(attrs("github"), url: "evil")

    assert {:error, :invalid_account_query} =
             Accounts.connect(attrs("github"), request_options: [url: "evil"])

    assert {:error, :invalid_account_query} = Accounts.connect(attrs("github"), authorize: "true")
    assert Repo.aggregate(Connection, :count) == 0
  end

  test "finite operation and integer page bounds reject arbitrary tools without network" do
    for {op, args} <- [
          {"github.delete", %{}},
          {"https://api.github.com/user", %{}},
          {"github.repositories", %{"limit" => 0}},
          {"github.repositories", %{"limit" => 21}},
          {"github.repositories", %{"limit" => "10"}},
          {"github.repositories", %{"url" => "https://evil.invalid"}},
          {"github.repositories", []}
        ] do
      assert {:error, :invalid_account_query} = Accounts.query(op, args)
    end

    assert {:error, :github_account_not_connected} = Accounts.query("github.repositories")
    assert {:error, :service_account_not_connected} = Accounts.query("slack.channels")
  end

  test "missing credentials cause no account admission and never imply browser authentication" do
    System.delete_env(@ref)
    assert {:error, %Error{code: "credential_unavailable"}} = Accounts.connect(attrs("github"))
    assert {:ok, catalog} = Accounts.catalog()
    assert Enum.all?(catalog, &(&1["state"] == "not_configured"))
    assert Repo.aggregate(Connection, :count) == 0
  end

  test "denied rate-limited and redirected verification never persist authority or leak bodies" do
    for {status, code} <- [
          {401, "source_access_denied"},
          {429, "rate_limited"},
          {302, "redirect_rejected"}
        ] do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, status, @secret <> " provider detail"))
      assert {:error, %Error{code: ^code} = error} = Accounts.connect(attrs("github"))
      refute inspect(error) =~ @secret
    end

    assert Repo.aggregate(Connection, :count) == 0
  end

  test "HTTP 200 Slack and GraphQL permission errors are not successful connections" do
    Req.Test.expect(
      __MODULE__,
      &Req.Test.json(&1, %{"ok" => false, "error" => "missing_scope", "needed" => @secret})
    )

    assert {:error, %Error{code: "source_access_denied"}} = Accounts.connect(attrs("slack"))

    Req.Test.expect(
      __MODULE__,
      &Req.Test.json(&1, %{
        "data" => %{"viewer" => nil},
        "errors" => [%{"type" => "FORBIDDEN", "message" => @secret}]
      })
    )

    assert {:error, %Error{code: "source_access_denied"}} =
             Accounts.connect(attrs("github_projects"))

    assert Repo.aggregate(Connection, :count) == 0
  end

  test "live replies expire after account revocation, credential removal, tampering and workspace change" do
    stub("github")
    assert {:ok, connection} = Accounts.connect(attrs("github"))
    assert {:ok, reply} = Accounts.query("github.repositories")
    refute Accounts.valid?(Map.put(reply, "answer", "forged"))
    refute Accounts.valid?(nil)

    System.delete_env(@ref)
    refute Accounts.valid?(reply)
    assert {:ok, catalog} = Accounts.catalog()
    assert Enum.find(catalog, &(&1["service"] == "github"))["state"] == "credential_missing"
    System.put_env(@ref, @secret)

    previous = Application.fetch_env!(:harness_forge, :workspace_id)

    try do
      Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
      refute Accounts.valid?(reply)
      assert {:error, :github_account_not_connected} = Accounts.query("github.repositories")
    after
      Application.put_env(:harness_forge, :workspace_id, previous)
    end

    assert Accounts.valid?(reply)
    assert {:ok, _} = Accounts.disconnect(connection["id"])
    refute Accounts.valid?(reply)
    assert {:error, :github_account_not_connected} = Accounts.query("github.repositories")
  end

  test "disconnect cannot revoke a selected source connection" do
    assert {:ok, connection} =
             Evidence.connect(%{
               "provider" => "github",
               "name" => "Selected",
               "config" => %{"repository" => "synthetic/repo", "credential_ref" => @ref}
             })

    assert {:error, :service_account_not_connected} = Accounts.disconnect(connection["id"])
    assert Repo.get!(Connection, connection["id"]).status == "active"
  end

  test "a changed remote account identity cannot silently replace the connected owner" do
    stub("github")
    assert {:ok, _} = Accounts.connect(attrs("github"))

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.request_path == "/user",
        do:
          Req.Test.json(conn, %{
            "id" => 20,
            "login" => "other",
            "html_url" => "https://github.com/other"
          }),
        else: Req.Test.json(conn, [])
    end)

    assert {:error, :stale_live_context} = Accounts.query("github.repositories")
  end

  test "authorization is checked before requests and again before account persistence" do
    assert {:error, :authorization_revoked} =
             Accounts.connect(attrs("github"), authorize: fn -> false end)

    assert Repo.aggregate(Connection, :count) == 0

    stub("github")
    key = {__MODULE__, :authorized}
    Process.put(key, true)

    Req.Test.stub(__MODULE__, fn conn ->
      Process.put(key, false)
      Req.Test.json(conn, user())
    end)

    assert {:error, :authorization_revoked} =
             Accounts.connect(attrs("github"), authorize: fn -> Process.get(key) end)

    assert Repo.aggregate(Connection, :count) == 0
  end

  test "service account wrappers cannot synchronize or import source bodies" do
    stub("github")
    assert {:ok, connection} = Accounts.connect(attrs("github"))

    assert {:error, %Error{code: "account_source_import_unsupported"}} =
             Evidence.sync(connection["id"])

    assert {:error, :scope_violation} =
             Evidence.import_markdown(connection["id"], %{
               "external_id" => "anything",
               "title" => "No body",
               "body" => "never import"
             })

    assert Repo.aggregate(Source, :count) == 0

    assert {:error, %Error{code: "invalid_connector_config"}} =
             ServiceAccount.validate_config(%{})
  end

  test "workspace purge removes account authority and invalidates in-memory replies" do
    isolated_workspace(fn ->
      stub("github")
      assert {:ok, _} = Accounts.connect(attrs("github"))
      assert {:ok, reply} = Accounts.query("github.repositories")
      assert {:ok, %{"state" => "completed"}} = Privacy.purge_workspace(Workspaces.current_id())
      refute Accounts.valid?(reply)
      assert {:ok, catalog} = Accounts.catalog()
      assert Enum.all?(catalog, &(&1["state"] == "not_configured"))
    end)
  end

  test "restored quarantine semantics remove configuration authority from old replies" do
    stub("github")
    assert {:ok, account} = Accounts.connect(attrs("github"))
    assert {:ok, reply} = Accounts.query("github.repositories")

    Repo.get!(Connection, account["id"])
    |> Ecto.Changeset.change(
      status: "revoked",
      config: %{},
      sync_state: "restored_requires_revalidation"
    )
    |> Repo.update!()

    refute Accounts.valid?(reply)
    assert {:ok, catalog} = Accounts.catalog()
    assert Enum.all?(catalog, &(&1["state"] == "not_configured"))
  end

  test "each service respects the one and twenty result request bounds" do
    for service <- @services do
      stub(service)
      assert {:ok, _} = Accounts.connect(attrs(service))

      for limit <- [1, 20] do
        assert {:ok, reply} = Accounts.query(operation(service), %{"limit" => limit})
        assert reply["coverage"]["requested"] == limit
        assert Accounts.valid?(reply)
      end
    end
  end

  test "verification admission serializes with a concurrent workspace purge" do
    isolated_workspace(fn ->
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:verification_waiting, self()})

        receive do
          :continue_verification -> Req.Test.json(conn, user())
        after
          5000 -> flunk("verification was not released")
        end
      end)

      connect = Task.async(fn -> Accounts.connect(attrs("github")) end)
      assert_receive {:verification_waiting, verifier}, 2000
      purge = Task.async(fn -> Privacy.purge_workspace(Workspaces.current_id()) end)
      assert Task.yield(purge, 50) == nil
      send(verifier, :continue_verification)
      assert {:ok, _} = Task.await(connect, 5000)
      assert {:ok, %{"state" => "completed"}} = Task.await(purge, 5000)
      assert {:ok, catalog} = Accounts.catalog()
      assert Enum.all?(catalog, &(&1["state"] == "not_configured"))
    end)
  end

  test "malformed metadata identities, cross-workspace channels and URLs fail closed" do
    cases = [
      {"github_projects",
       %{
         "data" => %{
           "viewer" => %{
             "databaseId" => 10,
             "login" => "synthetic",
             "projectsV2" => %{
               "nodes" => [
                 %{
                   "id" => "PVT_1",
                   "number" => %{},
                   "title" => "Invalid",
                   "url" => "https://evil.invalid"
                 }
               ],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         }
       }},
      {"slack",
       %{
         "ok" => true,
         "user_id" => "U123",
         "user" => "synthetic",
         "team_id" => "https://evil.invalid"
       }},
      {"jira", %{"accountId" => "account-123", "active" => false}},
      {"confluence", %{"accountId" => "account-123", "type" => "anonymous"}}
    ]

    for {service, body} <- cases do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, body))
      assert {:error, %Error{}} = Accounts.connect(attrs(service))
    end

    stub("slack")
    assert {:ok, _} = Accounts.connect(attrs("slack"))

    Req.Test.stub(__MODULE__, fn conn ->
      body =
        if conn.request_path == "/api/auth.test",
          do: fixture("slack", conn),
          else: %{
            "ok" => true,
            "channels" => [
              %{
                "id" => "C123",
                "name" => "channel",
                "is_private" => false,
                "context_team_id" => "TOTHER"
              }
            ],
            "response_metadata" => %{"next_cursor" => ""}
          }

      Req.Test.json(conn, body)
    end)

    assert {:error, %Error{code: "scope_violation"}} = Accounts.query("slack.channels")
  end

  defp attrs(service) when service in ~w(jira confluence),
    do: %{
      "service" => service,
      "endpoint" => "https://synthetic.atlassian.net",
      "credential_ref" => @ref,
      "username_ref" => @username_ref
    }

  defp attrs(service), do: %{"service" => service, "credential_ref" => @ref}
  defp operation("github"), do: "github.repositories"
  defp operation("github_projects"), do: "github_projects.boards"
  defp operation("slack"), do: "slack.channels"
  defp operation("jira"), do: "jira.projects"
  defp operation("confluence"), do: "confluence.spaces"

  defp stub(service) do
    Req.Test.stub(__MODULE__, fn conn ->
      expected_host =
        if service in ~w(jira confluence),
          do: "synthetic.atlassian.net",
          else: if(service == "slack", do: "slack.com", else: "api.github.com")

      assert conn.host == expected_host
      assert conn.scheme == :https

      expected_auth =
        if service in ~w(jira confluence),
          do: "Basic " <> Base.encode64("synthetic@example.invalid:" <> @secret),
          else: "Bearer " <> @secret

      assert Plug.Conn.get_req_header(conn, "authorization") == [expected_auth]
      body = fixture(service, conn)
      Req.Test.json(conn, body)
    end)
  end

  defp fixture("github", %{request_path: "/user", method: "GET"}), do: user()

  defp fixture("github", %{request_path: "/user/repos", method: "GET"} = conn) do
    params = Plug.Conn.fetch_query_params(conn).query_params
    assert params["affiliation"] == "owner"
    assert params["sort"] == "updated"
    assert params["per_page"] in ~w(1 10 20)

    [
      %{
        "id" => 30,
        "name" => "repo",
        "full_name" => "synthetic/repo",
        "owner" => %{"id" => 10, "login" => "synthetic"},
        "html_url" => "https://github.com/synthetic/repo",
        "private" => true,
        "stargazers_count" => 2,
        "updated_at" => "2026-10-30T12:00:00Z",
        "description" => "BODY_MUST_NOT_ESCAPE"
      }
    ]
  end

  defp fixture("github_projects", %{request_path: "/graphql", method: "POST"} = conn) do
    {:ok, bytes, _} = Plug.Conn.read_body(conn)
    data = Jason.decode!(bytes)
    assert String.starts_with?(data["query"], "query ")
    refute data["query"] =~ "mutation"
    assert data["variables"]["limit"] in [1, 10, 20]

    %{
      "data" => %{
        "viewer" => %{
          "databaseId" => 10,
          "login" => "synthetic",
          "projectsV2" => %{
            "nodes" => [
              %{
                "id" => "PVT_1",
                "number" => 1,
                "title" => "Board",
                "url" => "https://github.com/users/synthetic/projects/1",
                "updatedAt" => "2026-10-30T12:00:00Z",
                "public" => false,
                "description" => "BODY_MUST_NOT_ESCAPE"
              }
            ],
            "pageInfo" => %{"hasNextPage" => false}
          }
        }
      }
    }
  end

  defp fixture("slack", %{request_path: "/api/auth.test", method: "GET"}),
    do: %{"ok" => true, "user_id" => "U123", "user" => "synthetic", "team_id" => "T123"}

  defp fixture("slack", %{request_path: "/api/conversations.list", method: "GET"} = conn) do
    params = Plug.Conn.fetch_query_params(conn).query_params
    assert params["types"] == "public_channel,private_channel"
    assert params["limit"] in ~w(1 10 20)

    %{
      "ok" => true,
      "channels" => [
        %{
          "id" => "C123",
          "name" => "general",
          "is_private" => false,
          "purpose" => %{"value" => "BODY_MUST_NOT_ESCAPE"}
        }
      ],
      "response_metadata" => %{"next_cursor" => ""}
    }
  end

  defp fixture("jira", %{request_path: "/rest/api/3/myself", method: "GET"}),
    do: %{
      "accountId" => "account-123",
      "active" => true,
      "emailAddress" => "BODY_MUST_NOT_ESCAPE"
    }

  defp fixture("jira", %{request_path: "/rest/api/3/project/search", method: "GET"} = conn) do
    params = Plug.Conn.fetch_query_params(conn).query_params
    assert params["orderBy"] == "key"

    %{
      "isLast" => true,
      "values" => [
        %{
          "id" => "100",
          "key" => "SYN",
          "name" => "Synthetic",
          "description" => "BODY_MUST_NOT_ESCAPE"
        }
      ]
    }
  end

  defp fixture("confluence", %{request_path: "/wiki/rest/api/user/current", method: "GET"}),
    do: %{"accountId" => "account-123", "type" => "known"}

  defp fixture("confluence", %{request_path: "/wiki/api/v2/spaces", method: "GET"}),
    do: %{
      "results" => [
        %{
          "id" => "100",
          "key" => "SYN",
          "name" => "Synthetic",
          "description" => "BODY_MUST_NOT_ESCAPE"
        }
      ],
      "_links" => %{}
    }

  defp user,
    do: %{"id" => 10, "login" => "synthetic", "html_url" => "https://github.com/synthetic"}

  defp isolated_workspace(fun) do
    previous_root = Application.get_env(:harness_forge, :workspace_root)
    previous_id = Workspaces.current_id()
    root = Path.join(File.cwd!(), ".service-account-test-" <> Ecto.UUID.generate())
    Enum.each(~w(artifacts runs tmp), &File.mkdir_p!(Path.join(root, &1)))
    Application.put_env(:harness_forge, :workspace_root, root)
    Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())

    try do
      fun.()
    after
      Application.put_env(:harness_forge, :workspace_root, previous_root)
      Application.put_env(:harness_forge, :workspace_id, previous_id)
      File.rm_rf!(root)
    end
  end
end
