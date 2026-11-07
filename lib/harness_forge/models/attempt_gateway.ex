defmodule HarnessForge.Models.AttemptGateway do
  @moduledoc "One actual HTTP attempt through root-owned authority, raw HTTP and the existing ledger."
  alias HarnessForge.Graphiti.Protocol
  alias HarnessForge.Models.{HTTP, StageAuthority}

  @public_grant ~w(attempt_id grant_id payload_sha256 expires_at cancel_epoch)

  def dispatch(attempt, authority), do: dispatch(attempt, authority, nil, fn _ -> :ok end)

  @doc false
  def dispatch(attempt, authority, job, notify_grant) when is_function(notify_grant, 1) do
    with :ok <- Protocol.validate_payload("attempt", attempt),
         {:ok, grant} <- StageAuthority.admit_attempt(context(attempt, authority, nil)),
         :ok <- grant_binding(grant, attempt) do
      ctx = context(attempt, authority, grant)
      outcome = perform(ctx, job, notify_grant)

      # Raw bodies remain ephemeral: root settles one receipt/usage record.
      with {:ok, receipt} <- StageAuthority.finish_attempt(ctx, outcome),
           :ok <- Protocol.validate_payload("attempt_result", receipt),
           true <- receipt["attempt_id"] == attempt["attempt_id"],
           :ok <- retain_receipt(authority, attempt, receipt) do
        {:ok, receipt}
      else
        _ -> {:error, :reconcile_required}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :scope_denied}
    end
  rescue
    _ -> {:error, :reconcile_required}
  catch
    :exit, _ -> {:error, :reconcile_required}
  end

  defp retain_receipt(%StageAuthority{operation_type: type} = auth, attempt, receipt)
       when type in ~w(ingest search remove),
       do: HarnessForge.Graphiti.Runtime.retain_receipt(auth, attempt, receipt)

  defp retain_receipt(_, _, _), do: :ok

  defp perform(ctx, job, notify_grant) do
    with :ok <- notify_grant.(Map.take(ctx["grant"], @public_grant)),
         {:ok, dispatch} <- StageAuthority.mark_dispatching(ctx),
         true <- valid_dispatch?(dispatch),
         :ok <- revalidate(ctx, job) do
      result =
        HTTP.request_raw(:post, dispatch["url"], ctx["attempt"]["body"], dispatch["headers"],
          timeout: min(dispatch["timeout_ms"], ctx["attempt"]["timeout_ms"]),
          dispatch_guard: fn -> revalidate(ctx, job) end
        )

      bound_response(result)
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :scope_denied}
    end
  rescue
    _ -> {:error, :model_service_unavailable}
  catch
    :exit, _ -> {:error, :model_service_unavailable}
  end

  defp revalidate(ctx, job),
    do:
      StageAuthority.revalidate_job(%{
        "job" => job,
        "authority" => ctx["authority"],
        "result" => nil
      })

  defp bound_response({:ok, %{"status" => status, "body" => body} = response})
       when is_integer(status) and status in 100..599 and is_binary(body) do
    if byte_size(body) <= 98_304 and String.valid?(body),
      do: {:ok, response},
      else: {:error, :response_limit}
  end

  defp bound_response({:error, _} = error), do: error
  defp bound_response(_), do: {:error, :invalid_provider_response}

  defp valid_dispatch?(%{"url" => url, "headers" => headers, "timeout_ms" => timeout}) do
    is_binary(url) and is_list(headers) and is_integer(timeout) and timeout in 1..60_000
  end

  defp valid_dispatch?(_), do: false

  defp context(attempt, authority, grant),
    do: %{"attempt" => attempt, "authority" => authority, "grant" => grant}

  defp grant_binding(grant, attempt) when is_map(grant) do
    public = Map.take(grant, @public_grant)

    with :ok <- Protocol.validate_payload("attempt_grant", public),
         true <- public["attempt_id"] == attempt["attempt_id"],
         true <- public["payload_sha256"] == attempt["payload_sha256"],
         true <- public["cancel_epoch"] == attempt["cancel_epoch"],
         {:ok, expiry, _} <- DateTime.from_iso8601(public["expires_at"]),
         true <- DateTime.compare(expiry, DateTime.utc_now()) == :gt do
      :ok
    else
      _ -> {:error, :scope_denied}
    end
  end

  defp grant_binding(_, _), do: {:error, :scope_denied}
end
