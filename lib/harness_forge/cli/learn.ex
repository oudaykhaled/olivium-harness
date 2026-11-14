defmodule HarnessForge.CLI.Learn do
  @moduledoc """
  `learn ABSOLUTE_PATH --out FRESH_DIR --verify-image IMAGE [...]` (contract-v4.md 2.2).

  Exit status: 0 when a bundle was written, whatever the learner status; 1 for an I/O
  error, an invalid repository, or an `--out` that already exists; 2 for a usage error.
  The text summary has four lines with the fixed prefixes `AI learning:`, `Kept:`,
  `Dropped:` and `Bundle:`; the `Kept:` line ends with the proposed Claude Code skills
  and agents kept (`skills N kept, agents M kept`); `--json` prints the usual envelope.

  Cloud inference is off unless both `--allow-cloud` and `--key-file` are given. The key
  file is never opened here: its path is handed to Docker as a read-only bind mount of
  the meter container. `--mock-plan` runs the scripted $0 learner against a mock meter
  and conflicts with `--allow-cloud`.
  """

  alias HarnessForge.Contracts
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Learning
  alias HarnessForge.Learning.Launcher

  @usage "learn ABSOLUTE_PATH --out FRESH_DIR --verify-image IMAGE " <>
           "[--allow-cloud --key-file PATH --model claude-haiku-5-5|claude-sonnet-5-5 --cap-usd 0.10] " <>
           "[--max-turns 15] [--meter-url URL --network NAME | --meter-image TAG] " <>
           "[--learner-image TAG] [--mock-plan PATH] [--json]"

  @switches [
    out: :string,
    verify_image: :string,
    allow_cloud: :boolean,
    key_file: :string,
    model: :string,
    cap_usd: :string,
    max_turns: :string,
    meter_url: :string,
    network: :string,
    meter_image: :string,
    learner_image: :string,
    mock_plan: :string,
    json: :boolean
  ]
  @models ~w(claude-haiku-5-5 claude-sonnet-5-5)
  @max_cap_nanousd 5_000_000_000
  @plan_limit 512 * 1024
  @meter_url ~r/\Ahttp:\/\/[A-Za-z0-9][A-Za-z0-9.-]{0,62}(?::[0-9]{1,5})?\/run\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  @spec usage() :: String.t()
  def usage, do: @usage

  @doc "Entry point for `bin/harnessforge learn ...`: prints the result and sets the exit status."
  @spec main([String.t()]) :: no_return() | :ok
  def main(args) do
    json? = json?(args)

    case run(args) do
      {:ok, value} ->
        IO.puts(
          if json?, do: Jason.encode!(%{"ok" => true, "result" => value}), else: summary(value)
        )

      {:error, %Error{} = error} ->
        failure =
          %{"ok" => false, "error" => error.code, "message" => error.message}
          |> then(
            &if(error.details in [nil, []], do: &1, else: Map.put(&1, "details", error.details))
          )

        IO.puts(
          :stderr,
          if(json?, do: Jason.encode!(failure), else: "error: #{error.code}: #{error.message}")
        )

        System.halt(if error.code == "invalid_arguments", do: 2, else: 1)
    end
  end

  @doc "Parse and run; `{:ok, summary}` or `{:error, %Error{}}` (code `invalid_arguments` is a usage error)."
  @spec run([String.t()]) :: {:ok, map()} | {:error, Error.t()}
  def run(args) do
    with {:ok, path, options} <- parse(args),
         {:ok, opts} <- options(options),
         {:ok, root} <- repository(path) do
      Learning.learn(root, Path.expand(options[:out]), opts)
    end
  end

  defp json?(args) do
    {options, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(options, :json, false)
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: @switches) do
      {options, [path], []} ->
        cond do
          repeated?(args) -> usage("Each option may be given once")
          not absolute?(path) -> usage("PATH must be an absolute path")
          true -> {:ok, path, options}
        end

      _ ->
        usage("Unexpected arguments")
    end
  end

  # OptionParser keeps only the last of a repeated switch, so count the raw words.
  defp repeated?(args) do
    @switches
    |> Keyword.keys()
    |> Enum.any?(fn name ->
      flag = "--" <> String.replace(Atom.to_string(name), "_", "-")
      negated = "--no-" <> String.replace(Atom.to_string(name), "_", "-")

      Enum.count(args, fn arg ->
        arg in [flag, negated] or String.starts_with?(arg, flag <> "=")
      end) > 1
    end)
  end

  defp options(options) do
    cloud? = Keyword.get(options, :allow_cloud, false)
    key = options[:key_file]
    plan = options[:mock_plan]

    cond do
      not absolute?(options[:out]) ->
        usage("--out FRESH_DIR is required and must be an absolute path")

      not Launcher.valid_image?(options[:verify_image]) ->
        usage("--verify-image IMAGE is required")

      cloud? and is_nil(key) ->
        usage("--allow-cloud needs --key-file PATH")

      not cloud? and not is_nil(key) ->
        usage("--key-file is used only with --allow-cloud")

      key && not key_path?(key) ->
        usage("--key-file must be an absolute path without commas")

      cloud? and not is_nil(plan) ->
        usage(
          "--mock-plan runs the scripted $0 learner and cannot be combined with --allow-cloud"
        )

      options[:model] && options[:model] not in @models ->
        usage("--model must be one of #{Enum.join(@models, ", ")}")

      is_nil(options[:meter_url]) != is_nil(options[:network]) ->
        usage("--meter-url and --network go together")

      options[:meter_url] && options[:meter_image] ->
        usage("Give --meter-url with --network, or --meter-image, not both")

      options[:meter_url] && not Regex.match?(@meter_url, options[:meter_url]) ->
        usage("--meter-url must look like http://meter:8080/run/RUN_ID")

      options[:network] && not Launcher.valid_name?(options[:network]) ->
        usage("--network must be a Docker network name")

      options[:meter_image] && not Launcher.valid_image?(options[:meter_image]) ->
        usage("--meter-image must be an image reference")

      options[:learner_image] && not Launcher.valid_image?(options[:learner_image]) ->
        usage("--learner-image must be an image reference")

      true ->
        with {:ok, cap} <- cap(options[:cap_usd], options[:model]),
             {:ok, turns} <- turns(options[:max_turns]),
             {:ok, plan_bytes} <- plan(plan) do
          meter =
            cond do
              options[:meter_url] -> {:url, options[:meter_url], options[:network]}
              options[:meter_image] -> {:image, options[:meter_image]}
              true -> nil
            end

          {:ok,
           [
             verify_image: options[:verify_image],
             allow_cloud: cloud?,
             key_file: key,
             model: options[:model] || "claude-haiku-5-5",
             cap_nanousd: cap,
             max_turns: turns,
             meter: meter,
             learner_image: options[:learner_image],
             mock_plan: plan_bytes
           ]}
        end
    end
  end

  defp absolute?(path) do
    is_binary(path) and String.valid?(path) and byte_size(path) <= 4096 and
      not String.contains?(path, <<0>>) and Path.type(path) == :absolute
  end

  defp key_path?(path) do
    absolute?(path) and not String.contains?(path, [",", "\n", "\r", "="])
  end

  defp cap(nil, model), do: {:ok, Learning.default_cap(model)}

  defp cap(text, _model) do
    case Regex.run(~r/\A([0-9]{1,2})(?:\.([0-9]{1,9}))?\z/, text) do
      [_, whole] ->
        bounded_cap(String.to_integer(whole) * 1_000_000_000)

      [_, whole, frac] ->
        bounded_cap(
          String.to_integer(whole) * 1_000_000_000 +
            String.to_integer(String.pad_trailing(frac, 9, "0"))
        )

      _ ->
        usage("--cap-usd must be a dollar amount such as 0.10")
    end
  end

  defp bounded_cap(nanos) when nanos > 0 and nanos <= @max_cap_nanousd, do: {:ok, nanos}
  defp bounded_cap(_), do: usage("--cap-usd must be above 0 and at most 5.00")

  defp turns(nil), do: {:ok, 15}

  defp turns(text) do
    case Integer.parse(text) do
      {n, ""} when n in 1..50 -> {:ok, n}
      _ -> usage("--max-turns must be a whole number from 1 to 50")
    end
  end

  defp plan(nil), do: {:ok, nil}

  defp plan(path) do
    full = Path.expand(path)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @plan_limit <-
           File.lstat(full),
         {:ok, bytes} <- File.read(full),
         {:ok, %{"steps" => steps}} when is_list(steps) <- Contracts.decode_json(bytes) do
      {:ok, bytes}
    else
      _ ->
        {:error,
         %Error{
           code: "invalid_mock_plan",
           message: "--mock-plan must be a JSON file of at most 512 KB with a steps list"
         }}
    end
  end

  defp repository(path) do
    with {:ok, root} <- HarnessForge.Analyzers.Git.real_directory(path) do
      case HarnessForge.Analyzers.Git.availability(root) do
        %{"status" => "available"} ->
          {:ok, root}

        %{"reason" => "not_a_repository"} ->
          {:error, %Error{code: "not_a_git_repository", message: "PATH is not a git repository"}}

        %{"reason" => reason} ->
          {:error,
           %Error{
             code: "git_unavailable",
             message: "git cannot be used for this repository",
             details: [reason]
           }}
      end
    end
  end

  defp usage(message) do
    {:error, %Error{code: "invalid_arguments", message: "#{message}. Usage: #{@usage}"}}
  end

  # Summary --------------------------------------------------------------------------------

  @doc "The four-line text summary."
  @spec summary(map()) :: String.t()
  def summary(value) do
    Enum.join(
      [learning_line(value), kept_line(value), dropped_line(value), bundle_line(value)],
      "\n"
    )
  end

  defp learning_line(%{"learner" => learner}) do
    numbers =
      "#{learner["model"]}, #{dollars(learner["cost_nanousd"])}, " <>
        "#{delimited(total_tokens(learner["tokens"]))} tokens, #{learner["requests"]} requests"

    case {learner["status"], learner["status_reason"]} do
      {"ok", _} ->
        "AI learning: ok (#{numbers})"

      {"mock", _} ->
        "AI learning: mock (#{numbers}; scripted $0 learner, not model output)"

      {"failed", _} ->
        "AI learning: failed (#{learner["status_reason"]}; #{numbers}): the learner's output was " <>
          "discarded; the bundle keeps verified commands and rewrites from the analyzer only"

      {"unavailable", "cloud_not_allowed"} ->
        "AI learning: unavailable (cloud_not_allowed): no model ran, so the bundle has no " <>
          "concepts, pitfalls, skills or agents, only verified commands and rewrites from the analyzer. " <>
          "Add --allow-cloud --key-file PATH to run the learner"

      {"unavailable", reason} ->
        "AI learning: unavailable (#{reason}): the learner could not start; " <>
          "the bundle keeps verified commands and rewrites from the analyzer only"
    end
  end

  defp kept_line(%{"kept" => kept, "verification" => verification}) do
    counts =
      "#{kept["concepts"]} concepts, #{kept["pitfalls"]} pitfalls, " <>
        "#{kept["commands"]} commands, #{kept["rewrites"]} rewrites; " <>
        "skills #{kept["skills"] || 0} kept, agents #{kept["agents"] || 0} kept"

    case verification["status"] do
      "ok" ->
        "Kept: #{counts} (verified in #{verification["image"]}, network none)"

      _ ->
        "Kept: #{counts} (verification unavailable: #{verification["status_reason"]}; " <>
          "every command and rewrite dropped as not_verified)"
    end
  end

  defp dropped_line(%{"dropped" => reasons, "dropped_items" => total} = value) do
    detail =
      reasons
      |> Enum.sort()
      |> Enum.map_join(", ", fn {reason, n} -> "#{reason} #{n}" end)

    kinds = value["dropped_kinds"] || %{}

    native =
      if Map.has_key?(kinds, "skill") or Map.has_key?(kinds, "agent"),
        do: "; skills #{kinds["skill"] || 0}, agents #{kinds["agent"] || 0}",
        else: ""

    if total == 0, do: "Dropped: 0", else: "Dropped: #{total} (#{detail}#{native})"
  end

  defp bundle_line(value) do
    "Bundle: #{value["bundle"]} (sha256 #{value["sha256"]}; report #{value["report"]})"
  end

  defp total_tokens(tokens) when is_map(tokens),
    do: Enum.reduce(~w(input output cache_read cache_write), 0, &(&2 + (tokens[&1] || 0)))

  defp total_tokens(_), do: 0

  @doc "Nanodollars as `$d.dddd`, rounded up so a nonzero cost never shows as zero."
  @spec dollars(non_neg_integer()) :: String.t()
  def dollars(nanos) do
    tenths_of_cents = div(nanos + 99_999, 100_000)
    whole = div(tenths_of_cents, 10_000)
    frac = tenths_of_cents |> rem(10_000) |> Integer.to_string() |> String.pad_leading(4, "0")
    "$#{whole}.#{frac}"
  end

  defp delimited(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
