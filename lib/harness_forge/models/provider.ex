defmodule HarnessForge.Models.Provider do
  @moduledoc "Inference adapter boundary. Adapters return text plus reported token usage; they never persist authority."
  @callback generate(map(), map(), binary() | nil, keyword()) :: {:ok, map()} | {:error, atom()}
end

defmodule HarnessForge.Models.HTTP do
  @moduledoc false
  @max_response 262_144

  @doc false
  def request_raw(method, url, body, headers, opts)
      when method in [:post, :get] and is_binary(url) and is_binary(body) and
             byte_size(body) <= 98_304 and is_list(headers) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    started = monotonic_ms()

    with true <- is_integer(timeout) and timeout in 1..60_000,
         deadline <- Keyword.get(opts, :deadline_ms, started + timeout),
         true <- is_integer(deadline),
         :ok <- raw_endpoint(url) do
      deadline = min(deadline, started + timeout)
      opts = Keyword.put(opts, :deadline_ms, deadline)

      # SQL-bearing admission stays in the owner, outside the cancellable reader.
      with :ok <- deadline_guard(opts) do
        transport_opts = Keyword.delete(opts, :dispatch_guard)

        bounded_request(deadline, fn ->
          raw_request(
            method,
            url,
            body,
            headers,
            transport_opts,
            max(1, min(timeout, deadline - monotonic_ms()))
          )
        end)
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  rescue
    _ -> {:error, :model_service_unavailable}
  end

  def request_raw(_, _, _, _, _), do: {:error, :invalid_input}

  defp raw_request(method, url, body, headers, opts, timeout) do
    options = [
      method: method,
      url: url,
      headers: headers,
      body: body,
      redirect: false,
      retry: false,
      retry_log_level: false,
      compressed: false,
      decode_body: false,
      receive_timeout: timeout,
      connect_options: [timeout: 1_000],
      into: &collect_raw/2
    ]

    options =
      case Application.get_env(:harness_forge, :model_test_plug) do
        nil -> options
        plug -> Keyword.put(options, :plug, plug)
      end

    with :ok <- transport_deadline(opts) do
      case Req.request(options) do
        {:ok, response} ->
          cond do
            response.private[:model_response_too_large] ->
              {:error, :model_response_too_large}

            response.status in 300..399 ->
              {:error, :model_redirect_denied}

            not is_binary(response.body) or byte_size(response.body) > 98_304 ->
              {:error, :model_response_too_large}

            true ->
              {:ok, %{"status" => response.status, "body" => response.body}}
          end

        {:error, _} ->
          {:error, :model_service_unavailable}
      end
    end
  rescue
    _ -> {:error, :model_service_unavailable}
  end

  @doc "Fixed local native Responses POST with bounded original SSE bytes and no forwarded credentials."
  def request_responses(url, body, opts)
      when is_binary(url) and is_binary(body) and byte_size(body) <= 131_072 and is_list(opts) do
    uri = URI.parse(url)
    timeout = Keyword.get(opts, :timeout, 30_000)
    deadline = Keyword.get(opts, :deadline_ms, monotonic_ms() + timeout)

    with true <-
           uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"] and
             uri.port in 1..65_535 and uri.path == "/v1/responses" and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- is_integer(timeout) and timeout in 1..60_000 and is_integer(deadline) do
      deadline = min(deadline, monotonic_ms() + timeout)
      opts = Keyword.put(opts, :deadline_ms, deadline)

      # Authority callbacks may use SQL. Keep them in the admission/settlement
      # owner, outside every forcibly cancellable network collector.
      with :ok <- deadline_guard(opts) do
        transport_opts = Keyword.delete(opts, :dispatch_guard)

        bounded_request(deadline, fn ->
          responses_request(
            url,
            body,
            transport_opts,
            max(1, min(timeout, deadline - monotonic_ms()))
          )
        end)
      end
    else
      _ -> {:error, :unsafe_model_endpoint}
    end
  rescue
    _ -> {:error, :model_service_unavailable}
  end

  def request_responses(_, _, _), do: {:error, :invalid_input}

  @doc "Metadata-only local routes, with an absolute deadline even for a continuously dripping peer."
  def request_metadata(method, url, body, opts) when is_binary(url) and is_list(opts) do
    uri = URI.parse(url)
    deadline = Keyword.get(opts, :deadline_ms)

    allowed_route =
      (method == :get and uri.path in ["/api/version", "/api/tags"] and is_nil(body)) or
        (method == :post and uri.path == "/api/show" and is_map(body) and
           Map.keys(body) == ["model"] and is_binary(body["model"]))

    with true <- allowed_route and is_integer(deadline),
         true <-
           uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"] and
             uri.port in 1..65_535 and is_nil(uri.userinfo) and
             is_nil(uri.query) and is_nil(uri.fragment),
         deadline = min(deadline, monotonic_ms() + 2_000) do
      guard_opts = Keyword.put(opts, :deadline_ms, deadline)

      with :ok <- deadline_guard(guard_opts) do
        transport_opts = Keyword.delete(guard_opts, :dispatch_guard)

        bounded_request(deadline, fn ->
          with :ok <- transport_deadline(transport_opts) do
            request(
              method,
              url,
              body,
              [],
              Keyword.put(transport_opts, :timeout, max(1, deadline - monotonic_ms()))
            )
          end
        end)
      end
    else
      _ -> {:error, :unsafe_model_endpoint}
    end
  rescue
    _ -> {:error, :model_service_unavailable}
  end

  def request_metadata(_, _, _, _), do: {:error, :invalid_input}

  defp bounded_request(deadline, function) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      {:error, :model_deadline_exceeded}
    else
      # Only network collection runs here: no SQL-bearing authority callback
      # may be put in this task. Unlike receive_timeout, expiry bounds even a
      # continuously dripping peer; the caller still owns Ledger settlement.
      task =
        Task.Supervisor.async_nolink(HarnessForge.Tasks, fn ->
          # The network reader owns its expiry even if its caller disappears.
          case deadline - monotonic_ms() do
            left when left > 0 ->
              {:ok, timer} = :timer.exit_after(left, self(), :kill)

              try do
                function.()
              after
                :timer.cancel(timer)
              end

            _ ->
              {:error, :model_deadline_exceeded}
          end
        end)

      case Task.yield(task, remaining) do
        {:ok, result} ->
          if monotonic_ms() < deadline, do: result, else: {:error, :model_deadline_exceeded}

        _ ->
          Task.shutdown(task, :brutal_kill)
          {:error, :model_deadline_exceeded}
      end
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp responses_request(url, body, opts, timeout) do
    options = [
      method: :post,
      url: url,
      body: body,
      headers: [{"content-type", "application/json"}, {"accept", "text/event-stream"}],
      redirect: false,
      retry: false,
      retry_log_level: false,
      compressed: false,
      decode_body: false,
      receive_timeout: timeout,
      connect_options: [timeout: 1_000],
      into: &collect/2
    ]

    options =
      case Application.get_env(:harness_forge, :model_test_plug) do
        nil -> options
        plug -> Keyword.put(options, :plug, plug)
      end

    with :ok <- transport_deadline(opts), {:ok, response} <- Req.request(options) do
      cond do
        response.private[:model_response_too_large] ->
          {:error, :model_response_too_large}

        response.status in 300..399 ->
          {:error, :model_redirect_denied}

        not is_binary(response.body) or byte_size(response.body) > @max_response ->
          {:error, :model_response_too_large}

        true ->
          {:ok,
           %{
             "status" => response.status,
             "content_type" => Req.Response.get_header(response, "content-type"),
             "body" => response.body
           }}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :model_service_unavailable}
    end
  rescue
    _ -> {:error, :model_service_unavailable}
  end

  defp deadline_guard(opts) do
    deadline = Keyword.fetch!(opts, :deadline_ms)

    with true <- monotonic_ms() < deadline,
         :ok <- dispatch_guard(opts),
         true <- monotonic_ms() < deadline do
      :ok
    else
      false -> {:error, :model_deadline_exceeded}
      error -> error
    end
  end

  # Pure clock check only. All authority callbacks have already returned in the
  # non-killed admission owner before a transport task can be created.
  defp transport_deadline(opts) do
    if monotonic_ms() < Keyword.fetch!(opts, :deadline_ms),
      do: :ok,
      else: {:error, :model_deadline_exceeded}
  end

  defp raw_endpoint(url) do
    uri = URI.parse(url)

    allowed =
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
        ((uri.scheme == "https" and
            uri.host in ["api.openai.com", "api.anthropic.com", "api.typesafe.ai"] and
            uri.port == 443) or
           (uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"] and uri.port in 1..65_535))

    if allowed, do: :ok, else: {:error, :unsafe_model_endpoint}
  end

  defp collect_raw({:data, bytes}, {request, response}) do
    if byte_size(response.body) + byte_size(bytes) <= 98_304 do
      {:cont, {request, %{response | body: response.body <> bytes}}}
    else
      {:halt, {request, Req.Response.put_private(response, :model_response_too_large, true)}}
    end
  end

  def request(method, url, body, headers, opts) do
    options = [
      method: method,
      url: url,
      headers: headers,
      redirect: false,
      retry: false,
      retry_log_level: false,
      compressed: false,
      decode_body: false,
      receive_timeout: Keyword.get(opts, :timeout, 30_000),
      connect_options: [timeout: 1_000],
      into: &collect/2
    ]

    options = if body, do: Keyword.put(options, :json, body), else: options
    # Application-owned transport injection is for deterministic tests only.
    options =
      case Application.get_env(:harness_forge, :model_test_plug) do
        nil -> options
        plug -> Keyword.put(options, :plug, plug)
      end

    with :ok <- dispatch_guard(opts) do
      case Req.request(options) do
        {:ok, response} ->
          cond do
            response.private[:model_response_too_large] ->
              {:error, :model_response_too_large}

            response.status in 300..399 ->
              {:error, :model_redirect_denied}

            response.status == 404 ->
              {:error, :model_unavailable}

            response.status in [401, 403] ->
              {:error, :model_authentication_denied}

            response.status == 429 ->
              {:error, :model_rate_limited}

            response.status != 200 ->
              {:error, :model_service_unavailable}

            not is_binary(response.body) or byte_size(response.body) > @max_response ->
              {:error, :model_response_too_large}

            true ->
              case Jason.decode(response.body) do
                {:ok, %{"error" => error}} when not is_nil(error) -> provider_error(error)
                {:ok, %{"type" => "error"}} -> {:error, :model_service_unavailable}
                {:ok, value} when is_map(value) -> {:ok, value}
                _ -> {:error, :invalid_provider_response}
              end
          end

        {:error, _} ->
          {:error, :model_service_unavailable}
      end
    end
  rescue
    # Exceptions may contain the authorization header or prompt. Never expose them.
    _ -> {:error, :model_service_unavailable}
  end

  defp dispatch_guard(opts) do
    case Keyword.get(opts, :dispatch_guard) do
      nil -> :ok
      guard when is_function(guard, 0) -> guard.()
    end
  end

  defp collect({:data, bytes}, {request, response}) do
    if byte_size(response.body) + byte_size(bytes) <= @max_response do
      {:cont, {request, %{response | body: response.body <> bytes}}}
    else
      {:halt, {request, Req.Response.put_private(response, :model_response_too_large, true)}}
    end
  end

  defp provider_error(%{"code" => code})
       when code in ["invalid_api_key", "permission_denied"],
       do: {:error, :model_authentication_denied}

  defp provider_error(%{"code" => code})
       when code in ["rate_limit_exceeded", "insufficient_quota"],
       do: {:error, :model_rate_limited}

  defp provider_error(%{"type" => type})
       when type in ["authentication_error", "invalid_api_key", "permission_error"],
       do: {:error, :model_authentication_denied}

  defp provider_error(%{"type" => type})
       when type in ["rate_limit_error", "rate_limit_exceeded", "insufficient_quota"],
       do: {:error, :model_rate_limited}

  defp provider_error(_), do: {:error, :model_service_unavailable}
end

defmodule HarnessForge.Models.Ollama do
  @moduledoc "Actual Ollama /api/generate adapter. No model pull, remote fallback, redirects, or tools."
  @behaviour HarnessForge.Models.Provider
  alias HarnessForge.Models.{HTTP, Profile}

  def available(config, opts \\ []) do
    with {:ok, %{"models" => models}} when is_list(models) <-
           HTTP.request(
             :get,
             config["endpoint"] <> "/api/tags",
             nil,
             [],
             Keyword.put(opts, :timeout, 1_000)
           ),
         selected when not is_nil(selected) <-
           Enum.find(models, fn model ->
             model["name"] == config["model"] or model["model"] == config["model"]
           end),
         true <-
           is_nil(selected["remote_host"]) and is_nil(selected["remote_model"]) and
             not String.contains?(String.downcase(config["model"]), "cloud") do
      :ok
    else
      false -> {:error, :cloud_model_denied}
      nil -> {:error, :model_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :model_service_unavailable}
    end
  end

  @impl true
  def generate(config, request, _credential, opts) do
    body = %{
      "model" => config["model"],
      "prompt" => request["prompt"],
      "system" => Profile.system(request),
      "format" => Profile.schema(request),
      "stream" => false,
      "options" => %{"num_predict" => request["max_output_tokens"], "temperature" => 0}
    }

    with :ok <- available(config, opts),
         {:ok, value} <-
           HTTP.request(:post, config["endpoint"] <> "/api/generate", body, [], opts),
         true <- value["done"] == true and is_binary(value["response"]) do
      {:ok,
       %{
         text: value["response"],
         input_tokens: value["prompt_eval_count"],
         output_tokens: value["eval_count"]
       }}
    else
      false -> {:error, :invalid_provider_response}
      error -> error
    end
  end
end

defmodule HarnessForge.Models.OpenAI do
  @moduledoc "Optional OpenAI Chat Completions adapter. Fixture-tested; live paid compatibility is unverified."
  @behaviour HarnessForge.Models.Provider
  alias HarnessForge.Models.{HTTP, Profile}

  @impl true
  def generate(config, request, credential, opts) do
    body = %{
      "model" => config["model"],
      "store" => false,
      "stream" => false,
      "max_completion_tokens" => request["max_output_tokens"],
      "messages" => [
        %{"role" => "system", "content" => Profile.system(request)},
        %{"role" => "user", "content" => request["prompt"]}
      ],
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => Profile.name(request),
          "strict" => true,
          "schema" => Profile.wire_schema(request, "openai")
        }
      }
    }

    with {:ok,
          %{
            "choices" => [%{"message" => %{"content" => text}, "finish_reason" => "stop"}],
            "usage" => usage
          }} <-
           HTTP.request(
             :post,
             config["endpoint"] <> "/chat/completions",
             body,
             [{"authorization", "Bearer " <> credential}],
             opts
           ),
         true <- is_binary(text) and is_map(usage) do
      {:ok,
       %{
         text: text,
         input_tokens: usage["prompt_tokens"],
         output_tokens: usage["completion_tokens"]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_response}
    end
  end
end
