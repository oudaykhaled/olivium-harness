# HarnessForge pipeline benchmark.
#
# Usage (from the project root, dev environment already compiled):
#
#   BENCH_OUT=DIR HARNESSFORGE_WORKSPACE=/absolute/fresh/workspace mix run bench/pipeline.exs
#
# `mix run` starts the application, so the workspace named by HARNESSFORGE_WORKSPACE
# is locked and migrated before this script runs. Use a FRESH, disposable workspace:
# the script loads the synthetic demo fixture, approves its two ordinary claims,
# builds/exports artifacts and imports a Markdown corpus into it.
#
# Environment variables:
#   HARNESSFORGE_WORKSPACE  required. Absolute path without symlinked ancestors.
#                           Never point it at a workspace you care about.
#   BENCH_OUT               evidence directory; defaults to docs/benchmarks/<today>/pipeline.
#                           Receives results.json and pipeline.log (all raw output).
#   BENCH_CORPUS_SRC        directory whose .md/.markdown/.txt files form the import corpus
#                           (default: docs/archive under the project root).
#   BENCH_CORPUS            directory where the bounded corpus copy is assembled
#                           (default: <workspace parent>/bench-corpus; recreated).
#   BENCH_EXPORT_DIR        parent directory for fresh export targets
#                           (default: <workspace parent>/bench-export; recreated).
#   BENCH_MAX_FILES         corpus file cap (default 400; importer hard limit is 500).
#   BENCH_MAX_TOTAL_BYTES   corpus byte cap (default 15 MiB; importer hard limit is 16 MiB).
#   BENCH_SKIP_SHELL=1      skip step 1 (nested `mix run` / `bin/harnessforge status` timings).
#
# Every step records its error string and the run continues with the next step.
# All in-process timings use :timer.tc; shell timings use /usr/bin/time -p.

defmodule Bench.Pipeline do
  @moduledoc false

  alias HarnessForge.{Compiler, Contracts, Decisions, Demo, Evidence, Harnesses, Repo}
  alias HarnessForge.Evidence.{LocalImport, Store}

  @approve_texts [
    "Exported Go functions require table-driven tests covering empty input and boundary values.",
    "Changes must preserve UTF-8 text and use the Go standard library unless a reviewer approves a dependency."
  ]

  # OpenCode accepts "unqualified" or any 1.x semver (lib/harness_forge/adapters/opencode.ex);
  # Codex accepts "unqualified" or "0.156.0"; Claude Code accepts "unqualified" or "2.1.311".
  @runtimes [
    {"opencode", "unqualified"},
    {"codex", "0.156.0"},
    {"claude_code", "2.1.311"}
  ]

  @compile_sizes_requested [10, 100, 1000]
  @compile_repeats 5
  @rebuilds 5
  @search_words ~w(verification coordination ticket connector evidence workspace release harness claim operator)
  @search_queries 50
  @mib 1_048_576

  def main do
    started = DateTime.utc_now()
    project = File.cwd!()
    workspace = System.get_env("HARNESSFORGE_WORKSPACE")

    if is_nil(workspace) or workspace == "" do
      IO.puts(:stderr, "HARNESSFORGE_WORKSPACE must name a fresh disposable workspace; aborting.")
      System.halt(2)
    end

    workspace = Path.expand(workspace)
    out = Path.expand(System.get_env("BENCH_OUT") || default_out(project))
    File.mkdir_p!(out)
    Process.put(:bench_log, Path.join(out, "pipeline.log"))
    File.write!(Process.get(:bench_log), "")

    log("harnessforge pipeline benchmark")
    log("started_at=#{DateTime.to_iso8601(started)} project=#{project}")
    log("workspace=#{workspace} evidence_dir=#{out}")

    ctx = %{
      project: project,
      workspace: workspace,
      out: out,
      commands: [
        %{
          "step" => "invocation",
          "command" =>
            "BENCH_OUT=#{out} HARNESSFORGE_WORKSPACE=#{workspace} mix run bench/pipeline.exs"
        }
      ]
    }

    steps = [
      {"1_beam_boot", "BEAM boot baseline from the shell", &step_beam_boot/1},
      {"2_demo_load", "Demo.load/0 on the fresh workspace", &step_demo/1},
      {"3_decisions", "Approve the two ordinary demo claims", &step_decisions/1},
      {"4_build", "Harnesses.build/1 per runtime", &step_build/1},
      {"5_determinism", "Rebuild each runtime #{@rebuilds} more times", &step_determinism/1},
      {"6_compiler", "Compiler.compile/1 and verify/1 micro-benchmark", &step_compiler/1},
      {"7_export", "Harnesses.export/2 and verification", &step_export/1},
      {"8_import", "Local corpus connect + sync throughput", &step_import/1},
      {"9_search", "Evidence.search/1 latency", &step_search/1},
      {"10_footprint", "Memory, RSS and database size", &step_footprint/1},
      {"11_inventory", "CLI.run([\"inventory\"])", &step_inventory/1}
    ]

    {results, ctx} =
      Enum.reduce(steps, {%{}, ctx}, fn {key, title, fun}, {acc, ctx} ->
        log("")
        log("== #{key}: #{title}")
        {value, ctx} = run_step(fun, ctx)
        log(pretty(value))
        {Map.put(acc, key, value), ctx}
      end)

    ended = DateTime.utc_now()

    report = %{
      "benchmark" => "harnessforge-pipeline",
      "script" => "bench/pipeline.exs",
      "started_at" => DateTime.to_iso8601(started),
      "ended_at" => DateTime.to_iso8601(ended),
      "duration_s" => round3(DateTime.diff(ended, started, :millisecond) / 1000),
      "machine" => machine(),
      "commit" => commit(ctx.project),
      "git_dirty_entries" => git_dirty(ctx.project),
      "mix_env" => Atom.to_string(Mix.env()),
      "workspace" => ctx.workspace,
      "evidence_dir" => ctx.out,
      "commands" => ctx.commands,
      "artifact_digests" => Map.get(ctx, :digests, %{}),
      "caveats" => caveats(ctx),
      "steps" => results
    }

    path = Path.join(ctx.out, "results.json")
    File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
    log("")
    log("results written to #{path}")
    summary(report)
  end

  # ---------------------------------------------------------------- steps

  defp step_beam_boot(ctx) do
    if System.get_env("BENCH_SKIP_SHELL") == "1" do
      {%{"status" => "skipped", "reason" => "BENCH_SKIP_SHELL=1"}, ctx}
    else
      # The running application owns ctx.workspace, so the nested processes get a
      # sibling workspace of their own (one owning OS process per workspace).
      cli_workspace = ctx.workspace <> "-cli"
      File.rm_rf!(cli_workspace)
      File.mkdir_p!(cli_workspace)

      env = [
        {"HARNESSFORGE_WORKSPACE", cli_workspace},
        {"MIX_ENV", Atom.to_string(Mix.env())},
        {"PHX_SERVER", nil}
      ]

      commands = [
        {"mix_run_ok", ["mix", "run", "-e", ":ok"]},
        {"harnessforge_status", ["bin/harnessforge", "status"]},
        {"mix_run_no_start_ok", ["mix", "run", "--no-start", "-e", ":ok"]}
      ]

      measured =
        Map.new(commands, fn {label, argv} ->
          {label, shell_timing(label, argv, env, ctx.project)}
        end)

      ctx =
        Enum.reduce(commands, ctx, fn {label, argv}, ctx ->
          record_command(ctx, "1_beam_boot/#{label}", [
            "cd #{ctx.project} &&",
            "HARNESSFORGE_WORKSPACE=#{cli_workspace} MIX_ENV=#{Mix.env()} /usr/bin/time -p" | argv
          ])
        end)

      {Map.merge(measured, %{
         "cli_workspace" => cli_workspace,
         "note" =>
           "Measured from the shell with /usr/bin/time -p (real seconds) in a nested OS process; " <>
             "first invocation after creating the sibling workspace is a warm-up (migrations) and is reported separately. " <>
             "mix run -e :ok and bin/harnessforge status both boot the BEAM, load the Mix project and start the application; " <>
             "mix run --no-start -e :ok isolates BEAM + Mix boot."
       }), ctx}
    end
  end

  defp shell_timing(label, argv, env, project) do
    if File.exists?("/usr/bin/time") do
      run = fn ->
        {wall_ms, {output, status}} =
          timed(fn ->
            System.cmd("/usr/bin/time", ["-p" | argv],
              cd: project,
              env: env,
              stderr_to_stdout: true
            )
          end)

        log("$ /usr/bin/time -p #{Enum.join(argv, " ")}  (exit #{status})")
        log(String.trim_trailing(output))
        real = parse_time_p(output, "real")

        %{
          "exit_status" => status,
          "real_s" => real,
          "user_s" => parse_time_p(output, "user"),
          "sys_s" => parse_time_p(output, "sys"),
          "wrapper_wall_ms" => round3(wall_ms)
        }
      end

      warmup = run.()
      samples = Enum.map(1..3, fn _ -> run.() end)
      reals = samples |> Enum.map(& &1["real_s"]) |> Enum.reject(&is_nil/1)
      failures = Enum.count(samples, &(&1["exit_status"] != 0 or is_nil(&1["real_s"])))

      base = %{
        "label" => label,
        "argv" => argv,
        "warmup" => warmup,
        "samples" => samples,
        "failed_runs" => failures
      }

      if reals == [] do
        Map.put(base, "error", "no successful timing sample")
      else
        sorted = Enum.sort(reals)

        Map.merge(base, %{
          "runs" => length(reals),
          "median_real_s" => round3(median(sorted)),
          "min_real_s" => round3(hd(sorted)),
          "max_real_s" => round3(List.last(sorted))
        })
      end
    else
      %{"label" => label, "argv" => argv, "error" => "/usr/bin/time not found"}
    end
  end

  defp parse_time_p(output, field) do
    case Regex.run(~r/^#{field}\s+([0-9]+(?:\.[0-9]+)?)/m, output) do
      [_, value] ->
        String.to_float(if(String.contains?(value, "."), do: value, else: value <> ".0"))

      _ ->
        nil
    end
  end

  defp step_demo(ctx) do
    revisions_before = count(HarnessForge.Evidence.Revision)
    {ms, result} = timed(fn -> Demo.load() end)
    log("Demo.load/0 -> #{inspect(elem(result, 0))} in #{round3(ms)} ms")
    {:ok, sources} = Evidence.list_sources()
    {:ok, claims} = Evidence.list_claims()
    revisions_after = count(HarnessForge.Evidence.Revision)

    # Demo.load/0 is idempotent; later calls take the "already loaded" path and
    # are reported separately, never mixed with the first (real) load.
    reruns =
      Enum.map(1..2, fn _ ->
        {ms, rerun} = timed(fn -> Demo.load() end)
        %{"ms" => round3(ms), "ok" => match?({:ok, _}, rerun)}
      end)

    value = %{
      "first_load_ms" => round3(ms),
      "ok" => match?({:ok, _}, result),
      "result" => result_payload(result),
      "sources" => length(sources),
      "claims" => length(claims),
      "revisions_created" => revisions_after - revisions_before,
      "revisions_total" => revisions_after,
      "claim_statuses" => Enum.frequencies(Enum.map(claims, & &1["status"])),
      "idempotent_reruns" => reruns
    }

    {value, ctx}
  end

  defp step_decisions(ctx) do
    {:ok, claims} = Evidence.list_claims()
    selected = Enum.filter(claims, &(&1["text"] in @approve_texts))

    if length(selected) != 2 do
      raise "expected exactly 2 ordinary demo claims, found #{length(selected)}"
    end

    decisions =
      Enum.map(selected, fn claim ->
        {ms, result} =
          timed(fn ->
            Decisions.decide(claim["id"], %{
              "actor" => "bench-pipeline",
              "decision" => "approve",
              "expected_revision_hash" => claim["revision_hash"]
            })
          end)

        %{
          "claim_id" => claim["id"],
          "revision_hash" => claim["revision_hash"],
          "ms" => round3(ms),
          "ok" => match?({:ok, _}, result),
          "status_after" =>
            case result do
              {:ok, decided} -> decided["status"]
              {:error, reason} -> "error: " <> inspect(reason)
            end
        }
      end)

    {:ok, approved} = Evidence.approved_claims()
    {:ok, all} = Evidence.list_claims()
    undecided = Enum.filter(all, &(&1["text"] not in @approve_texts))

    value = %{
      "decisions" => decisions,
      "decision_ms" => Enum.map(decisions, & &1["ms"]),
      "approved_claims_after" => length(approved),
      "untouched_claims" =>
        Enum.map(
          undecided,
          &%{"status" => &1["status"], "text_prefix" => String.slice(&1["text"], 0, 32)}
        ),
      "note" =>
        "Each decision is append-only and can run only once per claim revision, so no repetition is possible; " <>
          "the deliberately malicious third demo claim is never decided."
    }

    {value, ctx}
  end

  defp step_build(ctx) do
    {builds, ctx} =
      Enum.reduce(@runtimes, {[], ctx}, fn {runtime, version}, {acc, ctx} ->
        {ms, result} = timed(fn -> build(runtime, version) end)

        case result do
          {:ok, artifact} ->
            files = artifact["files"]
            bytes = files |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

            entry = %{
              "runtime" => runtime,
              "runtime_version" => version,
              "first_build_ms" => round3(ms),
              "files" => map_size(files),
              "bytes" => bytes,
              "digest" => artifact["digest"],
              "file_list" => files |> Map.keys() |> Enum.sort(),
              "capabilities" => length(artifact["capabilities"] || []),
              "diagnostics" => length(artifact["diagnostics"] || [])
            }

            log(
              "build #{runtime} #{version}: #{round3(ms)} ms, #{map_size(files)} files, #{bytes} bytes, digest #{artifact["digest"]}"
            )

            ctx =
              ctx
              |> Map.update(:artifacts, %{runtime => artifact}, &Map.put(&1, runtime, artifact))
              |> Map.update(
                :digests,
                %{runtime => artifact["digest"]},
                &Map.put(&1, runtime, artifact["digest"])
              )

            {[entry | acc], ctx}

          {:error, reason} ->
            log("build #{runtime} #{version} failed: #{inspect(reason)}")

            {[
               %{
                 "runtime" => runtime,
                 "runtime_version" => version,
                 "first_build_ms" => round3(ms),
                 "error" => inspect(reason)
               }
               | acc
             ], ctx}
        end
      end)

    {%{
       "builds" => Enum.reverse(builds),
       "note" =>
         "The first build of each runtime compiles, verifies and publishes the content-addressed artifact to disk; " <>
           "repeated builds (step 5) find the existing digest and re-verify it instead of writing."
     }, ctx}
  end

  defp step_determinism(ctx) do
    rows =
      Enum.map(@runtimes, fn {runtime, version} ->
        first = get_in(ctx, [:digests, runtime])

        {samples, digests} =
          Enum.map(1..@rebuilds, fn _ ->
            {ms, result} = timed(fn -> build(runtime, version) end)

            case result do
              {:ok, artifact} -> {ms, artifact["digest"]}
              {:error, reason} -> {ms, "error: " <> inspect(reason)}
            end
          end)
          |> Enum.unzip()

        all = if first, do: [first | digests], else: digests
        identical = Enum.count(all, &(&1 == hd(all)))

        %{
          "runtime" => runtime,
          "runtime_version" => version,
          "first_digest" => first,
          "rebuild_digests" => digests,
          "identical" => identical,
          "total" => length(all),
          "deterministic" => identical == length(all) and not is_nil(first),
          "rebuild" => stats(samples)
        }
      end)

    {%{"runtimes" => rows, "all_deterministic" => Enum.all?(rows, & &1["deterministic"])}, ctx}
  end

  defp step_compiler(ctx) do
    artifact = get_in(ctx, [:artifacts, "opencode"]) || raise "no opencode artifact from step 4"
    spec = artifact["spec"]
    template = hd(spec["spec"]["rules"])

    max_rules =
      case get_in(Contracts.schema(), ["properties", "spec", "properties", "rules", "maxItems"]) do
        n when is_integer(n) -> n
        _ -> nil
      end

    sizes =
      @compile_sizes_requested
      |> Enum.map(fn n -> if max_rules && n > max_rules, do: max_rules, else: n end)
      |> Enum.uniq()

    by_size =
      Enum.map(sizes, fn n ->
        bench_spec = replicate_rules(spec, template, n)
        {ms_first, first} = timed(fn -> Compiler.compile(bench_spec) end)

        rest =
          Enum.map(2..@compile_repeats, fn _ ->
            {ms, result} = timed(fn -> Compiler.compile(bench_spec) end)
            {ms, result}
          end)

        samples = [ms_first | Enum.map(rest, &elem(&1, 0))]
        results = [first | Enum.map(rest, &elem(&1, 1))]
        ok = Enum.count(results, &match?({:ok, _}, &1))
        st = stats(samples)

        error =
          case Enum.find(results, &(not match?({:ok, _}, &1))) do
            nil -> nil
            {:error, reason} -> inspect(reason) |> String.slice(0, 2000)
          end

        log("compile #{n} rules: median #{st["median_ms"]} ms (#{ok}/#{@compile_repeats} ok)")

        %{
          "rules" => n,
          "ok_runs" => ok,
          "compile" => st,
          "rules_per_second" =>
            if(st["median_ms"] > 0, do: round3(n / (st["median_ms"] / 1000)), else: nil),
          "spec_canonical_bytes" => byte_size(Contracts.canonical_json(bench_spec)),
          "output_files" =>
            case first do
              {:ok, out} -> map_size(out["files"])
              _ -> nil
            end,
          "output_bytes" =>
            case first do
              {:ok, out} -> out["files"] |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()
              _ -> nil
            end,
          "error" => error
        }
      end)

    verify_samples =
      Enum.map(1..@compile_repeats, fn _ ->
        {ms, result} = timed(fn -> Compiler.verify(artifact) end)
        {ms, result == :ok}
      end)

    value = %{
      "runtime" => "opencode",
      "schema_max_rules" => max_rules,
      "sizes_requested" => @compile_sizes_requested,
      "sizes_used" => sizes,
      "size_note" =>
        if(Enum.any?(@compile_sizes_requested, &(max_rules && &1 > max_rules)),
          do:
            "1000 rules exceeds the v1alpha1 schema limit (spec.rules maxItems = #{max_rules}); the largest allowed size #{max_rules} was used instead.",
          else: "all requested sizes are within the schema limit"
        ),
      "repeats_per_size" => @compile_repeats,
      "by_size" => by_size,
      "verify_real_artifact" =>
        Map.merge(stats(Enum.map(verify_samples, &elem(&1, 0))), %{
          "ok_runs" => Enum.count(verify_samples, &elem(&1, 1)),
          "artifact_rules" => length(spec["spec"]["rules"])
        }),
      "method" =>
        "Rules replicate the first real rule of the opencode artifact spec with unique synthetic UUIDs and statements; " <>
          "evidence citations, revision hash and goal reference are kept so semantic checks (byte ranges, goal ids, duplicate ids) pass."
    }

    {value, ctx}
  end

  defp replicate_rules(spec, template, n) do
    rules =
      Enum.map(1..n, fn i ->
        template
        |> Map.put("id", bench_uuid(i))
        |> Map.put("statement", "#{template["statement"]} Benchmark replica #{i}.")
      end)

    put_in(spec, ["spec", "rules"], rules)
  end

  defp bench_uuid(i) do
    suffix = i |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    "0000000b-0000-4000-8000-" <> suffix
  end

  defp step_export(ctx) do
    digest = get_in(ctx, [:digests, "opencode"]) || raise "no opencode digest from step 4"

    parent =
      Path.expand(
        System.get_env("BENCH_EXPORT_DIR") ||
          Path.join(Path.dirname(ctx.workspace), "bench-export")
      )

    File.rm_rf!(parent)
    File.mkdir_p!(parent)

    exports =
      Enum.map(1..3, fn i ->
        target = Path.join(parent, "run-#{i}")
        {ms, result} = timed(fn -> Harnesses.export(digest, target) end)

        case result do
          {:ok, location} ->
            {files, bytes} = tree_size(target)

            %{
              "target" => target,
              "ms" => round3(ms),
              "files_on_disk" => files,
              "bytes_on_disk" => bytes,
              "path" => location["path"]
            }

          {:error, reason} ->
            %{"target" => target, "ms" => round3(ms), "error" => inspect(reason)}
        end
      end)

    {:ok, artifact} = Harnesses.get(digest)

    verify_samples =
      Enum.map(1..3, fn _ ->
        {ms, result} = timed(fn -> Compiler.verify(artifact) end)
        {ms, result == :ok}
      end)

    first_target = Path.join(parent, "run-1")

    matching =
      Enum.count(artifact["files"], fn {relative, bytes} ->
        File.read(Path.join(first_target, relative)) == {:ok, bytes}
      end)

    ok_exports = Enum.filter(exports, &Map.has_key?(&1, "files_on_disk"))

    value = %{
      "digest" => digest,
      "export_parent" => parent,
      "exports" => exports,
      "export" => if(ok_exports == [], do: nil, else: stats(Enum.map(ok_exports, & &1["ms"]))),
      "files_on_disk" => List.first(ok_exports)["files_on_disk"],
      "bytes_on_disk" => List.first(ok_exports)["bytes_on_disk"],
      "artifact_files" => map_size(artifact["files"]),
      "exported_files_matching_artifact_bytes" => matching,
      "verify" =>
        Map.put(
          stats(Enum.map(verify_samples, &elem(&1, 0))),
          "ok_runs",
          Enum.count(verify_samples, &elem(&1, 1))
        )
    }

    {value, ctx}
  end

  defp step_import(ctx) do
    source_dir =
      Path.expand(System.get_env("BENCH_CORPUS_SRC") || Path.join(ctx.project, "docs/archive"))

    corpus_dir =
      Path.expand(
        System.get_env("BENCH_CORPUS") || Path.join(Path.dirname(ctx.workspace), "bench-corpus")
      )

    max_files = String.to_integer(System.get_env("BENCH_MAX_FILES") || "400")

    max_total =
      String.to_integer(System.get_env("BENCH_MAX_TOTAL_BYTES") || Integer.to_string(15 * @mib))

    corpus = assemble_corpus(source_dir, corpus_dir, max_files, max_total)

    log(
      "corpus: #{corpus["files"]} files, #{corpus["bytes"]} bytes from #{source_dir} -> #{corpus_dir}"
    )

    {:ok, _} = LocalImport.approved_directory(corpus_dir)

    {connect_ms, connect_result} =
      timed(fn ->
        Evidence.connect(%{
          "provider" => "local",
          "name" => "Benchmark corpus",
          "directory" => corpus_dir
        })
      end)

    {:ok, connection} = connect_result

    revisions_before = count(HarnessForge.Evidence.Revision)
    sources_before = count(HarnessForge.Evidence.Source)
    {sync_ms, sync_result} = timed(fn -> Evidence.sync(connection["id"]) end)
    revisions_after = count(HarnessForge.Evidence.Revision)
    sources_after = count(HarnessForge.Evidence.Source)
    seconds = sync_ms / 1000

    resyncs =
      Enum.map(1..2, fn _ ->
        {ms, result} = timed(fn -> Evidence.sync(connection["id"]) end)
        %{"ms" => round3(ms), "result" => result_payload(result)}
      end)

    value = %{
      "corpus" => corpus,
      "connection_id" => connection["id"],
      "connect_ms" => round3(connect_ms),
      "sync_ok" => match?({:ok, _}, sync_result),
      "sync_result" => result_payload(sync_result),
      "sync_seconds" => round3(seconds),
      "files_per_second" => if(seconds > 0, do: round3(corpus["files"] / seconds), else: nil),
      "mb_per_second" =>
        if(seconds > 0, do: round3(corpus["bytes"] / 1_000_000 / seconds), else: nil),
      "revisions_created" => revisions_after - revisions_before,
      "sources_created" => sources_after - sources_before,
      "resync_unchanged" => resyncs,
      "note" =>
        "sync of a local connection re-reads every file inside one SQLite transaction (bodies + FTS5 index rows); " <>
          "MB are decimal megabytes (1e6 bytes). Re-syncs of the unchanged corpus are reported separately."
    }

    {value, Map.put(ctx, :corpus, corpus)}
  end

  defp assemble_corpus(source_dir, corpus_dir, max_files, max_total) do
    File.rm_rf!(corpus_dir)
    File.mkdir_p!(corpus_dir)

    candidates =
      source_dir
      |> Path.join("**/*.{md,markdown,txt}")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.flat_map(fn path ->
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular, size: size}} -> [{path, size}]
          _ -> []
        end
      end)

    {selected, skipped_large, bytes} =
      Enum.reduce(candidates, {[], 0, 0}, fn {path, size}, {acc, skipped, total} ->
        cond do
          size >= @mib -> {acc, skipped + 1, total}
          length(acc) >= max_files -> {acc, skipped, total}
          total + size > max_total -> {acc, skipped, total}
          true -> {[{path, size} | acc], skipped, total + size}
        end
      end)

    selected = Enum.reverse(selected)

    Enum.each(selected, fn {path, _} ->
      relative = Path.relative_to(path, source_dir)
      destination = Path.join(corpus_dir, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(path, destination)
    end)

    %{
      "source_dir" => source_dir,
      "corpus_dir" => corpus_dir,
      "candidates" => length(candidates),
      "files" => length(selected),
      "bytes" => bytes,
      "mib" => round3(bytes / @mib),
      "skipped_over_1mib" => skipped_large,
      "largest_file_bytes" => selected |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end),
      "limits" => %{
        "max_files" => max_files,
        "max_total_bytes" => max_total,
        "max_file_bytes" => @mib
      }
    }
  end

  defp step_search(ctx) do
    probes =
      Enum.map(@search_words, fn word ->
        {ms, result} = timed(fn -> Evidence.search(word) end)

        case result do
          {:ok, hits} -> %{"word" => word, "hits" => length(hits), "ms" => round3(ms)}
          {:error, reason} -> %{"word" => word, "error" => inspect(reason), "ms" => round3(ms)}
        end
      end)

    samples =
      Enum.map(0..(@search_queries - 1), fn i ->
        word = Enum.at(@search_words, rem(i, length(@search_words)))
        {ms, result} = timed(fn -> Evidence.search(word) end)
        hits = if match?({:ok, _}, result), do: length(elem(result, 1)), else: -1
        {ms, hits}
      end)

    sorted = samples |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    total_hits = samples |> Enum.map(&elem(&1, 1)) |> Enum.filter(&(&1 >= 0)) |> Enum.sum()

    value = %{
      "words" => @search_words,
      "probe_per_word" => probes,
      "queries" => @search_queries,
      "failed_queries" => Enum.count(samples, &(elem(&1, 1) < 0)),
      "p50_ms" => round3(percentile(sorted, 50)),
      "p95_ms" => round3(percentile(sorted, 95)),
      "max_ms" => round3(List.last(sorted)),
      "min_ms" => round3(hd(sorted)),
      "mean_ms" => round3(Enum.sum(sorted) / length(sorted)),
      "mean_hits_per_query" => round3(total_hits / @search_queries),
      "samples_ms" => Enum.map(samples, fn {ms, _} -> round3(ms) end),
      "note" =>
        "Evidence.search/1 runs an FTS5 MATCH (literal tokens, LIMIT 50) and then loads every hit as a source DTO including its current revision body; " <>
          "latency therefore includes result materialisation, not only the index lookup."
    }

    {value, ctx}
  end

  defp step_footprint(ctx) do
    :erlang.garbage_collect()
    total = :erlang.memory(:total)

    rss_kb =
      case System.cmd("ps", ["-o", "rss=", "-p", System.pid()], stderr_to_stdout: true) do
        {out, 0} ->
          case Integer.parse(String.trim(out)) do
            {kb, _} -> kb
            :error -> nil
          end

        _ ->
          nil
      end

    db = Path.join(ctx.workspace, "data.sqlite3")

    db_files =
      Map.new([db, db <> "-wal", db <> "-shm"], fn path ->
        {Path.basename(path),
         case File.stat(path) do
           {:ok, %File.Stat{size: size}} -> size
           _ -> nil
         end}
      end)

    value = %{
      "erlang_memory_total_bytes" => total,
      "erlang_memory_total_mb" => round3(total / 1_000_000),
      "erlang_memory" => Map.new(:erlang.memory(), fn {k, v} -> {Atom.to_string(k), v} end),
      "os_pid" => System.pid(),
      "rss_kb" => rss_kb,
      "rss_mb" => if(rss_kb, do: round3(rss_kb * 1024 / 1_000_000), else: nil),
      "database_path" => db,
      "database_files_bytes" => db_files,
      "database_sqlite3_mb" =>
        if(db_files["data.sqlite3"], do: round3(db_files["data.sqlite3"] / 1_000_000), else: nil),
      "database_total_mb" =>
        round3(Enum.sum(Enum.map(Map.values(db_files), &(&1 || 0))) / 1_000_000),
      "schedulers_online" => System.schedulers_online(),
      "process_count" => :erlang.system_info(:process_count),
      "note" =>
        "Measured after step 9; MB are decimal megabytes (1e6 bytes); RSS from ps -o rss= (KiB)."
    }

    {value, ctx}
  end

  defp step_inventory(ctx) do
    {ms, result} = timed(fn -> HarnessForge.CLI.run(["inventory"]) end)

    value =
      case result do
        {:ok, inventory} ->
          %{"ms" => round3(ms), "ok" => true, "inventory" => inventory}

        {:error, reason} ->
          %{"ms" => round3(ms), "ok" => false, "error" => inspect(reason)}
      end

    {value, ctx}
  end

  # -------------------------------------------------------------- helpers

  defp build(runtime, version) do
    Harnesses.build(%{
      "name" => "bench-" <> String.replace(runtime, "_", "-"),
      "version" => "0.1.0",
      "runtime" => runtime,
      "runtime_version" => version
    })
  end

  defp run_step(fun, ctx) do
    try do
      fun.(ctx)
    rescue
      error ->
        message = Exception.format(:error, error, __STACKTRACE__) |> String.slice(0, 4000)
        log("STEP FAILED: " <> message)
        {%{"status" => "failed", "error" => message}, ctx}
    catch
      kind, reason ->
        message = Exception.format(kind, reason, __STACKTRACE__) |> String.slice(0, 4000)
        log("STEP FAILED: " <> message)
        {%{"status" => "failed", "error" => message}, ctx}
    end
  end

  defp record_command(ctx, step, parts) do
    Map.update!(ctx, :commands, &(&1 ++ [%{"step" => step, "command" => Enum.join(parts, " ")}]))
  end

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {us / 1000, result}
  end

  defp count(schema), do: Repo.aggregate(Store.scoped(schema), :count)

  defp tree_size(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce({0, 0}, fn path, {files, bytes} ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} -> {files + 1, bytes + size}
        _ -> {files, bytes}
      end
    end)
  end

  defp result_payload({:ok, value}), do: value
  defp result_payload({:error, reason}), do: %{"error" => inspect(reason)}
  defp result_payload(other), do: inspect(other)

  defp stats([]), do: %{"runs" => 0}

  defp stats(samples) do
    sorted = Enum.sort(samples)

    %{
      "runs" => length(sorted),
      "median_ms" => round3(median(sorted)),
      "min_ms" => round3(hd(sorted)),
      "max_ms" => round3(List.last(sorted)),
      "mean_ms" => round3(Enum.sum(sorted) / length(sorted)),
      "samples_ms" => Enum.map(samples, &round3/1)
    }
  end

  defp median(sorted) do
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)),
      else: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
  end

  defp percentile(sorted, p) do
    n = length(sorted)
    index = trunc(Float.ceil(p / 100 * n)) - 1
    Enum.at(sorted, max(0, min(n - 1, index)))
  end

  defp round3(nil), do: nil
  defp round3(value) when is_integer(value), do: value
  defp round3(value) when is_float(value), do: Float.round(value, 3)

  defp machine do
    %{
      "cpu" => sysctl("machdep.cpu.brand_string") || uname("-m"),
      "logical_cores" => System.schedulers_online(),
      "memory_bytes" => sysctl("hw.memsize") |> maybe_integer(),
      "os" => Atom.to_string(elem(:os.type(), 1)),
      "os_version" => cmd_out("sw_vers", ["-productVersion"]) || uname("-r"),
      "os_build" => cmd_out("sw_vers", ["-buildVersion"]),
      "kernel" => uname("-v"),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "erts" => List.to_string(:erlang.system_info(:version)),
      "node" => cmd_out("node", ["--version"]),
      "hostname_hash" =>
        :crypto.hash(:sha256, to_string(:net_adm.localhost()))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 12)
    }
  end

  defp commit(project) do
    case cmd_out("git", ["-C", project, "rev-parse", "HEAD"]) do
      nil -> "unknown"
      sha -> sha
    end
  end

  defp git_dirty(project) do
    case cmd_out("git", ["-C", project, "status", "--porcelain"]) do
      nil -> nil
      "" -> 0
      text -> text |> String.split("\n", trim: true) |> length()
    end
  end

  defp sysctl(key), do: cmd_out("sysctl", ["-n", key])
  defp uname(flag), do: cmd_out("uname", [flag])

  defp cmd_out(executable, args) do
    case System.find_executable(executable) do
      nil ->
        nil

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end
    end
  end

  defp maybe_integer(nil), do: nil

  defp maybe_integer(text) do
    case Integer.parse(text) do
      {value, _} -> value
      :error -> text
    end
  end

  defp caveats(ctx) do
    [
      "In-process numbers come from :timer.tc inside the same dev-mode BEAM (mix run, not a release) that runs the benchmark; the first call of each API includes module loading.",
      "Step 1 CLI timings include BEAM boot, Mix project loading and HarnessForge application start (workspace lock, SQLite open/migrations, Oban, endpoint without HTTP listener); they were spawned as nested OS processes from this script and measured with /usr/bin/time -p.",
      "Step 1 uses a sibling workspace (#{ctx.workspace}-cli) because the benchmark process owns #{ctx.workspace} and a workspace admits one owning OS process.",
      "Other processes on the machine (for this run: a second HarnessForge portal from a concurrent agent on PORT 8866 with its own workspace) add light background load; no isolation or CPU pinning was applied.",
      "Repeated builds re-verify an existing content-addressed artifact instead of writing it; only the first build per runtime includes publication to disk.",
      "Compiler sizes above the v1alpha1 schema limit for spec.rules are not representable; see steps.6_compiler.size_note.",
      "Evidence.search/1 latency includes loading every matching source with its revision body (up to 50 per query).",
      "Decisions and the first demo load cannot be repeated on the same workspace, so they are single measurements."
    ]
  end

  defp default_out(project) do
    today = Date.utc_today() |> Date.to_iso8601()
    Path.join([project, "docs/benchmarks", today, "pipeline"])
  end

  defp pretty(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(value, pretty: true, limit: :infinity)
    end
  end

  defp log(message) do
    IO.puts(message)
    stamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    File.write!(Process.get(:bench_log), "[#{stamp}] #{message}\n", [:append])
  end

  defp summary(report) do
    steps = report["steps"]
    boot = steps["1_beam_boot"] || %{}
    demo = steps["2_demo_load"] || %{}
    build = steps["4_build"] || %{}
    det = steps["5_determinism"] || %{}
    comp = steps["6_compiler"] || %{}
    exp = steps["7_export"] || %{}
    imp = steps["8_import"] || %{}
    search = steps["9_search"] || %{}
    foot = steps["10_footprint"] || %{}

    lines =
      [
        "",
        "================ HarnessForge pipeline benchmark summary ================",
        "commit #{report["commit"]}  duration #{report["duration_s"]} s  workspace #{report["workspace"]}",
        "1  mix run -e :ok           median #{get_in(boot, ["mix_run_ok", "median_real_s"])} s (min #{get_in(boot, ["mix_run_ok", "min_real_s"])}, max #{get_in(boot, ["mix_run_ok", "max_real_s"])})",
        "   bin/harnessforge status  median #{get_in(boot, ["harnessforge_status", "median_real_s"])} s (min #{get_in(boot, ["harnessforge_status", "min_real_s"])}, max #{get_in(boot, ["harnessforge_status", "max_real_s"])})",
        "   mix run --no-start       median #{get_in(boot, ["mix_run_no_start_ok", "median_real_s"])} s",
        "2  demo load                #{demo["first_load_ms"]} ms; sources #{demo["sources"]}, revisions #{demo["revisions_created"]}, claims #{demo["claims"]}",
        "3  decisions                #{inspect(get_in(steps, ["3_decisions", "decision_ms"]))} ms"
      ] ++
        Enum.map(build["builds"] || [], fn b ->
          "4  build #{b["runtime"]}#{String.duplicate(" ", max(1, 18 - String.length(b["runtime"] || "")))}#{b["first_build_ms"]} ms, #{b["files"]} files, #{b["bytes"]} bytes, #{b["digest"] || b["error"]}"
        end) ++
        Enum.map(det["runtimes"] || [], fn r ->
          "5  determinism #{r["runtime"]}: #{r["identical"]}/#{r["total"]} identical; rebuild median #{get_in(r, ["rebuild", "median_ms"])} ms"
        end) ++
        Enum.map(comp["by_size"] || [], fn s ->
          "6  compile #{s["rules"]} rules: median #{get_in(s, ["compile", "median_ms"])} ms, #{s["rules_per_second"]} rules/s"
        end) ++
        [
          "6  verify real artifact: median #{get_in(comp, ["verify_real_artifact", "median_ms"])} ms",
          "7  export                   median #{get_in(exp, ["export", "median_ms"])} ms, #{exp["files_on_disk"]} files, #{exp["bytes_on_disk"]} bytes on disk; verify median #{get_in(exp, ["verify", "median_ms"])} ms",
          "8  import                   #{get_in(imp, ["corpus", "files"])} files / #{get_in(imp, ["corpus", "bytes"])} bytes in #{imp["sync_seconds"]} s = #{imp["files_per_second"]} files/s, #{imp["mb_per_second"]} MB/s; revisions #{imp["revisions_created"]}",
          "9  search                   p50 #{search["p50_ms"]} ms, p95 #{search["p95_ms"]} ms, max #{search["max_ms"]} ms over #{search["queries"]} queries",
          "10 footprint                erlang #{foot["erlang_memory_total_mb"]} MB, RSS #{foot["rss_mb"]} MB, data.sqlite3 #{foot["database_sqlite3_mb"]} MB",
          "11 inventory                ok=#{get_in(steps, ["11_inventory", "ok"])}",
          "results: #{Path.join(report["evidence_dir"], "results.json")}",
          "=========================================================================="
        ]

    Enum.each(lines, &log/1)
  end
end

Bench.Pipeline.main()
