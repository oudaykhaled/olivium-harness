defmodule HarnessForge.Chat.Snapshot do
  @moduledoc false
  alias HarnessForge.{Contracts, Evidence, Privacy, Repo, Workspaces}
  alias HarnessForge.Models.Configuration
  alias HarnessForge.Evidence.{Connection, Revision, RevisionUseHolds, Source, Store}
  alias HarnessForge.Privacy.Purge

  @providers [
    {"local", "Local files"},
    {"github", "GitHub"},
    {"github_projects", "GitHub Projects"},
    {"jira", "Jira"},
    {"slack", "Slack"},
    {"confluence", "Confluence"}
  ]

  def catalog do
    with :ok <- Privacy.ready(),
         {:ok, connections} <- Evidence.list_connections(),
         {:ok, counts} <- captured_counts() do
      {:ok,
       %{
         "connectors" => connector_rows(connections, counts),
         "runtimes" => HarnessForge.Adapters.Registry.list(),
         "model" => model_status()
       }}
    end
  end

  def model_status do
    config = Configuration.get()
    reason = model_reason(config)

    %{
      "provider" => config["provider"],
      "model" => config["model"],
      "availability" => if(is_nil(reason), do: "configured", else: "unavailable"),
      "reason" => reason,
      "local_only" => config["provider"] == "ollama",
      "network_checked" => false,
      "chat_consent" => chat_consent?(config)
    }
  end

  def fingerprint, do: Contracts.digest(Configuration.get())

  def context_ref(citation),
    do:
      Map.take(
        citation,
        ~w(source_id connection_id provider title revision_id body_hash source_url captured_at)
      )

  def scope(citations, model_fingerprint) do
    %{
      "workspace_id" => Workspaces.current_id(),
      "model_fingerprint" => model_fingerprint,
      "context" => Enum.map(citations, &context_ref/1)
    }
  end

  def current?(scope) when is_map(scope) do
    with true <- valid_context?(scope),
         {:ok, snapshot} <- capture(scope["context"]) do
      current?(scope, snapshot)
    else
      _ -> false
    end
  end

  def current?(_), do: false

  @doc false
  def capture(refs) when is_list(refs) do
    if Repo.in_transaction?(),
      do: {:error, :chat_snapshot_requires_outermost_transaction},
      else: Purge.synchronize(fn -> capture_current(refs) end)
  end

  defp capture_current(refs) do
    with :ok <- Privacy.ready(),
         {:ok, connections} <- Evidence.list_connections() do
      active =
        connections |> Enum.filter(&(&1["status"] == "active")) |> Map.new(&{&1["id"], true})

      sources =
        refs
        |> Enum.map(& &1["source_id"])
        |> Enum.uniq()
        |> Enum.flat_map(&capture_source/1)
        |> Map.new()

      {:ok,
       %{
         workspace_id: Workspaces.current_id(),
         model_fingerprint: fingerprint(),
         active_connections: active,
         sources: sources
       }}
    end
  end

  def current?(scope, snapshot) when is_map(scope) do
    valid_context?(scope) and scope["workspace_id"] == snapshot.workspace_id and
      snapshot.workspace_id == Workspaces.current_id() and
      model_current?(scope["model_fingerprint"], snapshot) and
      Enum.all?(scope["context"], &ref_current?(&1, snapshot))
  end

  def current?(_, _), do: false

  def citation_current?(citation) when is_map(citation) do
    with {:ok, snapshot} <- capture([context_ref(citation)]) do
      citation_current?(citation, snapshot)
    else
      _ -> false
    end
  end

  def citation_current?(_), do: false

  def citation_current?(citation, snapshot) when is_map(citation) do
    with true <- ref_current?(context_ref(citation), snapshot),
         %{body: body} <- snapshot.sources[citation["source_id"]],
         start when is_integer(start) and start >= 0 <- citation["start_byte"],
         ending when is_integer(ending) and ending > start <- citation["end_byte"],
         true <- ending <= byte_size(body) do
      prefix = binary_part(body, 0, start)
      selected = binary_part(body, start, ending - start)
      String.valid?(prefix) and String.valid?(selected) and selected == citation["snippet"]
    else
      _ -> false
    end
  end

  def citation_current?(_, _), do: false

  def source_ref(source) do
    revision = source["latest_revision"]

    %{
      "source_id" => source["id"],
      "connection_id" => source["connection_id"],
      "provider" => source["provider"],
      "title" => truncate(source["title"], 512),
      "revision_id" => revision["id"],
      "body_hash" => revision["body_hash"],
      "source_url" => safe_url(revision["source_url"]),
      "captured_at" => revision["captured_at"]
    }
  end

  def eligible?(%{"status" => "active", "latest_revision" => revision} = source)
      when is_map(revision) do
    source["workspace_id"] == Workspaces.current_id() and
      revision["workspace_id"] == Workspaces.current_id() and
      revision["source_id"] == source["id"] and
      source["latest_revision_id"] == revision["id"] and
      is_binary(revision["body"]) and String.valid?(revision["body"]) and
      Contracts.sha256(revision["body"]) == revision["body_hash"]
  end

  def eligible?(_), do: false

  def truncate(value, bytes) when is_binary(value) do
    value |> binary_part(0, min(byte_size(value), bytes)) |> valid_prefix()
  end

  def truncate(_, _), do: ""

  def chat_consent?(config) do
    consent = config["cloud_consent"]

    config["provider"] == "ollama" or
      (is_map(consent) and is_list(consent["data_categories"]) and
         Enum.all?(~w(source_body chat_context), &(&1 in consent["data_categories"])))
  end

  defp capture_source(id) do
    with {:ok, source} <- Store.get(Source, id),
         true <- source.status == "active",
         {:ok, %{status: "active"}} <- Store.get(Connection, source.connection_id),
         {:ok, revision} <- capture_revision(source),
         source = Store.dto(source) |> Map.put("latest_revision", Store.dto(revision)),
         true <- eligible?(source) do
      [{id, %{ref: source_ref(source), body: source["latest_revision"]["body"]}}]
    else
      _ -> []
    end
  end

  # The outer privacy fence prevents a hold from committing during hydration.
  # Keep source access and the central denial in the body query, not per citation.
  defp capture_revision(source) do
    sql = """
    SELECT r.* FROM evidence_revisions r
    JOIN evidence_sources s ON s.id = r.source_id AND s.workspace_id = r.workspace_id
      AND s.latest_revision_id = r.id
    JOIN source_connections c ON c.id = s.connection_id AND c.workspace_id = s.workspace_id
    WHERE s.workspace_id = ? AND s.id = ? AND r.id = ?
      AND s.status = 'active' AND c.status = 'active'
      AND #{RevisionUseHolds.not_held_sql("r")}
    """

    case Repo.query(sql, [Workspaces.current_id(), source.id, source.latest_revision_id]) do
      {:ok, %{columns: columns, rows: [row]}} -> {:ok, Repo.load(Revision, {columns, row})}
      _ -> {:error, :source_unavailable}
    end
  end

  defp ref_current?(ref, snapshot) when is_map(ref) do
    case snapshot.sources[ref["source_id"]] do
      %{ref: stored} ->
        stored == ref and Map.has_key?(snapshot.active_connections, ref["connection_id"])

      _ ->
        false
    end
  end

  defp ref_current?(_, _), do: false

  defp valid_context?(scope),
    do:
      is_list(scope["context"]) and length(scope["context"]) <= 12 and
        Enum.all?(scope["context"], &is_map/1)

  defp model_current?(nil, _), do: true
  defp model_current?(value, snapshot), do: value == snapshot.model_fingerprint

  defp model_reason(%{"model" => nil}), do: "model_not_selected"
  defp model_reason(%{"provider" => "ollama"}), do: nil

  defp model_reason(config) do
    cond do
      not chat_consent?(config) -> "chat_context_consent_required"
      config["input_microusd_per_million"] <= 0 -> "cloud_cost_estimate_required"
      config["output_microusd_per_million"] <= 0 -> "cloud_cost_estimate_required"
      true -> credential_reason(config)
    end
  end

  defp credential_reason(config) do
    case Configuration.credential(config) do
      {:ok, _} -> nil
      _ -> "credential_unavailable"
    end
  end

  # This is a count of locally captured current revision records, not a content
  # integrity or semantic-coverage check. Exact chat reads still validate hashes
  # and UTF-8 in capture_source/1; the inventory never hydrates corpus bodies.
  defp captured_counts do
    sql = """
    SELECT s.connection_id, count(*)
    FROM evidence_sources s
    JOIN evidence_revisions r ON r.id = s.latest_revision_id
      AND r.source_id = s.id AND r.workspace_id = s.workspace_id
    WHERE s.workspace_id = ? AND s.status = 'active'
    GROUP BY s.connection_id
    """

    with {:ok, %{rows: rows}} <- Repo.query(sql, [Workspaces.current_id()]),
         :ok <- Privacy.ready() do
      {:ok, Map.new(rows, fn [id, count] -> {id, count} end)}
    end
  end

  defp connector_rows(connections, counts) do
    for {provider, label} <- @providers do
      %{
        "provider" => provider,
        "label" => label,
        "connections" =>
          connections
          |> Enum.filter(&(&1["provider"] == provider))
          |> Enum.map(&connection_row(&1, counts))
      }
    end
  end

  defp connection_row(connection, counts) do
    %{
      "id" => connection["id"],
      "name" => truncate(connection["name"], 256),
      "access_state" => connection["status"],
      "sync_state" => connection["sync_state"],
      "sync_complete" => connection["sync_complete"],
      "source_count" => Map.get(counts, connection["id"], 0),
      "source_count_kind" => "captured_revision_records"
    }
  end

  defp safe_url(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: query} when is_binary(host) ->
        if is_nil(query) or Regex.match?(~r/\ApageId=[1-9][0-9]*\z/, query), do: value

      _ ->
        nil
    end
  end

  defp safe_url(_), do: nil
  defp valid_prefix(<<>>), do: ""

  defp valid_prefix(value) do
    if String.valid?(value),
      do: value,
      else: value |> binary_part(0, byte_size(value) - 1) |> valid_prefix()
  end
end
