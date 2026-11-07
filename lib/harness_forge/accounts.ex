defmodule HarnessForge.Accounts do
  @moduledoc """
  Explicit live, metadata-only service account access for local conversations.

  Account verification is separate from importing a selected repository, channel,
  project or space. Credentials remain in operator-selected environment variables.
  Queries execute finite compiled operations, never user-supplied URLs or tools.
  """
  alias HarnessForge.{Contracts, Evidence, Privacy, Workspaces}
  alias HarnessForge.Accounts.Provider
  alias HarnessForge.Connectors.{Common, ServiceAccount}

  @services [
    {"github", "GitHub"},
    {"github_projects", "GitHub Projects"},
    {"slack", "Slack"},
    {"jira", "Jira"},
    {"confluence", "Confluence"}
  ]
  @operations %{
    "github.repositories" => "github",
    "github_projects.boards" => "github_projects",
    "slack.channels" => "slack",
    "jira.projects" => "jira",
    "confluence.spaces" => "confluence"
  }

  @spec connect(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def connect(attrs, opts \\ []) do
    HarnessForge.Privacy.Purge.synchronize(fn -> connect_locked(attrs, opts) end)
  end

  defp connect_locked(attrs, opts) do
    epoch = Workspaces.session_epoch()

    with :ok <- Workspaces.ensure_writable(),
         {:ok, context} <- context(opts),
         :ok <- authorize(opts, epoch),
         {:ok, config} <- ServiceAccount.input(attrs),
         {:ok, verified} <- Provider.verify(config, context),
         :ok <- authorize(opts, epoch),
         config =
           Map.merge(config, %{
             "identity" => verified["identity"],
             "last_verified_at" => now()
           }),
         {:ok, config} <- ServiceAccount.validate_config(config),
         {:ok, connection} <-
           Evidence.connect(%{
             "provider" => "service_account",
             "name" => label(config["service"]) <> " · " <> config["identity"]["login"],
             "config" => config
           }) do
      {:ok, connection_row(connection)}
    end
  end

  @spec disconnect(String.t()) :: {:ok, map()} | {:error, term()}
  def disconnect(id) do
    with {:ok, connections} <- account_connections(),
         connection when is_map(connection) <- Enum.find(connections, &(&1["id"] == id)) do
      Evidence.revoke_connection(connection["id"])
    else
      nil -> {:error, :service_account_not_connected}
      error -> error
    end
  end

  @doc "Safe local status; configured means last verified, not a fresh network check."
  @spec catalog() :: {:ok, list(map())} | {:error, term()}
  def catalog do
    with {:ok, connections} <- account_connections() do
      {:ok,
       Enum.map(@services, fn {service, service_label} ->
         rows =
           connections
           |> Enum.filter(&(&1["config"]["service"] == service))
           |> Enum.map(&connection_row/1)

         active = Enum.filter(rows, &(&1["status"] == "active"))

         state =
           cond do
             active == [] -> "not_configured"
             Enum.any?(active, & &1["credential_available"]) -> "configured"
             true -> "credential_missing"
           end

         %{
           "service" => service,
           "label" => service_label,
           "state" => state,
           "connections" => rows,
           "network_checked" => false
         }
       end)}
    end
  end

  @spec query(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(operation, args \\ %{}, opts \\ []) do
    epoch = Workspaces.session_epoch()

    with :ok <- Workspaces.ensure_writable(),
         {:ok, service, limit} <- operation(operation, args),
         {:ok, context} <- context(opts),
         :ok <- authorize(opts, epoch),
         {:ok, connection} <- active_account(service),
         {:ok, result} <- Provider.query(connection["config"], limit, context),
         :ok <- authorize(opts, epoch),
         true <- result["identity"] == connection["config"]["identity"],
         reply = reply(service, result),
         scope = %{
           "workspace_id" => Workspaces.current_id(),
           "session_epoch" => epoch,
           "connection_id" => connection["id"],
           "config_digest" => Contracts.digest(connection["config"])
         },
         sealed = seal(reply, scope),
         true <- valid?(sealed) do
      {:ok, sealed}
    else
      false -> {:error, :stale_live_context}
      error -> error
    end
  end

  @doc "Revalidate live reply scope without another network request."
  @spec valid?(term()) :: boolean()
  def valid?(reply) when is_map(reply) do
    with :ok <- Privacy.ready(),
         scope when is_map(scope) <- reply["_live_scope"],
         true <- scope["workspace_id"] == Workspaces.current_id(),
         true <- scope["session_epoch"] == Workspaces.session_epoch(),
         true <-
           scope["reply_digest"] ==
             Contracts.digest(%{
               "reply" => Map.delete(reply, "_live_scope"),
               "scope" => Map.delete(scope, "reply_digest")
             }),
         {:ok, connections} <- account_connections(),
         connection when is_map(connection) <-
           Enum.find(connections, &(&1["id"] == scope["connection_id"])),
         true <- connection["status"] == "active",
         true <- scope["config_digest"] == Contracts.digest(connection["config"]),
         true <- credentials_available?(connection["config"]) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def valid?(_), do: false

  defp account_connections do
    with :ok <- Privacy.ready(),
         {:ok, connections} <- Evidence.list_connections() do
      {:ok,
       Enum.filter(connections, fn connection ->
         connection["provider"] == "service_account" and
           match?({:ok, _}, ServiceAccount.validate_config(connection["config"]))
       end)}
    end
  end

  defp active_account(service) do
    with {:ok, connections} <- account_connections() do
      active =
        connections
        |> Enum.filter(&(&1["status"] == "active" and &1["config"]["service"] == service))
        |> Enum.sort_by(&{&1["inserted_at"], &1["id"]}, :desc)
        |> List.first()

      if active,
        do: {:ok, active},
        else:
          {:error,
           if(service == "github",
             do: :github_account_not_connected,
             else: :service_account_not_connected
           )}
    end
  end

  defp connection_row(connection) do
    config = connection["config"]

    %{
      "id" => connection["id"],
      "name" => connection["name"],
      "identity" => config["identity"],
      "last_verified_at" => config["last_verified_at"],
      "credential_available" => credentials_available?(config),
      "status" => connection["status"]
    }
  end

  defp credentials_available?(config) do
    refs =
      [config["credential_ref"]] ++
        if(config["username_ref"], do: [config["username_ref"]], else: [])

    Enum.all?(refs, &match?({:ok, _}, Common.credential(&1, true)))
  end

  defp operation(operation, args) do
    service = @operations[operation]
    limit = if is_map(args), do: Map.get(args, "limit", 10)

    if is_binary(service) and Common.keys(args, ["limit"]) and is_integer(limit) and
         limit in 1..20,
       do: {:ok, service, limit},
       else: {:error, :invalid_account_query}
  end

  defp context(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:request_options, :authorize] == [] and
         (not Keyword.has_key?(opts, :authorize) or is_function(opts[:authorize], 0)) do
      request_options = Keyword.get(opts, :request_options, [])

      if Keyword.keyword?(request_options) and Keyword.keys(request_options) -- [:plug] == [] do
        fallback = Application.get_env(:harness_forge, :account_test_plug)

        request_options =
          if fallback,
            do: Keyword.put_new(request_options, :plug, fallback),
            else: request_options

        {:ok, %{"request_options" => request_options}}
      else
        {:error, :invalid_account_query}
      end
    else
      {:error, :invalid_account_query}
    end
  end

  defp context(_), do: {:error, :invalid_account_query}

  defp authorize(opts, epoch) do
    callback = Keyword.get(opts, :authorize, fn -> true end)

    if epoch == Workspaces.session_epoch() and callback.() in [true, :ok],
      do: :ok,
      else: {:error, :authorization_revoked}
  rescue
    _ -> {:error, :authorization_revoked}
  end

  defp reply(service, result) do
    %{
      "mode" => "live",
      "answer" => answer(service, result),
      "rows" => result["rows"],
      "citations" => [],
      "provider" => service,
      "account_login" => result["identity"]["login"],
      "fetched_at" => now(),
      "ordering" => result["ordering"],
      "coverage" => result["coverage"]
    }
  end

  defp answer(service, result) do
    rows = result["rows"]

    intro =
      "Live #{label(service)} metadata for #{result["identity"]["login"]}: #{length(rows)} results, ordered #{result["ordering"]}."

    entries =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {row, index} ->
        title = row["full_name"] || row["title"] || row["name"]
        url = row["html_url"] || row["url"]

        detail =
          if service == "github",
            do: " · updated #{row["updated_at"]} · #{row["stargazers_count"]} stars",
            else: ""

        "#{index}. #{title} — #{url}#{detail}"
      end)

    intro <>
      "\n\n" <>
      entries <>
      "\n\nOne bounded API page; only resources visible to this credential are included. No content was imported and no model was called."
  end

  defp seal(reply, scope) do
    digest = Contracts.digest(%{"reply" => reply, "scope" => scope})
    Map.put(reply, "_live_scope", Map.put(scope, "reply_digest", digest))
  end

  defp label(service), do: @services |> List.keyfind(service, 0) |> elem(1)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
