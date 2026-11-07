defmodule HarnessForge.MCP.Clients do
  @moduledoc "Owner-issued independent local client credentials; values are returned once, never audited."
  alias HarnessForge.{Audit, Repo}
  alias HarnessForge.Evidence.{Corpora, Store}

  def list(owner) do
    Corpora.guard(owner, fn ->
      rows =
        Corpora.rows(
          "SELECT id,name,generation,state,revoked_at,inserted_at FROM mcp_clients WHERE workspace_id=? ORDER BY inserted_at DESC,id DESC LIMIT 51",
          [Store.workspace()]
        )

      {:ok, %{"clients" => Enum.take(rows, 50), "truncated" => length(rows) > 50}}
    end)
  end

  def register(attrs, owner) do
    Corpora.guard(owner, fn ->
      with :ok <- Corpora.keys(attrs, ["name"]),
           true <- Corpora.text?(attrs["name"], 200) do
        id = Ecto.UUID.generate()
        credential = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        now = Corpora.now()

        with {:ok, _} <-
               Repo.query(
                 "INSERT INTO mcp_clients(id,workspace_id,name,token_hash,generation,state,inserted_at) VALUES(?,?,?,?,0,'active',?)",
                 [id, Store.workspace(), attrs["name"], Store.hash(credential), now],
                 log: false
               ),
             {:ok, _} <-
               Audit.append("mcp.client.registered", %{"actor" => id, "status" => "active"}) do
          {:ok,
           %{
             "client_id" => id,
             "name" => attrs["name"],
             "generation" => 0,
             "credential" => credential
           }}
        end
      else
        false -> {:error, :invalid_input}
        error -> error
      end
    end)
  end

  def revoke(id, owner) do
    Corpora.guard(owner, fn ->
      with {:ok, _} <- get(id),
           {:ok, _} <-
             Repo.query(
               "UPDATE mcp_clients SET state='revoked',generation=generation+1,revoked_at=? WHERE workspace_id=? AND id=? AND state='active'",
               [Corpora.now(), Store.workspace(), id],
               log: false
             ),
           {:ok, _} <- Audit.append("mcp.client.revoked", %{"actor" => id, "status" => "revoked"}) do
        {:ok, %{"client_id" => id, "state" => "revoked"}}
      end
    end)
  end

  def get(id) do
    if Corpora.uuid?(id) do
      case Corpora.rows("SELECT * FROM mcp_clients WHERE workspace_id=? AND id=?", [
             Store.workspace(),
             id
           ]) do
        [row] -> {:ok, row}
        _ -> {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  end

  def authenticate(token) when is_binary(token) do
    if byte_size(token) in 43..256 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, token) do
      hash = Store.hash(token)

      rows =
        Corpora.rows(
          "SELECT * FROM mcp_clients WHERE workspace_id=? AND token_hash=? AND state='active' LIMIT 1",
          [Store.workspace(), hash]
        )

      expected =
        case rows do
          [row] -> row["token_hash"]
          _ -> String.duplicate("0", 64)
        end

      valid = Plug.Crypto.secure_compare(expected, hash)
      if valid and length(rows) == 1, do: {:ok, hd(rows)}, else: {:error, :unauthorized}
    else
      {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def authenticate(_), do: {:error, :unauthorized}

  def current?(context) do
    with {:ok, client} <- get(context.client_id),
         true <- client["state"] == "active" and client["generation"] == context.client_generation,
         true <- is_binary(context.token_hash) and byte_size(context.token_hash) == 64,
         true <- Plug.Crypto.secure_compare(client["token_hash"], context.token_hash),
         do: :ok,
         else: (_ -> {:error, :client_grant_unavailable})
  end
end
