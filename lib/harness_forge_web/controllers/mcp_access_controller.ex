defmodule HarnessForgeWeb.MCPAccessController do
  use HarnessForgeWeb, :controller
  alias HarnessForge.{Contracts, Workspaces}
  alias HarnessForge.Evidence.Corpora
  alias HarnessForge.MCP.{Clients, DisclosureGrants}
  alias HarnessForge.Privacy.Purge
  alias HarnessForgeWeb.Plugs.OperatorSession

  @scope_keys ~w(corpus_id project_id goal_id goal_hash expected_generation)
  @salt "mcp-owner-disclosure-v1"

  def index(conn, params) do
    owner = caller(conn)
    preview = preview(params, owner)

    reviewed =
      case preview do
        {:ok, value, attrs} ->
          Phoenix.Token.sign(HarnessForgeWeb.Endpoint, @salt, %{
            "attrs" => attrs,
            "scope" => value["scope"],
            "members" => value["members"],
            "profile" => value["profile"],
            "session" => Contracts.digest(get_session(conn, "operator_auth"))
          })

        _ ->
          nil
      end

    with {:ok, %{"clients" => clients}} <- Clients.list(owner),
         {:ok, %{"grants" => grants}} <- DisclosureGrants.list(owner) do
      render(conn, :index,
        page_title: "Connect an assistant",
        clients: clients,
        grants: grants,
        preview: preview,
        selection_labels: selection_labels(preview),
        reviewed: reviewed
      )
    else
      _ -> unavailable(conn)
    end
  end

  def create(conn, %{"reviewed" => token, "name" => name, "synthetic" => "confirmed"}) do
    Purge.synchronize(fn ->
      owner = caller(conn)

      with true <- is_binary(token) and byte_size(token) <= 300_000,
           {:ok, review} <-
             Phoenix.Token.verify(HarnessForgeWeb.Endpoint, @salt, token, max_age: 300),
           true <- review["session"] == Contracts.digest(get_session(conn, "operator_auth")),
           {:ok, result} <-
             Corpora.guard(owner, fn ->
               with {:ok, current} <- DisclosureGrants.preview(review["attrs"], owner),
                    true <-
                      Map.take(current, ~w(scope members profile)) ==
                        Map.take(review, ~w(scope members profile)),
                    {:ok, client} <- Clients.register(%{"name" => name}, owner),
                    attrs =
                      Map.merge(review["attrs"], %{
                        "client_id" => client["client_id"],
                        "members" => review["members"],
                        "profile" => review["profile"],
                        "ttl_seconds" => 1800
                      }),
                    {:ok, grant} <- DisclosureGrants.issue(attrs, owner) do
                 {:ok,
                  %{
                    "url" => HarnessForgeWeb.Endpoint.url() <> "/mcp",
                    "client_id" => client["client_id"],
                    "grant_id" => grant["id"],
                    "expires_at" => grant["expires_at"],
                    "headers" => %{
                      "Authorization" => "Bearer " <> client["credential"],
                      "X-HarnessForge-Disclosure-Grant" => grant["id"]
                    },
                    "profile" => grant["profile"]
                  }}
               else
                 false -> {:error, :stale_disclosure_review}
                 error -> error
               end
             end),
           true <- OperatorSession.valid?(get_session(conn, "operator_auth")) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_download({:binary, Jason.encode!(result, pretty: true)},
          filename: "harnessforge-assistant-access.json",
          content_type: "application/json"
        )
      else
        _ -> unavailable(conn)
      end
    end)
  end

  def create(conn, _), do: unavailable(conn)

  def revoke(conn, %{"kind" => kind, "target_id" => id}) do
    result =
      case kind do
        "client" -> Clients.revoke(id, caller(conn))
        "grant" -> DisclosureGrants.revoke(id, caller(conn))
        _ -> {:error, :invalid_input}
      end

    case result do
      {:ok, _} -> redirect(conn, to: "/mcp/access")
      _ -> unavailable(conn)
    end
  end

  def revoke(conn, _), do: unavailable(conn)

  defp selection_labels({:ok, value, _}) do
    scope = value["scope"]

    with {:ok, project} <-
           HarnessForge.Evidence.Store.get(HarnessForge.Company.Project, scope["project_id"]),
         {:ok, goal} <-
           HarnessForge.Evidence.Store.get(HarnessForge.Evidence.Goal, scope["goal_id"]) do
      %{project: project.payload["name"], goal: goal.title}
    else
      _ -> %{project: scope["project_id"], goal: scope["goal_id"]}
    end
  end

  defp selection_labels(_), do: %{project: nil, goal: nil}

  defp preview(params, _owner) when map_size(params) == 0, do: :none

  defp preview(params, owner) do
    with true <- Enum.sort(Map.keys(params)) == Enum.sort(@scope_keys),
         true <- is_binary(params["expected_generation"]),
         {generation, ""} <- Integer.parse(params["expected_generation"]),
         true <- generation >= 0,
         attrs = Map.put(params, "expected_generation", generation),
         {:ok, value} <- DisclosureGrants.preview(attrs, owner) do
      {:ok, value, attrs}
    else
      _ -> :unavailable
    end
  end

  defp caller(conn) do
    auth = get_session(conn, "operator_auth")
    workspace = Workspaces.current_id()

    [
      authorize: fn -> workspace == Workspaces.current_id() and OperatorSession.valid?(auth) end,
      session_fingerprint: Contracts.digest(auth),
      view_generation: String.slice(Contracts.digest(auth), 0, 32),
      reset_token: 0
    ]
  end

  defp unavailable(conn),
    do:
      conn
      |> put_status(:conflict)
      |> text(
        "Access changed or the reviewed scope expired. Return to source review and try again."
      )
end
