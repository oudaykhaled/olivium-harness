defmodule HarnessForge.Graphiti do
  @moduledoc "Explicit Graphiti candidate lane. Scope, manifests and publication remain root-owned."
  alias HarnessForge.Graphiti.{Runtime, Worker}

  def submit(job, authority), do: safely(fn -> Worker.submit(Worker, job, authority) end)
  def cancel(job_id, epoch), do: safely(fn -> Worker.cancel(Worker, job_id, epoch) end)
  def status(job_id), do: safely(fn -> Worker.status(Worker, job_id) end)

  @doc "Await canonical candidate results outside SQL/privacy locks; no lexical fallback."
  def search(%{"op" => "search"} = job, authority) do
    with {:ok, %{"state" => "completed"} = result} <-
           Runtime.await(authority, job, job["deadline_ms"] + 5_000) do
      {:ok, result}
    else
      {:ok, %{"result" => %{"error_code" => code}}} -> {:error, code}
      {:error, _} = error -> error
      _ -> {:error, :stage_unavailable}
    end
  catch
    :exit, _ -> {:error, :worker_lost}
  end

  def search(_, _), do: {:error, :invalid_dto}

  defp safely(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :worker_lost}
  end
end
