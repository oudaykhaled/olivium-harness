defmodule HarnessForge.Workspaces do
  @moduledoc """
  One workspace per application process. A dedicated SQLite transaction owns
  the directory across OS processes and releases automatically on VM death.
  The evidence database uses a separate file and connection pool.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def root do
    Application.get_env(:harness_forge, :workspace_root) ||
      Path.join(System.user_home!(), ".local/share/harnessforge/default")
  end

  def current_id, do: Application.fetch_env!(:harness_forge, :workspace_id)
  def access_token, do: GenServer.call(__MODULE__, :access_token)
  def session_epoch, do: GenServer.call(__MODULE__, :session_epoch)
  def rotate_session_epoch, do: GenServer.call(__MODULE__, :rotate_session_epoch)
  def operator, do: "local-operator"

  @doc "Validates the existing process-bound operator session without granting source use."
  def authenticate_operator(%{"workspace_id" => id, "epoch" => epoch, "issued_at" => issued})
      when is_binary(epoch) and is_integer(issued) do
    age = System.system_time(:second) - issued

    if id == current_id() and age >= 0 and age < 43_200 and
         Plug.Crypto.secure_compare(epoch, session_epoch()) do
      {:ok, %{workspace_id: current_id(), owner_id: operator()}}
    else
      {:error, :operator_session_revoked}
    end
  end

  def authenticate_operator(_), do: {:error, :operator_session_revoked}

  def ensure_writable do
    if Code.ensure_loaded?(HarnessForge.Privacy) and
         function_exported?(HarnessForge.Privacy, :ready, 0),
       do: HarnessForge.Privacy.ready(),
       else: :ok
  end

  def paths do
    %{
      "root" => root(),
      "artifacts" => Path.join(root(), "artifacts"),
      "runs" => Path.join(root(), "runs"),
      "database" => database_path()
    }
  end

  def database_path, do: HarnessForge.Repo.config()[:database]

  @doc "Acquires a kernel-backed exclusive lock; caller must retain/close the connection."
  def acquire(root) do
    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         {:ok, connection} <- Exqlite.Sqlite3.open(Path.join(root, ".ownership.sqlite3")) do
      case Exqlite.Sqlite3.execute(connection, "PRAGMA busy_timeout=0; BEGIN EXCLUSIVE;") do
        :ok ->
          File.chmod(Path.join(root, ".ownership.sqlite3"), 0o600)
          {:ok, connection}

        {:error, _} ->
          Exqlite.Sqlite3.close(connection)
          {:error, :workspace_in_use}
      end
    end
  end

  def release(connection), do: Exqlite.Sqlite3.close(connection)

  @impl true
  def init(_opts) do
    case acquire(root()) do
      {:ok, lock} ->
        Process.flag(:trap_exit, true)
        id = load_identity!()
        Application.put_env(:harness_forge, :workspace_id, id)
        Enum.each(["artifacts", "runs", "tmp"], &File.mkdir_p!(Path.join(root(), &1)))
        token = secret_file!("access-token", 32)
        endpoint_config = Application.fetch_env!(:harness_forge, HarnessForgeWeb.Endpoint)

        Application.put_env(
          :harness_forge,
          HarnessForgeWeb.Endpoint,
          Keyword.put(endpoint_config, :secret_key_base, secret_file!("session-secret", 64))
        )

        {:ok,
         %{
           lock: lock,
           token: token,
           epoch: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:access_token, _from, state), do: {:reply, state.token, state}
  def handle_call(:session_epoch, _from, state), do: {:reply, state.epoch, state}

  def handle_call(:rotate_session_epoch, _from, state) do
    epoch = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    Phoenix.PubSub.broadcast(
      HarnessForge.PubSub,
      "workspace:" <> current_id(),
      :operator_session_revoked
    )

    {:reply, :ok, %{state | epoch: epoch}}
  end

  @impl true
  def terminate(_reason, state), do: release(state.lock)

  defp load_identity! do
    path = Path.join(root(), "workspace.json")

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"id" => id}} when is_binary(id) and byte_size(id) > 0 -> id
          _ -> raise "Invalid workspace identity; restore a valid backup instead of replacing it"
        end

      {:error, :enoent} ->
        id = Ecto.UUID.generate()
        File.write!(path, Jason.encode!(%{"id" => id, "version" => 1}), [:exclusive])
        File.chmod!(path, 0o600)
        id

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read workspace identity", path: path
    end
  end

  defp secret_file!(name, bytes) do
    path = Path.join(root(), name)

    case File.read(path) do
      {:ok, token} ->
        File.chmod!(path, 0o600)
        String.trim(token)

      {:error, :enoent} ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)
        File.write!(path, token <> "\n", [:exclusive])
        File.chmod!(path, 0o600)
        token

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read workspace credential", path: path
    end
  end
end
