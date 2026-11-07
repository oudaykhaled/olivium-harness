defmodule HarnessForge.RawHTTPDeadlineTest.Upstream do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, %{owner: owner}) do
    send(owner, {:raw_http_request, conn.request_path})

    case conn.request_path do
      route when route in ["/drip-timeout", "/drip-deadline"] ->
        conn = conn |> put_resp_content_type("application/octet-stream") |> send_chunked(200)

        # A progressing peer must not reset the absolute request budget.
        Enum.reduce_while(1..100, conn, fn count, conn ->
          case chunk(conn, " ") do
            {:ok, conn} ->
              send(owner, {:raw_http_chunk, route, count})
              Process.sleep(20)
              {:cont, conn}

            {:error, _} ->
              {:halt, conn}
          end
        end)

      "/redirect" ->
        conn |> put_resp_header("location", "/raw") |> send_resp(307, "")

      "/oversized" ->
        send_resp(conn, 200, String.duplicate("x", 98_305))

      "/raw" ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, <<0, 255, 123, 32, 125>>)

      _ ->
        send_resp(conn, 404, "")
    end
  end
end

defmodule HarnessForge.RawHTTPDeadlineTest do
  use HarnessForge.DataCase, async: false

  alias HarnessForge.Models.HTTP

  setup do
    previous = Application.fetch_env(:harness_forge, :model_test_plug)
    Application.delete_env(:harness_forge, :model_test_plug)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:harness_forge, :model_test_plug, value)
        :error -> Application.delete_env(:harness_forge, :model_test_plug)
      end
    end)

    upstream =
      start_supervised!(
        {Bandit,
         [
           plug: {__MODULE__.Upstream, %{owner: self()}},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false
         ]}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(upstream)
    %{endpoint: "http://127.0.0.1:#{port}"}
  end

  test "raw collection stops a continuously progressing peer at the earlier absolute cutoff", %{
    endpoint: endpoint
  } do
    for {route, timeout, deadline_offset} <- [
          {"/drip-timeout", 150, 5_000},
          {"/drip-deadline", 1_000, 150}
        ] do
      started = now_ms()

      assert {:error, :model_deadline_exceeded} =
               HTTP.request_raw(:post, endpoint <> route, "{}", [],
                 timeout: timeout,
                 deadline_ms: started + deadline_offset
               )

      assert now_ms() - started < 600
      assert_receive {:raw_http_request, ^route}
      assert_receive {:raw_http_chunk, ^route, count} when count >= 2
      refute_receive {:raw_http_request, ^route}, 30
    end
  end

  test "SQL admission crosses the cutoff in its owner, preserves SQL and sends no HTTP", %{
    endpoint: endpoint
  } do
    owner = self()

    gate =
      Task.async(fn ->
        receive do
          {:guard_has_sql, pid} ->
            Process.sleep(100)
            send(pid, :finish_guard_sql)
        after
          2_000 -> flunk("SQL admission guard never reached its controlled gate")
        end
      end)

    guard = fn ->
      assert {:ok, :guard_finished} =
               Repo.transaction(fn ->
                 assert [[1]] == Repo.query!("SELECT 1").rows
                 send(owner, {:raw_sql_admission_owner, self()})
                 send(gate.pid, {:guard_has_sql, self()})

                 receive do
                   :finish_guard_sql -> :ok
                 after
                   1_000 -> flunk("SQL admission gate was not released")
                 end

                 assert [[2]] == Repo.query!("SELECT 2").rows
                 :guard_finished
               end)

      :ok
    end

    assert {:error, :model_deadline_exceeded} =
             HTTP.request_raw(:post, endpoint <> "/raw", "{}", [],
               timeout: 50,
               deadline_ms: now_ms() + 50,
               dispatch_guard: guard
             )

    assert :finish_guard_sql = Task.await(gate, 2_000)
    assert_receive {:raw_sql_admission_owner, ^owner}
    assert [[3]] == Repo.query!("SELECT 3").rows
    refute_receive {:raw_http_request, _}, 30
  end

  test "invalid or already elapsed raw deadlines refuse dispatch", %{endpoint: endpoint} do
    owner = self()

    guard = fn ->
      send(owner, :raw_dispatch_guard_ran)
      :ok
    end

    for opts <- [
          [timeout: 0],
          [timeout: -1],
          [timeout: 60_001],
          [timeout: nil],
          [timeout: "100"],
          [deadline_ms: nil],
          [deadline_ms: "later"]
        ] do
      assert {:error, :invalid_input} =
               HTTP.request_raw(
                 :post,
                 endpoint <> "/raw",
                 "{}",
                 [],
                 Keyword.put(opts, :dispatch_guard, guard)
               )
    end

    assert {:error, :model_deadline_exceeded} =
             HTTP.request_raw(:post, endpoint <> "/raw", "{}", [],
               timeout: 100,
               deadline_ms: now_ms() - 1,
               dispatch_guard: guard
             )

    refute_receive :raw_dispatch_guard_ran, 30
    refute_receive {:raw_http_request, _}, 30
  end

  test "bounded raw collection preserves original bytes, redirect denial and the byte cap", %{
    endpoint: endpoint
  } do
    assert {:ok, %{"status" => 200, "body" => <<0, 255, 123, 32, 125>>}} =
             HTTP.request_raw(:post, endpoint <> "/raw", "{}", [], timeout: 1_000)

    assert_receive {:raw_http_request, "/raw"}

    assert {:error, :model_redirect_denied} =
             HTTP.request_raw(:post, endpoint <> "/redirect", "{}", [], timeout: 1_000)

    assert_receive {:raw_http_request, "/redirect"}
    refute_receive {:raw_http_request, "/raw"}, 30

    assert {:error, :model_response_too_large} =
             HTTP.request_raw(:post, endpoint <> "/oversized", "{}", [], timeout: 1_000)

    assert_receive {:raw_http_request, "/oversized"}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
