defmodule HarnessForge.MCP.Protocol do
  @moduledoc "Stateless MCP 2025-11-25 messages over the authenticated local HTTP boundary."

  alias HarnessForge.MCP.Tools

  @version "2025-11-25"
  @safe_integer 9_007_199_254_740_991

  @spec version() :: String.t()
  def version, do: @version

  @spec handle(term()) ::
          {:reply, map()} | :accepted_notification | {:reject, pos_integer(), map()}
  def handle(request) do
    if valid_envelope?(request) do
      dispatch(request)
    else
      {:reject, 400, error(nil, -32600, "Invalid request")}
    end
  rescue
    _ -> {:reject, 500, error(request_id(request), -32603, "Internal error")}
  catch
    _, _ -> {:reject, 500, error(request_id(request), -32603, "Internal error")}
  end

  defp valid_envelope?(request) when is_map(request) and not is_struct(request) do
    Map.keys(request) -- ~w(jsonrpc id method params) == [] and
      request["jsonrpc"] == "2.0" and bounded_string?(request["method"], 128) and
      valid_optional_params?(request) and
      (not Map.has_key?(request, "id") or valid_id?(request["id"]))
  end

  defp valid_envelope?(_), do: false

  defp valid_optional_params?(request),
    do: not Map.has_key?(request, "params") or object?(request["params"])

  defp valid_id?(id) when is_integer(id), do: id in -@safe_integer..@safe_integer
  defp valid_id?(id) when is_binary(id), do: byte_size(id) <= 128 and String.valid?(id)
  defp valid_id?(_), do: false

  defp request_id(request) when is_map(request) do
    if valid_id?(request["id"]), do: request["id"], else: nil
  end

  defp request_id(_), do: nil

  defp dispatch(%{"method" => "notifications/initialized"} = request) do
    if not Map.has_key?(request, "id") and empty_params?(request) do
      :accepted_notification
    else
      {:reject, 400, error(request_id(request), -32600, "Invalid notification")}
    end
  end

  defp dispatch(%{"id" => id} = request), do: dispatch_request(request, id)
  defp dispatch(_), do: {:reject, 400, error(nil, -32600, "Unsupported notification")}

  defp dispatch_request(%{"method" => "initialize"} = request, id) do
    if initialize_params?(request["params"]) do
      reply(id, %{
        "protocolVersion" => @version,
        "capabilities" => %{"tools" => %{"listChanged" => false}},
        "serverInfo" => %{"name" => "HarnessForge", "version" => "0.1.0"}
      })
    else
      invalid_params(id)
    end
  end

  defp dispatch_request(%{"method" => "ping"} = request, id) do
    if empty_params?(request), do: reply(id, %{}), else: invalid_params(id)
  end

  defp dispatch_request(%{"method" => "tools/list"} = request, id) do
    if empty_params?(request),
      do: reply(id, %{"tools" => Tools.list()}),
      else: invalid_params(id)
  end

  defp dispatch_request(%{"method" => "tools/call", "params" => params}, id) do
    arguments = Map.get(params, "arguments", %{})

    if exact_params?(params, ~w(name arguments _meta)) and
         bounded_string?(params["name"], 128) and object?(arguments) do
      tool_reply(id, Tools.call(params["name"], arguments))
    else
      invalid_params(id)
    end
  end

  defp dispatch_request(%{"method" => "tools/call"}, id), do: invalid_params(id)
  defp dispatch_request(_, id), do: {:reply, error(id, -32601, "Method not found")}

  defp initialize_params?(params) do
    exact_params?(params, ~w(protocolVersion capabilities clientInfo _meta)) and
      bounded_string?(params["protocolVersion"], 32) and object?(params["capabilities"]) and
      client_info?(params["clientInfo"])
  end

  defp client_info?(info) when is_map(info) do
    bounded_string?(info["name"], 256) and bounded_string?(info["version"], 256)
  end

  defp client_info?(_), do: false

  defp empty_params?(request), do: exact_params?(Map.get(request, "params", %{}), ~w(_meta))

  defp exact_params?(params, keys) do
    object?(params) and Map.keys(params) -- keys == [] and
      (not Map.has_key?(params, "_meta") or object?(params["_meta"]))
  end

  defp object?(value), do: is_map(value) and not is_struct(value)

  defp bounded_string?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp tool_reply(id, {:ok, result}) when is_map(result), do: reply(id, content(result, false))

  defp tool_reply(id, {:error, reason}) when reason in [:unknown_tool, :invalid_arguments],
    do: invalid_params(id)

  defp tool_reply(id, {:error, reason}) do
    {code, message} = tool_error(reason)
    reply(id, content(%{"error" => %{"code" => code, "message" => message}}, true))
  end

  defp tool_error(:not_found), do: {"not_found", "Requested item is unavailable"}
  defp tool_error(:package_unavailable), do: {"package_unavailable", "Package is unavailable"}
  defp tool_error(_), do: {"unavailable", "Tool is temporarily unavailable"}

  defp content(result, is_error) do
    %{
      "structuredContent" => result,
      "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
      "isError" => is_error
    }
  end

  defp reply(id, result), do: {:reply, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
  defp invalid_params(id), do: {:reply, error(id, -32602, "Invalid params")}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
