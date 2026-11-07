defmodule HarnessForge.Execution.Codex do
  @moduledoc """
  Fixed Codex 0.156.0 driver for the existing isolated coding lifecycle.

  Image receipts bind trusted local build inputs to an immutable Docker image;
  they do not qualify task execution. Coding owns resource creation, containment,
  exact artifact admission, current source authority, metering and cleanup.
  """
  import Bitwise
  alias HarnessForge.{Contracts, Workspaces}
  alias HarnessForge.Execution.{CodingTransport, Command}

  @id "docker-codex-isolated-v1"
  @version "0.156.0"
  @protocol "ollama-native-responses-v1"
  @base "node@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da"
  @platforms ["linux/amd64", "linux/arm64"]
  @driver_hash :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower)
  @inputs ~w(Dockerfile package.json package-lock.json preflight.cjs requirements.toml)
  @receipt_keys ~w(version driver_id descriptor_digest input_hashes base_image platform image_id cli_version transport_identity_digest cli_version_output_sha256)
  @expected_keys ~w(model overlay_sha256 guidance_sha256 project_config_sha256 requirements_sha256 rule_directory_uids skill_paths)
  @preflight_keys ~w(version cli_version protocol model model_provider raw_config_approval_policy approval_policy bootstrap_policy approvals_reviewer default_permissions active_permission_profile sandbox_policy network_access web_search provider disabled_features enabled_features skip_host_skill_discovery bundled_skills_enabled origins shell_environment tools managed_requirements rule_roots loaded_rule_roots initialize environment instruction_sources skill_paths overlay_sha256 guidance_sha256 project_config_sha256 requirements_sha256 rule_directory_uids warnings turns_started agent_invocation_verified command_bridge_qualified)
  @origin_keys ~w(model model_provider approval_policy approvals_reviewer default_permissions web_search features.shell_tool features.unified_exec features.multi_agent features.hooks shell_environment_policy.inherit tools.experimental_request_user_input.enabled tools.update_plan.enabled)
  @disabled ~w(apps browser_use browser_use_external browser_use_full_cdp_access code_mode code_mode_host code_mode_only computer_use goals hooks image_generation in_app_browser in_app_chat in_app_local_automation memories multi_agent multi_agent_v2 plugins remote_plugin remote_models shell_snapshot shell_snapshot_v2 unified_exec unified_exec_tty shell_zsh_fork exec_permission_approvals request_permissions_tool view_image use_legacy_landlock skill_mcp_dependency_install skill_env_var_dependency_prompt enable_request_compression unbounded_connection_retries network_proxy)
  @enabled ~w(shell_tool)
  @managed_features Map.new(
                      ~w(unified_exec unified_exec_tty shell_zsh_fork shell_snapshot shell_snapshot_v2 hooks exec_permission_approvals request_permissions_tool view_image use_legacy_landlock),
                      &{&1, false}
                    )
                    |> Map.put("shell_tool", true)
  @rule_roots ~w(/etc/codex/rules /home/harnessforge/.codex/rules /candidate/.codex/rules)
  @rule_tmpfs %{
    "/home/harnessforge/.codex/rules" => "ro,noexec,nosuid,nodev,size=64k,mode=0555,uid=0,gid=0",
    "/candidate/.codex/rules" => "ro,noexec,nosuid,nodev,size=64k,mode=0555,uid=0,gid=0"
  }
  @protected_reads ~w(/etc/codex /opt/harnessforge-codex /runtime /run/harnessforge /home/harnessforge/.codex /proc)
  @shell_environment %{
    "inherit" => "none",
    "ignore_default_excludes" => false,
    "exclude" => ["HARNESSFORGE_RELAY_TOKEN", "HARNESSFORGE_*", "*TOKEN*", "*KEY*", "*SECRET*"],
    "include_only" => ~w(PATH HOME TMPDIR LANG SHELL),
    "set" => %{
      "PATH" => "/usr/local/bin:/usr/bin:/bin",
      "HOME" => "/candidate",
      "TMPDIR" => "/candidate",
      "LANG" => "C.UTF-8",
      "SHELL" => "/bin/bash"
    }
  }
  @provider %{
    "base_url" => "http://model-relay:8080/v1",
    "env_key" => "HARNESSFORGE_RELAY_TOKEN",
    "wire_api" => "responses",
    "requires_openai_auth" => false,
    "request_max_retries" => 0,
    "stream_max_retries" => 0
  }
  @max_output 131_072

  @spec descriptor() :: map()
  def descriptor do
    hashes = Map.new(@inputs, &{&1, input_hash(&1)}) |> Map.put("codex.ex", @driver_hash)

    %{
      "id" => @id,
      "cli_version" => @version,
      "protocol" => @protocol,
      "command_bridge" => "native-approval-v1-phase1-unqualified",
      "permission_profile" => "hf_candidate",
      "managed_requirements_path" => requirements_path(),
      "rule_tmpfs" => rule_tmpfs(),
      "base_image" => @base,
      "platforms" => @platforms,
      "input_hashes" => hashes
    }
  end

  @spec descriptor_digest() :: String.t()
  def descriptor_digest, do: Contracts.digest(descriptor())

  @spec requirements_path() :: String.t()
  def requirements_path, do: "/etc/codex/requirements.toml"

  @spec rule_roots() :: [String.t()]
  def rule_roots, do: @rule_roots

  @doc "Fixed fresh read-only rule mounts; callers cannot select destinations or options."
  @spec rule_tmpfs() :: %{String.t() => String.t()}
  def rule_tmpfs, do: @rule_tmpfs

  @spec protected_read_paths() :: [String.t()]
  def protected_read_paths, do: @protected_reads

  @spec receipt_path() :: String.t()
  def receipt_path, do: Path.join([Workspaces.root(), "runtime", "codex-image-receipt.json"])

  @doc "Inspect only the checked immutable image on its original daemon; creates no resources."
  @spec load_image(CodingTransport.t()) :: {:ok, map()} | {:error, atom()}
  def load_image(%CodingTransport{} = observation) do
    with :ok <- CodingTransport.verify(observation),
         {:ok, bytes} <- read_receipt(),
         {:ok, receipt} <- Contracts.decode_json(bytes),
         :ok <- validate_receipt(receipt, observation),
         {:ok, %{exit_status: 0, output: output}} <-
           Command.docker_at(
             CodingTransport.endpoint(observation),
             ["image", "inspect", receipt["image_id"], "--format", "{{json .}}"],
             5_000,
             65_536
           ),
         {:ok, image} <- Contracts.decode_json(output),
         true <- is_map(image) and image["Id"] == receipt["image_id"],
         true <- image["Os"] <> "/" <> image["Architecture"] == receipt["platform"],
         :ok <- CodingTransport.verify(observation) do
      {:ok,
       Map.take(receipt, ~w(image_id descriptor_digest cli_version platform))
       |> Map.put("receipt_digest", Contracts.sha256(bytes))}
    else
      {:error, :coding_transport_changed} -> {:error, :coding_transport_changed}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :codex_image_unverified}
    end
  rescue
    _ -> {:error, :codex_image_unverified}
  end

  def load_image(_), do: {:error, :codex_image_unverified}

  @doc "Pure receipt validation is not image admission and grants no execution authority."
  @spec validate_receipt(term(), CodingTransport.t()) :: :ok | {:error, atom()}
  def validate_receipt(receipt, %CodingTransport{} = observation) when is_map(receipt) do
    descriptor = descriptor()

    if exact_keys?(receipt, @receipt_keys) and receipt["version"] == 1 and
         receipt["driver_id"] == @id and receipt["base_image"] == @base and
         receipt["platform"] in @platforms and receipt["cli_version"] == @version and
         receipt["descriptor_digest"] == Contracts.digest(descriptor) and
         receipt["input_hashes"] == descriptor["input_hashes"] and
         Enum.all?(Map.values(descriptor["input_hashes"]), &hash?/1) and
         image_id?(receipt["image_id"]) and
         receipt["transport_identity_digest"] == CodingTransport.identity_digest(observation) and
         receipt["cli_version_output_sha256"] == Contracts.sha256("codex-cli #{@version}\n"),
       do: :ok,
       else: {:error, :codex_image_receipt_mismatch}
  end

  def validate_receipt(_, _), do: {:error, :codex_image_receipt_mismatch}

  @doc "Trusted HOME overlay, distinct from and never written into exported project bytes."
  @spec effective_config(map(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def effective_config(artifact, model) do
    with :ok <- valid_artifact_files(artifact), true <- model?(model) do
      lines =
        [{"model", model}, {"project_doc_max_bytes", 131_072}] ++
          fixed_settings() ++
          [{"projects.\"/candidate\".trust_level", "trusted"}]

      {:ok,
       "# HarnessForge isolated runtime overlay; no credentials.\n" <>
         Enum.map_join(lines, "", fn {key, value} ->
           key <> " = " <> Jason.encode!(value) <> "\n"
         end)}
    else
      _ -> {:error, :codex_runtime_config_invalid}
    end
  end

  @spec preflight_expected(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def preflight_expected(artifact, model) do
    with {:ok, overlay} <- effective_config(artifact, model) do
      files = artifact["files"]

      {:ok,
       %{
         "model" => model,
         "overlay_sha256" => Contracts.sha256(overlay),
         "guidance_sha256" => Contracts.sha256(files["AGENTS.md"]),
         "project_config_sha256" => Contracts.sha256(files[".codex/config.toml"]),
         "requirements_sha256" => input_hash("requirements.toml"),
         "rule_directory_uids" => Map.new(@rule_roots, &{&1, 0}),
         "skill_paths" =>
           files
           |> Map.keys()
           |> Enum.filter(
             &Regex.match?(~r/\A\.agents\/skills\/[a-z0-9]+(?:-[a-z0-9]+)*\/SKILL\.md\z/, &1)
           )
           |> Enum.map(&("/candidate/" <> &1))
           |> Enum.sort()
       }}
    else
      _ -> {:error, :codex_runtime_config_invalid}
    end
  end

  @spec version_argv() :: [String.t()]
  def version_argv, do: ["codex", "--version"]

  @spec preflight_argv() :: [String.t()]
  def preflight_argv, do: ["node", "/opt/harnessforge-codex/preflight.cjs"]

  @doc "Task admission remains closed until native approval delivery and isolation are qualified."
  @spec task_argv(term()) :: {:error, :codex_command_bridge_unqualified}
  def task_argv(_), do: {:error, :codex_command_bridge_unqualified}

  @doc "Validate zero-turn discovery; this never establishes agent invocation or task success."
  @spec validate_preflight(binary(), map()) :: {:ok, map()} | {:error, atom()}
  def validate_preflight(bytes, expected)
      when is_binary(bytes) and byte_size(bytes) <= @max_output do
    with true <- valid_expected?(expected),
         {:ok, actual} <- Contracts.decode_json(bytes),
         true <- is_map(actual) and exact_keys?(actual, @preflight_keys),
         true <- Map.take(actual, @expected_keys) == expected,
         true <- actual["version"] == 3 and actual["cli_version"] == @version,
         true <- actual["protocol"] == @protocol,
         true <- actual["model_provider"] == "harnessforge_local",
         true <- actual["raw_config_approval_policy"] == "on-request",
         true <- valid_bootstrap_policy?(actual["bootstrap_policy"], actual["model"]),
         true <-
           actual["approval_policy"] == "untrusted" and actual["approvals_reviewer"] == "user" and
             actual["default_permissions"] == "hf_candidate",
         true <- actual["network_access"] == false and actual["web_search"] == "disabled",
         true <- actual["provider"] == @provider,
         true <-
           actual["disabled_features"] == @disabled and
             actual["enabled_features"] == @enabled and
             actual["skip_host_skill_discovery"] == true and
             actual["bundled_skills_enabled"] == false,
         true <- valid_origins?(actual["origins"]),
         true <- actual["shell_environment"] == @shell_environment,
         true <-
           actual["tools"] == %{
             "experimental_request_user_input" => false,
             "update_plan" => false
           },
         true <- valid_rule_roots?(actual["rule_roots"], expected["rule_directory_uids"]),
         true <- valid_loaded_rule_roots?(actual["loaded_rule_roots"]),
         true <- valid_managed_requirements?(actual["managed_requirements"]),
         true <- valid_initialize?(actual["initialize"]),
         true <- valid_profile?(actual["active_permission_profile"]),
         true <- valid_sandbox?(actual["sandbox_policy"]),
         true <- valid_environment?(actual["environment"]),
         true <- actual["instruction_sources"] == ["/candidate/AGENTS.md"],
         true <-
           actual["warnings"] == [] and actual["turns_started"] == 0 and
             actual["agent_invocation_verified"] == false and
             actual["command_bridge_qualified"] == false do
      {:ok, actual}
    else
      _ -> {:error, :codex_preflight_rejected}
    end
  end

  def validate_preflight(_, _), do: {:error, :codex_preflight_rejected}

  @doc "Historical exec JSONL validator only; it cannot qualify the native command bridge."
  @spec validate_events(binary()) :: {:ok, map()} | {:error, atom()}
  def validate_events(bytes) when is_binary(bytes) and byte_size(bytes) in 1..@max_output do
    with true <- String.valid?(bytes) and String.ends_with?(bytes, "\n"),
         lines = String.split(bytes, "\n", trim: true),
         true <- length(lines) in 3..1000,
         {:ok, events} <- decode_lines(lines),
         {:ok, state} <- Enum.reduce_while(events, {:ok, initial_state()}, &event/2),
         true <- state.phase == :completed and map_size(state.pending) == 0 do
      {:ok,
       %{
         "events" => events,
         "usage" => state.usage,
         "changed_paths" => state.paths |> MapSet.to_list() |> Enum.sort(),
         "events_digest" => Contracts.sha256(bytes)
       }}
    else
      _ -> {:error, :codex_events_rejected}
    end
  end

  def validate_events(_), do: {:error, :codex_events_rejected}

  defp fixed_settings do
    [
      {"model_provider", "harnessforge_local"},
      {"approvals_reviewer", "user"},
      {"default_permissions", "hf_candidate"},
      {"allow_login_shell", false},
      {"tool_output_token_limit", 2000},
      {"tools.experimental_request_user_input.enabled", false},
      {"tools.update_plan.enabled", false},
      {"web_search", "disabled"},
      {"skills.bundled.enabled", false},
      {"model_providers.harnessforge_local.name", "HarnessForge isolated local relay"}
    ] ++
      (@provider
       |> Enum.sort()
       |> Enum.map(fn {key, value} ->
         {"model_providers.harnessforge_local." <> key, value}
       end)) ++
      Enum.map(@disabled, &{"features." <> &1, false}) ++
      Enum.map(@enabled, &{"features." <> &1, true}) ++
      [{"features.skip_host_skill_discovery", true}] ++
      (@shell_environment
       |> Map.delete("set")
       |> Enum.sort()
       |> Enum.map(fn {key, value} ->
         {"shell_environment_policy." <> key, value}
       end)) ++
      (@shell_environment["set"]
       |> Enum.sort()
       |> Enum.map(fn {key, value} ->
         {"shell_environment_policy.set." <> key, value}
       end))
  end

  defp valid_artifact_files(%{"files" => files}) when is_map(files) do
    required = ~w(AGENTS.md .codex/config.toml)

    if map_size(files) <= 100 and Enum.all?(required, &is_binary(files[&1])) and
         Enum.all?(files, fn {path, bytes} ->
           is_binary(path) and is_binary(bytes) and String.valid?(bytes) and
             byte_size(bytes) <= @max_output
         end),
       do: :ok,
       else: {:error, :codex_runtime_config_invalid}
  end

  defp valid_artifact_files(_), do: {:error, :codex_runtime_config_invalid}

  defp input_hash(name) do
    case File.read(Application.app_dir(:harness_forge, ["priv", "codex_runtime", name])) do
      {:ok, bytes} when byte_size(bytes) <= 2_000_000 -> Contracts.sha256(bytes)
      _ -> nil
    end
  end

  defp read_receipt do
    root = Workspaces.root()
    parent = Path.dirname(receipt_path())

    with {:ok, root_stat} <- File.lstat(root),
         true <- private_dir?(root_stat),
         {:ok, parent_stat} <- File.lstat(parent),
         true <- private_dir?(parent_stat) and parent_stat.uid == root_stat.uid,
         {:ok, before_stat} <- File.lstat(receipt_path()),
         true <-
           before_stat.type == :regular and before_stat.links == 1 and
             before_stat.uid == root_stat.uid and (before_stat.mode &&& 0o777) == 0o600 and
             before_stat.size in 1..16_384,
         {:ok, io} <- File.open(receipt_path(), [:read, :binary]) do
      try do
        bytes = IO.binread(io, 16_385)

        with true <- is_binary(bytes) and byte_size(bytes) == before_stat.size,
             {:ok, after_stat} <- File.lstat(receipt_path()),
             true <- same_file?(before_stat, after_stat),
             {:ok, after_parent} <- File.lstat(parent),
             true <- same_file?(parent_stat, after_parent),
             {:ok, after_root} <- File.lstat(root),
             true <- same_file?(root_stat, after_root) do
          {:ok, bytes}
        else
          _ -> {:error, :codex_image_receipt_untrusted}
        end
      after
        File.close(io)
      end
    else
      {:error, :enoent} -> {:error, :codex_image_receipt_missing}
      _ -> {:error, :codex_image_receipt_untrusted}
    end
  end

  # Reading may legitimately update atime. All security-relevant identity and
  # mutation fields must remain stable across the bounded read.
  defp same_file?(left, right),
    do:
      Map.take(
        left,
        ~w(type mode uid gid inode major_device minor_device links size mtime ctime)a
      ) ==
        Map.take(
          right,
          ~w(type mode uid gid inode major_device minor_device links size mtime ctime)a
        )

  defp private_dir?(stat), do: stat.type == :directory and (stat.mode &&& 0o777) == 0o700
  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp image_id?(value), do: is_binary(value) and Regex.match?(~r/\Asha256:[a-f0-9]{64}\z/, value)

  defp model?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,127}\z/, value)

  defp valid_expected?(expected) when is_map(expected) do
    exact_keys?(expected, @expected_keys) and model?(expected["model"]) and
      Enum.all?(
        ~w(overlay_sha256 guidance_sha256 project_config_sha256 requirements_sha256),
        &hash?(expected[&1])
      ) and
      valid_rule_uids?(expected["rule_directory_uids"]) and
      is_list(expected["skill_paths"]) and length(expected["skill_paths"]) <= 100 and
      expected["skill_paths"] == Enum.sort(Enum.uniq(expected["skill_paths"])) and
      Enum.all?(expected["skill_paths"], fn path ->
        is_binary(path) and
          Regex.match?(
            ~r/\A\/candidate\/\.agents\/skills\/[a-z0-9]+(?:-[a-z0-9]+)*\/SKILL\.md\z/,
            path
          )
      end)
  end

  defp valid_expected?(_), do: false

  defp valid_origins?(origins) when is_map(origins) do
    exact_keys?(origins, @origin_keys) and
      Enum.all?(origins, fn {key, origin} ->
        expected_name =
          case key do
            "model" ->
              %{
                "type" => "user",
                "file" => "/home/harnessforge/.codex/config.toml",
                "profile" => nil
              }

            "approval_policy" ->
              %{"type" => "project", "dotCodexFolder" => "/candidate/.codex"}

            _ ->
              %{"type" => "sessionFlags"}
          end

        is_map(origin) and exact_keys?(origin, ~w(name version)) and
          origin["name"] == expected_name and is_binary(origin["version"]) and
          Regex.match?(~r/\Asha256:[a-f0-9]{64}\z/, origin["version"])
      end)
  end

  defp valid_origins?(_), do: false

  # Bootstrap policy metadata records an actual zero-turn thread response only;
  # it is not a command, catalog, containment or credential-isolation result.
  defp valid_bootstrap_policy?(value, model) do
    value == %{
      "approval_policy_override" => nil,
      "approval_policy" => "untrusted",
      "approvals_reviewer" => "user",
      "active_permission_profile" => %{"id" => "hf_candidate", "extends" => nil},
      "model" => model,
      "model_provider" => "harnessforge_local",
      "cwd" => "/candidate"
    }
  end

  defp valid_profile?(value), do: value == %{"id" => "hf_candidate", "extends" => nil}

  # This legacy projection cannot prove denied-read or namespace enforcement.
  # Managed requirements and Root's protected probes remain separate gates.
  defp valid_sandbox?(value) do
    value == %{
      "type" => "workspaceWrite",
      "writableRoots" => ["/candidate"],
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => true,
      "excludeSlashTmp" => true
    }
  end

  defp valid_initialize?(value) when is_map(value) do
    exact_keys?(value, ~w(user_agent codex_home platform_family platform_os)) and
      value["codex_home"] == "/home/harnessforge/.codex" and
      value["platform_family"] == "unix" and value["platform_os"] == "linux" and
      bounded_text?(value["user_agent"]) and byte_size(value["user_agent"]) in 1..256
  end

  defp valid_initialize?(_), do: false

  defp valid_environment?(value) when is_map(value) do
    exact_keys?(value, ~w(environment_id cwd runtime_workspace_roots info status)) and
      identifier?(value["environment_id"]) and value["cwd"] == "/candidate" and
      value["runtime_workspace_roots"] == ["/candidate"] and
      value["info"] == %{
        "shell" => %{"name" => "bash", "path" => "/bin/bash"},
        "cwd" => "file:///candidate"
      } and
      value["status"] == %{"status" => "ready"}
  end

  defp valid_environment?(_), do: false

  defp valid_rule_roots?(value, owners) when is_list(value) do
    value ==
      Enum.map(
        @rule_roots,
        &%{
          "path" => &1,
          "uid" => owners[&1],
          "mode" => 0o555,
          "entries" => [],
          "writable" => false
        }
      )
  end

  defp valid_rule_roots?(_, _), do: false

  defp valid_rule_uids?(value) when is_map(value),
    do: value === Map.new(@rule_roots, &{&1, 0})

  defp valid_rule_uids?(_), do: false

  defp valid_loaded_rule_roots?(value) when is_list(value) do
    value == Enum.sort(@rule_roots)
  end

  defp valid_loaded_rule_roots?(_), do: false

  defp valid_managed_requirements?(value) do
    value == %{
      "allowed_approval_policies" => ["untrusted"],
      "allowed_approvals_reviewers" => ["user"],
      "allowed_web_search_modes" => ["disabled"],
      "default_permissions" => "hf_candidate",
      "allowed_permission_profiles" => %{"hf_candidate" => true},
      "allow_login_shell" => false,
      "check_for_update_on_startup" => false,
      "feature_requirements" => @managed_features
    }
  end

  defp decode_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case Contracts.decode_json(line) do
        {:ok, value} when is_map(value) -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      _ -> :error
    end
  end

  defp initial_state,
    do: %{phase: :new, pending: %{}, seen: MapSet.new(), paths: MapSet.new(), usage: nil}

  defp event(%{"type" => "thread.started", "thread_id" => id} = e, {:ok, %{phase: :new} = s}) do
    if exact_keys?(e, ~w(type thread_id)) and identifier?(id),
      do: {:cont, {:ok, %{s | phase: :thread}}},
      else: {:halt, :error}
  end

  defp event(%{"type" => "turn.started"} = e, {:ok, %{phase: :thread} = s}) do
    if exact_keys?(e, ["type"]), do: {:cont, {:ok, %{s | phase: :running}}}, else: {:halt, :error}
  end

  defp event(%{"type" => type, "item" => item} = e, {:ok, %{phase: :running} = s})
       when type in ["item.started", "item.updated", "item.completed"] do
    with true <- exact_keys?(e, ~w(type item)) and is_map(item),
         true <- identifier?(item["id"]),
         true <- valid_item?(item, type),
         false <- MapSet.member?(s.seen, item["id"]),
         true <- not Map.has_key?(s.pending, item["id"]) or s.pending[item["id"]] == item["type"] do
      id = item["id"]

      if type == "item.completed" do
        paths = Enum.reduce(item["changes"] || [], s.paths, &MapSet.put(&2, &1["path"]))

        {:cont,
         {:ok,
          %{s | pending: Map.delete(s.pending, id), seen: MapSet.put(s.seen, id), paths: paths}}}
      else
        {:cont, {:ok, %{s | pending: Map.put(s.pending, id, item["type"])}}}
      end
    else
      _ -> {:halt, :error}
    end
  end

  defp event(
         %{"type" => "turn.completed", "usage" => usage} = e,
         {:ok, %{phase: :running} = s}
       ) do
    if exact_keys?(e, ~w(type usage)) and map_size(s.pending) == 0 and valid_usage?(usage),
      do: {:cont, {:ok, %{s | phase: :completed, usage: usage}}},
      else: {:halt, :error}
  end

  defp event(_, _), do: {:halt, :error}

  defp valid_item?(%{"type" => type, "text" => text} = item, _)
       when type in ["reasoning", "agent_message"],
       do: exact_keys?(item, ~w(id type text)) and bounded_text?(text)

  defp valid_item?(
         %{"type" => "file_change", "changes" => changes, "status" => status} = item,
         event
       ) do
    exact_keys?(item, ~w(id type changes status)) and is_list(changes) and
      length(changes) in 1..100 and
      status in if(event == "item.completed", do: ["completed"], else: ["in_progress"]) and
      Enum.all?(changes, fn change ->
        is_map(change) and exact_keys?(change, ~w(path kind)) and
          change["kind"] in ~w(add update delete) and
          safe_relative_path?(change["path"])
      end)
  end

  # Historical exec output cannot qualify the current app-server command path.
  # Its distinct RPC/approval evidence must never be converted into this JSONL.
  defp valid_item?(_, _), do: false

  defp valid_usage?(usage) when is_map(usage),
    do:
      exact_keys?(usage, ~w(input_tokens cached_input_tokens output_tokens)) and
        Enum.all?(Map.values(usage), &(is_integer(&1) and &1 >= 0 and &1 <= 100_000_000)) and
        usage["input_tokens"] >= usage["cached_input_tokens"] and
        usage["input_tokens"] + usage["output_tokens"] > 0

  defp valid_usage?(_), do: false

  defp bounded_text?(text),
    do:
      is_binary(text) and String.valid?(text) and byte_size(text) <= 65_536 and
        not String.contains?(text, <<0>>)

  defp identifier?(id),
    do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/, id)

  defp safe_relative_path?(path) when is_binary(path) and byte_size(path) in 1..256 do
    not String.starts_with?(path, "/") and not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(
        String.split(path, "/"),
        &(&1 not in ["", ".", "..", ".codex", ".agents", "AGENTS.md"])
      ) and
      String.valid?(path)
  end

  defp safe_relative_path?(_), do: false
end
