defmodule HarnessForge.CodexRuntimeTest do
  use ExUnit.Case, async: false
  alias HarnessForge.{Contracts, Workspaces}
  alias HarnessForge.CodingDockerFixture, as: Fixture
  alias HarnessForge.Execution.{Codex, CodingTransport}

  setup do
    fixture = Fixture.install!()
    previous = Application.get_env(:harness_forge, :workspace_root)
    root = Path.join(fixture.root, "workspace")
    File.mkdir_p!(Path.join(root, "runtime"))
    File.chmod!(root, 0o700)
    File.chmod!(Path.join(root, "runtime"), 0o700)
    Application.put_env(:harness_forge, :workspace_root, root)
    {:ok, observation} = CodingTransport.observe()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:harness_forge, :workspace_root, previous),
        else: Application.delete_env(:harness_forge, :workspace_root)

      Fixture.restore(fixture)
    end)

    %{fixture: fixture, observation: observation}
  end

  test "descriptor pins compiled driver and release-shipped inputs, never a tag" do
    descriptor = Codex.descriptor()
    assert descriptor["id"] == "docker-codex-isolated-v1"
    assert descriptor["cli_version"] == "0.156.0"
    assert descriptor["protocol"] == "ollama-native-responses-v1"
    assert descriptor["platforms"] == ["linux/amd64", "linux/arm64"]
    assert descriptor["base_image"] =~ ~r/\Anode@sha256:[a-f0-9]{64}\z/

    assert Enum.sort(Map.keys(descriptor["input_hashes"])) ==
             Enum.sort(
               ~w(Dockerfile package.json package-lock.json preflight.cjs requirements.toml codex.ex)
             )

    assert Enum.all?(
             Map.values(descriptor["input_hashes"]),
             &Regex.match?(~r/\A[a-f0-9]{64}\z/, &1)
           )

    assert Codex.descriptor_digest() == Contracts.digest(descriptor)
  end

  test "receipt binds every input, immutable image, platform and original daemon", ctx do
    receipt = receipt(ctx.observation)
    assert :ok = Codex.validate_receipt(receipt, ctx.observation)

    for {key, value} <- [
          {"version", 2},
          {"driver_id", "docker-coding-isolated-v2"},
          {"descriptor_digest", hash("changed")},
          {"input_hashes", %{}},
          {"base_image", "node:latest"},
          {"platform", "linux/s390x"},
          {"image_id", "harnessforge:codex"},
          {"cli_version", "0.155.0"},
          {"transport_identity_digest", hash("decoy")},
          {"cli_version_output_sha256", hash("bad")}
        ] do
      assert {:error, :codex_image_receipt_mismatch} =
               Codex.validate_receipt(Map.put(receipt, key, value), ctx.observation)

      assert {:error, :codex_image_receipt_mismatch} =
               Codex.validate_receipt(Map.delete(receipt, key), ctx.observation)
    end

    assert {:error, :codex_image_receipt_mismatch} =
             Codex.validate_receipt(Map.put(receipt, "tag", "latest"), ctx.observation)

    assert {:error, :codex_image_receipt_mismatch} =
             Codex.validate_receipt(receipt, %{ctx.observation | daemon_id: "DECOY"})
  end

  test "admission uses only immutable ID inspection and original daemon, creating no resources",
       ctx do
    receipt = receipt(ctx.observation)
    write_receipt(receipt)
    image_fixture(ctx.fixture, receipt["image_id"])
    Fixture.clear_commands(ctx.fixture)

    assert {:ok, loaded} = Codex.load_image(ctx.observation)
    assert loaded["image_id"] == receipt["image_id"]
    assert loaded["descriptor_digest"] == Codex.descriptor_digest()
    assert loaded["receipt_digest"] == hash(File.read!(Codex.receipt_path()))
    commands = Fixture.commands(ctx.fixture)
    assert length(commands) == 3

    assert Enum.at(commands, 1)["argv"] ==
             [
               "--host",
               ctx.fixture.endpoint,
               "image",
               "inspect",
               receipt["image_id"],
               "--format",
               "{{json .}}"
             ]

    refute Enum.any?(
             commands,
             &Enum.any?(&1["argv"], fn arg -> arg in ~w(run create pull build) end)
           )

    image_fixture(ctx.fixture, "sha256:" <> hash("substituted"))
    assert {:error, :codex_image_unverified} = Codex.load_image(ctx.observation)
    image_fixture(ctx.fixture, receipt["image_id"], "amd64")
    assert {:error, :codex_image_unverified} = Codex.load_image(ctx.observation)

    Fixture.put_daemon(ctx.fixture, ctx.fixture.endpoint, %{
      "identity_raw" => Jason.encode!("CHANGED")
    })

    assert {:error, :coding_transport_changed} = Codex.load_image(ctx.observation)
  end

  test "missing, linked, permissive, duplicate-key and oversized receipts are refused", ctx do
    assert {:error, :codex_image_receipt_missing} = Codex.load_image(ctx.observation)
    write_receipt(receipt(ctx.observation))
    File.chmod!(Codex.receipt_path(), 0o644)
    assert {:error, :codex_image_receipt_untrusted} = Codex.load_image(ctx.observation)
    File.chmod!(Codex.receipt_path(), 0o600)
    File.ln!(Codex.receipt_path(), Path.join(Workspaces.root(), "receipt-link"))
    assert {:error, :codex_image_receipt_untrusted} = Codex.load_image(ctx.observation)
    File.rm!(Path.join(Workspaces.root(), "receipt-link"))
    File.rename!(Codex.receipt_path(), Codex.receipt_path() <> ".real")
    File.ln_s!(Codex.receipt_path() <> ".real", Codex.receipt_path())
    assert {:error, :codex_image_receipt_untrusted} = Codex.load_image(ctx.observation)
    File.rm!(Codex.receipt_path())
    File.write!(Codex.receipt_path(), ~s({"version":1,"version":1}))
    File.chmod!(Codex.receipt_path(), 0o600)
    assert {:error, :codex_image_unverified} = Codex.load_image(ctx.observation)
    File.write!(Codex.receipt_path(), String.duplicate(" ", 16_385))
    assert {:error, :codex_image_receipt_untrusted} = Codex.load_image(ctx.observation)
  end

  test "native approval overlay preserves exported bytes and never grants task execution" do
    artifact = artifact()
    before = Contracts.digest(artifact)
    assert {:ok, overlay} = Codex.effective_config(artifact, "qwen3:4b")
    assert overlay =~ ~s(model = "qwen3:4b")
    refute Regex.match?(~r/^\s*approval_policy\s*=/m, overlay)
    assert overlay =~ ~s(approvals_reviewer = "user")
    assert overlay =~ ~s(default_permissions = "hf_candidate")
    assert overlay =~ ~s(model_providers.harnessforge_local.wire_api = "responses")
    assert overlay =~ ~s(model_providers.harnessforge_local.env_key = "HARNESSFORGE_RELAY_TOKEN")
    assert overlay =~ "features.multi_agent = false"
    assert overlay =~ "features.shell_tool = true"
    assert overlay =~ "features.unified_exec = false"
    assert overlay =~ "features.view_image = false"
    assert overlay =~ "tools.experimental_request_user_input.enabled = false"
    assert overlay =~ "tools.update_plan.enabled = false"
    assert overlay =~ ~s(shell_environment_policy.inherit = "none")
    assert overlay =~ ~s(shell_environment_policy.set.PATH = "/usr/local/bin:/usr/bin:/bin")
    assert overlay =~ ~s(shell_environment_policy.set.HOME = "/candidate")
    assert overlay =~ ~s(shell_environment_policy.set.TMPDIR = "/candidate")
    assert overlay =~ ~s(shell_environment_policy.set.SHELL = "/bin/bash")
    refute overlay =~ ~s(approval_policy = "never")
    refute overlay =~ "sandbox_mode ="
    refute overlay =~ "Bearer"
    prompt = "Edit utility.go. Literal $(touch /host) is task data."

    for input <- [prompt, "", <<0>>, String.duplicate("x", 16_385), nil, %{approved: true}] do
      assert {:error, :codex_command_bridge_unqualified} = Codex.task_argv(input)
    end

    assert ["codex", "--version"] == Codex.version_argv()
    assert ["node", "/opt/harnessforge-codex/preflight.cjs"] == Codex.preflight_argv()
    assert Contracts.digest(artifact) == before

    assert {:error, :codex_runtime_config_invalid} =
             Codex.effective_config(artifact, "model\napi_key=secret")

    assert {:error, :codex_runtime_config_invalid} =
             Codex.effective_config(%{"files" => %{}}, "qwen3:4b")
  end

  test "preflight independently checks actual routes, origins, discovery and zero-turn status" do
    {:ok, expected} = Codex.preflight_expected(artifact(), "qwen3:4b")
    observed = preflight(expected)
    assert {:ok, ^observed} = Codex.validate_preflight(Jason.encode!(observed), expected)
    assert observed["turns_started"] == 0
    assert observed["agent_invocation_verified"] == false

    for {key, value} <- [
          {"model", "cloud-model"},
          {"model_provider", "openai"},
          {"approval_policy", "never"},
          {"raw_config_approval_policy", "untrusted"},
          {"bootstrap_policy", %{}},
          {"approvals_reviewer", "auto_review"},
          {"default_permissions", ":danger-full-access"},
          {"active_permission_profile",
           %{"id" => "hf_candidate", "extends" => ":danger-full-access"}},
          {"network_access", true},
          {"sandbox_policy", %{"type" => "dangerFullAccess"}},
          {"web_search", "live"},
          {"provider", %{}},
          {"disabled_features", []},
          {"enabled_features", []},
          {"bundled_skills_enabled", true},
          {"origins", %{}},
          {"skill_paths", []},
          {"instruction_sources", ["/host/AGENTS.md"]},
          {"overlay_sha256", hash("changed")},
          {"requirements_sha256", hash("changed requirements")},
          {"managed_requirements", nil},
          {"rule_roots", []},
          {"loaded_rule_roots", ["/candidate/../rules"]},
          {"shell_environment", %{"inherit" => "all"}},
          {"tools", %{"update_plan" => true, "experimental_request_user_input" => true}},
          {"initialize", %{}},
          {"environment", %{}},
          {"warnings", ["unrecognized field"]},
          {"turns_started", 1},
          {"agent_invocation_verified", true},
          {"command_bridge_qualified", true}
        ] do
      assert {:error, :codex_preflight_rejected} =
               Codex.validate_preflight(Jason.encode!(Map.put(observed, key, value)), expected)
    end

    wrong_project_origin =
      put_in(observed, ["origins", "approval_policy", "name"], %{
        "type" => "project",
        "dotCodexFolder" => "/host/.codex"
      })

    assert {:error, :codex_preflight_rejected} =
             Codex.validate_preflight(Jason.encode!(wrong_project_origin), expected)

    assert {:error, :codex_preflight_rejected} = Codex.validate_preflight("{}", %{})

    assert {:error, :codex_preflight_rejected} =
             Codex.validate_preflight(String.duplicate("x", 131_073), expected)
  end

  test "raw project policy stays distinct from both effective untrusted bootstrap policies" do
    {:ok, expected} = Codex.preflight_expected(artifact(), "qwen3:4b")
    observed = preflight(expected)
    assert {:ok, ^observed} = Codex.validate_preflight(Jason.encode!(observed), expected)
    assert observed["version"] == 3
    assert observed["raw_config_approval_policy"] == "on-request"
    assert observed["approval_policy"] == "untrusted"
    assert observed["bootstrap_policy"]["approval_policy"] == "untrusted"
    assert observed["bootstrap_policy"]["approval_policy_override"] == nil

    for changed <- [
          Map.put(observed, "raw_config_approval_policy", "untrusted"),
          Map.put(observed, "approval_policy", "on-request"),
          put_in(observed, ["bootstrap_policy", "approval_policy"], "on-request"),
          put_in(observed, ["bootstrap_policy", "approval_policy_override"], "untrusted"),
          put_in(observed, ["bootstrap_policy", "approvals_reviewer"], "auto_review"),
          put_in(observed, ["bootstrap_policy", "active_permission_profile", "id"], ":workspace"),
          put_in(observed, ["bootstrap_policy", "model"], "other-model"),
          put_in(observed, ["origins", "approval_policy", "name"], %{"type" => "sessionFlags"}),
          put_in(observed, ["origins", "approval_policy", "name"], %{
            "type" => "user",
            "file" => "/home/harnessforge/.codex/config.toml",
            "profile" => nil
          }),
          Map.put(observed, "warnings", ["Unobserved native policy clamp warning"]),
          Map.put(observed, "version", 2)
        ] do
      assert {:error, :codex_preflight_rejected} =
               Codex.validate_preflight(Jason.encode!(changed), expected)
    end

    assert {:error, :codex_command_bridge_unqualified} = Codex.task_argv("perform approved work")
  end

  test "managed requirements are pinned immutable image inputs and deny protected roots" do
    bytes =
      File.read!(
        Application.app_dir(:harness_forge, ["priv", "codex_runtime", "requirements.toml"])
      )

    assert Codex.descriptor()["input_hashes"]["requirements.toml"] == hash(bytes)
    assert Codex.requirements_path() == "/etc/codex/requirements.toml"
    assert bytes =~ ~s(allowed_approval_policies = ["untrusted"])
    assert bytes =~ ~s(allowed_approvals_reviewers = ["user"])
    assert bytes =~ "unified_exec = false\nshell_tool = true"
    assert bytes =~ "[allowed_permission_profiles]\nhf_candidate = true"
    assert bytes =~ "[permissions.hf_candidate.network]\nenabled = false"
    assert bytes =~ ~s("/candidate" = "write")
    assert bytes =~ ~s("/candidate/.codex" = "read")
    assert bytes =~ ~s("/candidate/.agents" = "read")
    assert bytes =~ ~s("/candidate/AGENTS.md" = "read")
    for protected <- Codex.protected_read_paths(), do: assert(bytes =~ Jason.encode!(protected))

    assert Codex.rule_roots() == [
             "/etc/codex/rules",
             "/home/harnessforge/.codex/rules",
             "/candidate/.codex/rules"
           ]

    {:ok, expected} = Codex.preflight_expected(artifact(), "qwen3:4b")
    assert expected["requirements_sha256"] == hash(bytes)
    refute bytes =~ "use_legacy_landlock = true"
    refute bytes =~ "use_linux_sandbox_bwrap"
  end

  test "rule tmpfs recipe is source-owned and expected container UIDs do not depend on host ownership",
       %{fixture: fixture} do
    expected_mounts = %{
      "/home/harnessforge/.codex/rules" =>
        "ro,noexec,nosuid,nodev,size=64k,mode=0555,uid=0,gid=0",
      "/candidate/.codex/rules" => "ro,noexec,nosuid,nodev,size=64k,mode=0555,uid=0,gid=0"
    }

    assert Codex.rule_tmpfs() == expected_mounts
    assert Codex.descriptor()["rule_tmpfs"] == expected_mounts

    assert Enum.sort(Map.keys(expected_mounts)) ==
             ["/candidate/.codex/rules", "/home/harnessforge/.codex/rules"]

    previous_root = Application.get_env(:harness_forge, :workspace_root)

    Application.put_env(
      :harness_forge,
      :workspace_root,
      Path.join(fixture.root, "absent-workspace")
    )

    try do
      assert {:ok, expected} = Codex.preflight_expected(artifact(), "qwen3:4b")
      assert expected["rule_directory_uids"] === Map.new(Codex.rule_roots(), &{&1, 0})
    after
      Application.put_env(:harness_forge, :workspace_root, previous_root)
    end
  end

  test "preflight requires all-zero expected and observed owners plus the exact three loaded roots" do
    {:ok, expected} = Codex.preflight_expected(artifact(), "qwen3:4b")
    observed = preflight(expected)
    assert {:ok, ^observed} = Codex.validate_preflight(Jason.encode!(observed), expected)

    for uid <- [1, 501, 65534] do
      # A matching nonzero expected/observed host binding must not become
      # container policy authority, including the old shared HOME/project case.
      owners =
        expected["rule_directory_uids"]
        |> Map.put("/home/harnessforge/.codex/rules", uid)
        |> Map.put("/candidate/.codex/rules", uid)

      changed_expected = Map.put(expected, "rule_directory_uids", owners)

      changed_observed =
        observed
        |> Map.put("rule_directory_uids", owners)
        |> Map.update!("rule_roots", fn roots ->
          Enum.map(roots, &Map.put(&1, "uid", owners[&1["path"]]))
        end)

      assert {:error, :codex_preflight_rejected} =
               Codex.validate_preflight(Jason.encode!(changed_observed), changed_expected)

      for index <- 0..2 do
        drift =
          Map.update!(
            observed,
            "rule_roots",
            &List.update_at(&1, index, fn root -> Map.put(root, "uid", uid) end)
          )

        assert {:error, :codex_preflight_rejected} =
                 Codex.validate_preflight(Jason.encode!(drift), expected)
      end
    end

    roots = Enum.sort(Codex.rule_roots())

    for invalid <- [
          Enum.drop(roots, 1),
          List.delete(roots, "/etc/codex/rules"),
          Enum.reverse(roots),
          roots ++ ["/candidate/extra/rules"],
          roots ++ [hd(roots)]
        ] do
      assert {:error, :codex_preflight_rejected} =
               Codex.validate_preflight(
                 Jason.encode!(Map.put(observed, "loaded_rule_roots", invalid)),
                 expected
               )
    end
  end

  test "preflight refuses permissive native requirements, child credentials, rules and environment drift" do
    {:ok, expected} = Codex.preflight_expected(artifact(), "qwen3:4b")
    observed = preflight(expected)

    mutations = [
      put_in(observed, ["managed_requirements", "feature_requirements", "unified_exec"], true),
      put_in(observed, ["managed_requirements", "allowed_approval_policies"], [
        "untrusted",
        "never"
      ]),
      put_in(observed, ["managed_requirements", "allowed_permission_profiles", "unsafe"], true),
      put_in(
        observed,
        ["shell_environment", "set", "HARNESSFORGE_RELAY_TOKEN"],
        "synthetic sentinel"
      ),
      put_in(observed, ["shell_environment", "inherit"], "all"),
      put_in(observed, ["environment", "info", "shell", "path"], "/bin/sh"),
      put_in(observed, ["environment", "info", "cwd"], "/candidate"),
      put_in(observed, ["environment", "status"], %{"status" => "pending"}),
      put_in(observed, ["environment", "runtime_workspace_roots"], ["/"]),
      put_in(observed, ["initialize", "platform_os"], "macos"),
      put_in(observed, ["initialize", "codex_home"], "/host/.codex"),
      put_in(observed, ["sandbox_policy", "writableRoots"], ["/candidate", "/runtime"]),
      put_in(observed, ["sandbox_policy", "excludeSlashTmp"], false),
      Map.put(observed, "loaded_rule_roots", ["/home/harnessforge/.codex/rules"]),
      Map.put(
        observed,
        "rule_roots",
        List.update_at(observed["rule_roots"], 0, &Map.put(&1, "entries", ["allow.rules"]))
      ),
      Map.put(
        observed,
        "rule_roots",
        List.update_at(observed["rule_roots"], 0, &Map.put(&1, "writable", true))
      ),
      Map.put(
        observed,
        "rule_roots",
        List.update_at(observed["rule_roots"], 0, &Map.put(&1, "uid", 65534))
      )
    ]

    for changed <- mutations do
      assert {:error, :codex_preflight_rejected} =
               Codex.validate_preflight(Jason.encode!(changed), expected)
    end
  end

  test "native event validation retains inspectable edits and reported usage" do
    events = events()
    bytes = jsonl(events)
    assert {:ok, result} = Codex.validate_events(bytes)
    assert result["events"] == events
    assert result["changed_paths"] == ["utility.go"]

    assert result["usage"] == %{
             "input_tokens" => 42,
             "cached_input_tokens" => 0,
             "output_tokens" => 17
           }

    assert result["events_digest"] == hash(bytes)
  end

  test "incomplete, duplicate, approval, unsupported tool, error and unknown-usage streams fail closed" do
    events = events()

    for invalid <- [
          Enum.drop(events, -1),
          events ++ [List.last(events)],
          List.insert_at(events, 2, %{"type" => "approval.requested"}),
          List.insert_at(events, 2, %{"type" => "error", "message" => "provider failed"}),
          List.insert_at(events, 2, %{
            "type" => "item.completed",
            "item" => %{"id" => "web1", "type" => "web_search", "query" => "private"}
          }),
          List.insert_at(events, 2, %{
            "type" => "item.completed",
            "item" => %{"id" => "shell1", "type" => "command_execution", "command" => "whoami"}
          }),
          List.insert_at(events, 3, Enum.at(events, 2)),
          List.replace_at(
            events,
            2,
            put_in(Enum.at(events, 2), ["item", "changes"], [
              %{"path" => "../escape", "kind" => "update"}
            ])
          ),
          List.replace_at(
            events,
            2,
            put_in(Enum.at(events, 2), ["item", "changes"], [
              %{"path" => ".codex/config.toml", "kind" => "update"}
            ])
          ),
          List.replace_at(events, 2, put_in(Enum.at(events, 2), ["item", "status"], "failed")),
          List.replace_at(events, 3, %{"type" => "turn.completed", "usage" => nil}),
          List.replace_at(events, 3, %{
            "type" => "turn.completed",
            "usage" => %{"input_tokens" => 0, "cached_input_tokens" => 0, "output_tokens" => 0}
          }),
          List.replace_at(events, 3, %{
            "type" => "turn.completed",
            "usage" => %{"input_tokens" => 1, "cached_input_tokens" => 2, "output_tokens" => 1}
          })
        ] do
      assert {:error, :codex_events_rejected} = Codex.validate_events(jsonl(invalid))
    end

    assert {:error, :codex_events_rejected} =
             Codex.validate_events(String.trim_trailing(jsonl(events)))

    assert {:error, :codex_events_rejected} =
             Codex.validate_events("{\"type\":\"turn.started\",\"type\":\"turn.completed\"}\n")
  end

  test "pending tool items must complete before terminal usage" do
    [thread, turn, item, terminal] = events()
    started = put_in(item, ["type"], "item.started") |> put_in(["item", "status"], "in_progress")

    assert {:error, :codex_events_rejected} =
             Codex.validate_events(jsonl([thread, turn, started, terminal]))

    assert {:ok, _} = Codex.validate_events(jsonl([thread, turn, started, item, terminal]))
  end

  defp receipt(observation) do
    descriptor = Codex.descriptor()

    %{
      "version" => 1,
      "driver_id" => descriptor["id"],
      "descriptor_digest" => Codex.descriptor_digest(),
      "input_hashes" => descriptor["input_hashes"],
      "base_image" => descriptor["base_image"],
      "platform" => "linux/arm64",
      "image_id" => "sha256:" <> hash("synthetic image"),
      "cli_version" => "0.156.0",
      "transport_identity_digest" => CodingTransport.identity_digest(observation),
      "cli_version_output_sha256" => hash("codex-cli 0.156.0\n")
    }
  end

  defp write_receipt(receipt) do
    File.write!(Codex.receipt_path(), Jason.encode!(receipt))
    File.chmod!(Codex.receipt_path(), 0o600)
  end

  defp image_fixture(fixture, id, architecture \\ "arm64") do
    # Extend the existing temporary boundary fixture, never the shared source.
    path = Path.join(fixture.root, "docker")

    File.write!(
      path,
      File.read!(path)
      |> String.replace(
        "print('sha256:synthetic-fixture')",
        "print(json.dumps(daemon.get('image', {})))"
      )
    )

    Fixture.put_daemon(fixture, fixture.endpoint, %{
      "image" => %{"Id" => id, "Os" => "linux", "Architecture" => architecture}
    })
  end

  defp artifact do
    %{
      "files" => %{
        "AGENTS.md" => "# Public synthetic guidance\nRequire review.\n",
        ".codex/config.toml" =>
          "approval_policy = \"on-request\"\n[features]\nshell_tool = false\n",
        ".agents/skills/review-change/SKILL.md" =>
          "---\nname: review-change\n---\nReview changes.\n"
      }
    }
  end

  defp preflight(expected) do
    {:ok, overlay} = Codex.effective_config(artifact(), expected["model"])

    disabled =
      Regex.scan(~r/^features\.([a-z0-9_]+) = false$/m, overlay) |> Enum.map(&Enum.at(&1, 1))

    origins =
      Map.new(
        ~w(model model_provider approval_policy approvals_reviewer default_permissions web_search features.shell_tool features.unified_exec features.multi_agent features.hooks shell_environment_policy.inherit tools.experimental_request_user_input.enabled tools.update_plan.enabled),
        fn key ->
          name =
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

          {key, %{"name" => name, "version" => "sha256:" <> hash("native config layer")}}
        end
      )

    Map.merge(expected, %{
      "version" => 3,
      "cli_version" => "0.156.0",
      "protocol" => "ollama-native-responses-v1",
      "model_provider" => "harnessforge_local",
      "raw_config_approval_policy" => "on-request",
      "approval_policy" => "untrusted",
      "bootstrap_policy" => %{
        "approval_policy_override" => nil,
        "approval_policy" => "untrusted",
        "approvals_reviewer" => "user",
        "active_permission_profile" => %{"id" => "hf_candidate", "extends" => nil},
        "model" => expected["model"],
        "model_provider" => "harnessforge_local",
        "cwd" => "/candidate"
      },
      "approvals_reviewer" => "user",
      "default_permissions" => "hf_candidate",
      "active_permission_profile" => %{"id" => "hf_candidate", "extends" => nil},
      "sandbox_policy" => %{
        "type" => "workspaceWrite",
        "writableRoots" => ["/candidate"],
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => true,
        "excludeSlashTmp" => true
      },
      "network_access" => false,
      "web_search" => "disabled",
      "skip_host_skill_discovery" => true,
      "bundled_skills_enabled" => false,
      "provider" => %{
        "base_url" => "http://model-relay:8080/v1",
        "env_key" => "HARNESSFORGE_RELAY_TOKEN",
        "wire_api" => "responses",
        "requires_openai_auth" => false,
        "request_max_retries" => 0,
        "stream_max_retries" => 0
      },
      "disabled_features" => disabled,
      "enabled_features" => ["shell_tool"],
      "shell_environment" => %{
        "inherit" => "none",
        "ignore_default_excludes" => false,
        "exclude" => [
          "HARNESSFORGE_RELAY_TOKEN",
          "HARNESSFORGE_*",
          "*TOKEN*",
          "*KEY*",
          "*SECRET*"
        ],
        "include_only" => ~w(PATH HOME TMPDIR LANG SHELL),
        "set" => %{
          "PATH" => "/usr/local/bin:/usr/bin:/bin",
          "HOME" => "/candidate",
          "TMPDIR" => "/candidate",
          "LANG" => "C.UTF-8",
          "SHELL" => "/bin/bash"
        }
      },
      "tools" => %{"experimental_request_user_input" => false, "update_plan" => false},
      "managed_requirements" => %{
        "allowed_approval_policies" => ["untrusted"],
        "allowed_approvals_reviewers" => ["user"],
        "allowed_web_search_modes" => ["disabled"],
        "default_permissions" => "hf_candidate",
        "allowed_permission_profiles" => %{"hf_candidate" => true},
        "allow_login_shell" => false,
        "check_for_update_on_startup" => false,
        "feature_requirements" =>
          Map.new(
            ~w(unified_exec unified_exec_tty shell_zsh_fork shell_snapshot shell_snapshot_v2 hooks exec_permission_approvals request_permissions_tool view_image use_legacy_landlock),
            &{&1, false}
          )
          |> Map.put("shell_tool", true)
      },
      "rule_roots" =>
        Enum.map(
          Codex.rule_roots(),
          &%{
            "path" => &1,
            "uid" => expected["rule_directory_uids"][&1],
            "mode" => 0o555,
            "entries" => [],
            "writable" => false
          }
        ),
      "loaded_rule_roots" => Enum.sort(Codex.rule_roots()),
      "initialize" => %{
        "user_agent" => "synthetic native fixture",
        "codex_home" => "/home/harnessforge/.codex",
        "platform_family" => "unix",
        "platform_os" => "linux"
      },
      "environment" => %{
        "environment_id" => "native-local-fixture",
        "cwd" => "/candidate",
        "runtime_workspace_roots" => ["/candidate"],
        "info" => %{
          "shell" => %{"name" => "bash", "path" => "/bin/bash"},
          "cwd" => "file:///candidate"
        },
        "status" => %{"status" => "ready"}
      },
      "origins" => origins,
      "instruction_sources" => ["/candidate/AGENTS.md"],
      "warnings" => [],
      "turns_started" => 0,
      "agent_invocation_verified" => false,
      "command_bridge_qualified" => false
    })
  end

  defp events do
    [
      %{"type" => "thread.started", "thread_id" => "public-synthetic-thread"},
      %{"type" => "turn.started"},
      %{
        "type" => "item.completed",
        "item" => %{
          "id" => "item_1",
          "type" => "file_change",
          "status" => "completed",
          "changes" => [%{"path" => "utility.go", "kind" => "update"}]
        }
      },
      %{
        "type" => "turn.completed",
        "usage" => %{"input_tokens" => 42, "cached_input_tokens" => 0, "output_tokens" => 17}
      }
    ]
  end

  defp jsonl(events), do: Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n"))
  defp hash(bytes), do: Contracts.sha256(bytes)
end
