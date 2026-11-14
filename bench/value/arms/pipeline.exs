# Drives the real Olivium Harness pipeline for one task: connect the local
# Markdown directory, sync, propose claims, approve every proposal with valid
# citations, build for claude_code, export.
#
# Usage (from an app snapshot, with a fresh HARNESSFORGE_WORKSPACE):
#   mix run bench/value/arms/pipeline.exs CONFIG.json
#
# In "paid" mode claims come from the Anthropic provider through
# HarnessForge.Models.propose/2. In "rehearsal" mode that one step is replaced
# by a clearly marked fixture whose claims still pass the real validator and
# persistence; every other step is the real pipeline. The provider cannot be
# pointed at the mock meter: its endpoint is an exact allowlist.

alias HarnessForge.{Decisions, Evidence, Harnesses, Models}
alias HarnessForge.Models.Proposal

defmodule Bench.Pipeline do
  @credential_env "HARNESSFORGE_BENCH_ANTHROPIC_API_KEY"
  @fixture_prefix "REHEARSAL FIXTURE (not model output): "

  def run(config_path) do
    config = config_path |> File.read!() |> Jason.decode!()

    report =
      try do
        pipeline(config)
      rescue
        error -> %{"status" => "failed", "stage" => "exception", "error" => Exception.message(error)}
      catch
        kind, _ -> %{"status" => "failed", "stage" => "exception", "error" => to_string(kind)}
      end

    File.write!(config["result_path"], Jason.encode!(report))
    IO.puts("pipeline status: " <> report["status"])
  end

  defp pipeline(config) do
    with {:ok, conn} <-
           stage("connect", Evidence.connect(%{
             "provider" => "local",
             "name" => config["name"],
             "directory" => config["docs_dir"]
           })),
         {:ok, sync} <- stage("sync", Evidence.sync(conn["id"])),
         {:ok, sources} <- stage("sources", Evidence.list_sources()),
         selected = select_sources(sources, config["propose"]),
         {:ok, model_status} <- configure(config, selected),
         {:ok, proposals} <- propose_all(config, selected),
         {:ok, decisions} <- decide_all() do
      # Proposal outcomes and decisions are kept in a failed report too, so a
      # failure at build (for example no_approved_claims) shows which proposal
      # requests failed and with what error code.
      context = %{
        "proposals" => proposals,
        "claims_total" => decisions["total"],
        "approved" => decisions["approved"],
        "decide_errors" => decisions["errors"]
      }

      with {:ok, artifact} <- stage("build", build(config)),
           {:ok, exported} <-
             stage("export", Harnesses.export(artifact["digest"], config["export_dir"])) do
        Map.merge(context, %{
          "status" => "ok",
          "mode" => config["mode"],
          "sources_total" => length(sources),
          "sync" => Map.take(sync, ["imported", "unchanged", "deleted"]),
          "selected" => Enum.map(selected, & &1["external_id"]),
          "model_status" => model_status,
          "digest" => artifact["digest"],
          "export" =>
            exported |> Map.take(["target", "file_count"]) |> Map.put("root", config["export_dir"]),
          "usage" => usage(config)
        })
      else
        {:failed, report} -> report |> Map.merge(context) |> Map.put("usage", usage(config))
      end
    else
      {:failed, report} -> Map.put(report, "usage", usage(config))
    end
  end

  defp build(config) do
    Harnesses.build(%{
      "name" => config["name"],
      "version" => "0.1.0",
      "runtime" => "claude_code",
      "runtime_version" => config["runtime_version"]
    })
  end

  defp select_sources(sources, paths) do
    Enum.flat_map(paths, fn path ->
      case Enum.find(sources, &(&1["external_id"] == path)) do
        nil -> []
        source -> [source]
      end
    end)
  end

  defp configure(config, selected) do
    case Models.configure(%{
           "provider" => "anthropic",
           "endpoint" => "https://api.anthropic.com/v1",
           "model" => config["model"],
           "credential_env" => @credential_env,
           "input_microusd_per_million" => config["input_microusd_per_million"],
           "output_microusd_per_million" => config["output_microusd_per_million"],
           "cloud_consent" => %{
             "provider" => "anthropic",
             "endpoint" => "https://api.anthropic.com/v1",
             "source_ids" => Enum.map(selected, & &1["id"]),
             "data_categories" => ["source_body"]
           }
         }) do
      {:ok, _} ->
        status = Models.status()

        {:ok,
         %{
           "provider" => status["provider"],
           "model" => status["model"],
           "availability" => status["availability"],
           "reason" => status["reason"]
         }}

      {:error, reason} ->
        {:failed, %{"status" => "failed", "stage" => "configure", "error" => code(reason)}}
    end
  end

  defp propose_all(%{"mode" => "paid"} = config, selected) do
    {:ok, Enum.map(selected, &propose_paid(config, &1))}
  end

  defp propose_all(_config, selected), do: {:ok, Enum.map(selected, &propose_fixture/1)}

  defp propose_paid(config, source) do
    request_id = "bench-" <> Integer.to_string(:erlang.phash2({config["name"], source["id"]}))

    result =
      Models.propose(source["id"],
        run_id: config["ledger_run_id"],
        request_id: request_id,
        budget: config["budget"],
        max_output_tokens: config["max_output_tokens"],
        timeout: 60_000
      )

    case result do
      {:ok, response} ->
        %{"path" => source["external_id"], "status" => "ok", "claims" => length(response["claims"])}

      {:error, reason} ->
        %{"path" => source["external_id"], "status" => "error", "claims" => 0, "error" => code(reason)}
    end
  end

  defp propose_fixture(source) do
    {:ok, source} = Evidence.get_source(source["id"])
    claims = fixture_claims(source)

    with {:ok, validated} <- Proposal.validate(Jason.encode!(%{"claims" => claims}), source),
         {:ok, created} <- Proposal.persist(validated, source) do
      %{
        "path" => source["external_id"],
        "status" => "ok",
        "claims" => length(created),
        "rehearsal_fixture" => true
      }
    else
      {:error, reason} ->
        %{
          "path" => source["external_id"],
          "status" => "error",
          "claims" => 0,
          "error" => code(reason),
          "rehearsal_fixture" => true
        }
    end
  end

  defp fixture_claims(source) do
    revision = source["latest_revision"]
    body = revision["body"]

    {lines, _} =
      Enum.map_reduce(String.split(body, "\n"), 0, fn line, offset ->
        {{line, offset}, offset + byte_size(line) + 1}
      end)

    candidates =
      Enum.filter(lines, fn {line, _offset} ->
        trimmed = String.trim(line)
        String.length(trimmed) >= 30 and not String.starts_with?(trimmed, ["#", "```"])
      end)

    candidates =
      if candidates == [],
        do: Enum.filter(lines, fn {line, _} -> String.trim(line) != "" end),
        else: candidates

    candidates
    |> Enum.take(3)
    |> Enum.map(fn {line, offset} ->
      %{
        "text" => @fixture_prefix <> String.slice(line, 0, 300),
        "citations" => [
          %{
            "source_id" => source["id"],
            "revision_id" => revision["id"],
            "start_byte" => offset,
            "end_byte" => offset + byte_size(line),
            "snippet" => binary_part(body, offset, byte_size(line))
          }
        ]
      }
    end)
  end

  defp decide_all do
    with {:ok, claims} <- Evidence.list_claims() do
      proposed = Enum.filter(claims, &(&1["status"] == "proposed"))

      results =
        Enum.map(proposed, fn claim ->
          Decisions.decide(claim["id"], %{
            "actor" => "olivium-value-benchmark",
            "decision" => "approve",
            "expected_revision_hash" => claim["revision_hash"]
          })
        end)

      errors =
        results
        |> Enum.filter(&match?({:error, _}, &1))
        |> Enum.map(fn {:error, reason} -> code(reason) end)

      {:ok,
       %{
         "total" => length(proposed),
         "approved" => length(proposed) - length(errors),
         "errors" => errors
       }}
    end
  end

  defp usage(%{"mode" => "paid", "ledger_run_id" => run_id}) do
    case Models.list_requests(run_id) do
      {:ok, requests} ->
        Enum.map(requests, fn request ->
          Map.take(request, ~w(state usage_status billing_status input_tokens output_tokens
                               reserved_tokens reserved_estimated_microusd model))
        end)

      _ ->
        []
    end
  end

  defp usage(_), do: []

  defp stage(_name, {:ok, value}), do: {:ok, value}

  defp stage(name, {:error, reason}),
    do: {:failed, %{"status" => "failed", "stage" => name, "error" => code(reason)}}

  defp stage(name, other),
    do: {:failed, %{"status" => "failed", "stage" => name, "error" => inspect(other)}}

  defp code(%{code: code}) when is_binary(code), do: code
  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code(reason), do: inspect(reason)
end

[config_path] = System.argv()
Bench.Pipeline.run(config_path)
