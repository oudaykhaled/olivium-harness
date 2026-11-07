defmodule HarnessForge.ConnectorBoundariesTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.Connectors.{Common, Registry}
  alias HarnessForge.Contracts.Error

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "GraphQL transport is fixed, read only, JSON encoded and never follows redirects" do
    context = %{"request_options" => [plug: {Req.Test, __MODULE__}]}

    for query <- [
          "mutation Bad { deleteProjectV2(input:{}) { clientMutationId } }",
          "query Good { viewer { login } } mutation Bad { x }",
          "{ viewer { login } }"
        ] do
      assert {:error, %Error{code: "invalid_graphql_operation"}} =
               Common.graphql(query, %{}, [], context)
    end

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "api.github.com"
      assert conn.request_path == "/graphql"
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)

      assert %{
               "query" => "query Selected($id: ID!) { node(id:$id) { id } }",
               "variables" => %{"id" => "PVT_synthetic"}
             } = Jason.decode!(bytes)

      conn
      |> Plug.Conn.put_resp_header("location", "https://evil.invalid")
      |> Plug.Conn.send_resp(302, "secret-provider-body")
    end)

    assert {:error, %Error{code: "redirect_rejected"}} =
             Common.graphql(
               "query Selected($id: ID!) { node(id:$id) { id } }",
               %{"id" => "PVT_synthetic"},
               [],
               context
             )
  end

  test "bounded GraphQL transport rejects oversized responses" do
    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, String.duplicate(" ", 4_194_305))
    end)

    assert {:error, %Error{code: "provider_response_too_large"}} =
             Common.graphql("query Selected { viewer { id } }", %{}, [], %{
               "request_options" => [plug: {Req.Test, __MODULE__}]
             })
  end

  test "second boundary rejects forged source selection for every provider" do
    id = Ecto.UUID.generate()

    docs = [
      {"github", %{"repository" => "synthetic/selected"}, "review:91",
       "https://github.com/synthetic/selected/pull/2#pullrequestreview-91",
       %{"repository" => "synthetic/selected", "kind" => "review", "pull_number" => 2}},
      {"jira", %{"endpoint" => "https://synthetic.atlassian.net", "project" => "DEMO"},
       "issue:123", "https://synthetic.atlassian.net/browse/DEMO-1", %{"project" => "DEMO"}},
      {"github_projects", %{"project_url" => "https://github.com/orgs/synthetic/projects/1"},
       "PVTI_123", "https://github.com/orgs/synthetic/projects/1",
       %{
         "project_url" => "https://github.com/orgs/synthetic/projects/1",
         "project_id" => "PVT_123",
         "owner_kind" => "organization",
         "owner" => "synthetic",
         "number" => 1,
         "kind" => "item"
       }},
      {"slack", %{"team_id" => "T123456", "channel_id" => "C123456"}, "C123456:1761912001.000001",
       "https://synthetic.slack.com/archives/C123456/p1761912001000001",
       %{
         "team_id" => "T123456",
         "team_domain" => "synthetic",
         "channel_id" => "C123456",
         "message_ts" => "1761912001.000001",
         "kind" => "message"
       }},
      {"confluence", %{"endpoint" => "https://synthetic.atlassian.net", "space_id" => "12345"},
       "123", "https://synthetic.atlassian.net/wiki/pages/viewpage.action?pageId=123",
       %{"space_id" => "12345", "page_id" => "123", "kind" => "page"}}
    ]

    for {provider, config, key, url, metadata} <- docs do
      connection = %{provider: provider, id: id, config: config}

      document = %{
        "external_id" => "#{provider}:#{id}:#{key}",
        "source_url" => url,
        "metadata" => metadata
      }

      assert :ok = Registry.document_scope(connection, document)

      for change <- [
            %{"external_id" => "#{provider}:#{Ecto.UUID.generate()}:#{key}"},
            %{"metadata" => %{}},
            %{"source_url" => "https://evil.invalid/"},
            %{"source_url" => url <> "&extra=1"},
            %{"source_url" => String.replace(url, "https://", "https://secret@")}
          ] do
        assert {:error, :scope_violation} =
                 Registry.document_scope(connection, Map.merge(document, change))
      end
    end

    assert {:error, :provider_unavailable} = Registry.adapter("Elixir.Evil")
  end
end
