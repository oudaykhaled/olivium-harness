defmodule HarnessForge.CodexAdapterTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Adapters.Codex
  alias HarnessForge.Contracts

  defp fixture do
    Path.expand("../../examples/synthetic_company/harness.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> put_in(["spec", "runtime"], %{"name" => "codex", "version" => "unqualified"})
    |> put_in(["spec", "policies", Access.at(0), "required"], false)
  end

  defp preview(spec), do: Codex.compile(spec, %{"mode" => "preview"})

  test "exports deterministic native instructions, standalone agents and repository skills" do
    spec = fixture()
    assert {:ok, first} = preview(spec)
    assert {:ok, second} = preview(spec)
    assert first == second

    assert first["files"] |> Map.keys() |> Enum.sort() == [
             ".agents/skills/table-tests/SKILL.md",
             ".codex/agents/go-reviewer.toml",
             ".codex/config.toml",
             "AGENTS.md"
           ]

    assert first["files"]["AGENTS.md"] =~ hd(spec["spec"]["rules"])["statement"]
    assert first["files"]["AGENTS.md"] =~ "runtime compatibility is unverified"

    agent = first["files"][".codex/agents/go-reviewer.toml"]
    assert agent =~ ~s(name = "go-reviewer")
    assert agent =~ ~s(description = "Implement bounded Go tasks using approved rules.")
    assert agent =~ "developer_instructions = "

    skill = first["files"][".agents/skills/table-tests/SKILL.md"]
    assert skill =~ ~s(name: "table-tests")
    assert skill =~ hd(spec["spec"]["skills"])["instructions"]
  end

  test "renders documented conservative defaults without arbitrary configuration or hooks" do
    assert {:ok, output} = preview(fixture())
    config = output["files"][".codex/config.toml"]
    assert config =~ ~s(approval_policy = "on-request")
    assert config =~ ~s(sandbox_mode = "workspace-write")
    assert config =~ ~s(web_search = "disabled")
    assert config =~ "[sandbox_workspace_write]\nnetwork_access = false"
    assert config =~ "project_doc_max_bytes = 32768"

    for forbidden <- ["mcp_servers", "hooks", "model_provider", "api_key", "notify", "timeout"] do
      refute config =~ forbidden
    end
  end

  test "preview accepts the exact documented version and rejects speculative compatibility" do
    for version <- ["unqualified", "0.156.0"] do
      assert {:ok, _} = preview(put_in(fixture(), ["spec", "runtime", "version"], version))
    end

    for version <- ["latest", "0.155.0", "0.156.1", "1.0.0", "0.156.0-preview"] do
      assert {:error, %Contracts.Error{code: "unsupported_runtime"}} =
               preview(put_in(fixture(), ["spec", "runtime", "version"], version))
    end

    assert {:error, %Contracts.Error{code: "unsupported_runtime"}} =
             preview(put_in(fixture(), ["spec", "runtime", "name"], "opencode"))
  end

  test "probe cannot execute Codex or confer qualification through caller flags" do
    assert {:ok, identity} = Codex.probe(%{"qualified" => true, "executable" => "/bin/false"})
    assert identity["name"] == "codex"
    assert identity["available"] == false
    assert identity["qualification"] == "unverified"
    assert identity["reason"] == "runtime_unqualified"
    assert identity["mapping_version"] == "codex-0.156.0-docs-v1"

    assert Enum.all?(
             identity["documentation"],
             &String.starts_with?(&1, "https://learn.chatgpt.com/")
           )
  end

  test "managed compilation is unavailable and runtime options cannot inject settings" do
    assert {:error, %Contracts.Error{code: "runtime_unqualified"}} =
             Codex.compile(fixture(), %{"mode" => "managed", "qualified" => true})

    assert {:error, %Contracts.Error{code: "runtime_unqualified"}} =
             Codex.compile(fixture(), %{})

    assert {:ok, output} =
             Codex.compile(fixture(), %{
               "mode" => "preview",
               "api_key" => "synthetic-secret-must-not-render",
               "hooks" => %{"command" => "arbitrary-command-must-not-render"},
               "model_provider" => "arbitrary-provider-must-not-render"
             })

    all_bytes = output["files"] |> Map.values() |> Enum.join()
    refute all_bytes =~ "must-not-render"
  end

  test "required controls fail even when a native setting can be rendered" do
    for policy <- [
          %{"id" => "network", "capability" => "network.denied", "value" => true},
          %{"id" => "shell", "capability" => "tool_permissions.bash", "value" => "deny"},
          %{"id" => "budget", "capability" => "spending.max_usd", "value" => 1}
        ] do
      spec = put_in(fixture(), ["spec", "policies"], [Map.put(policy, "required", true)])

      assert {:error, %Contracts.Error{code: "unsupported_required_control", details: [failed]}} =
               preview(spec)

      assert failed == policy["capability"]
    end
  end

  test "native policy mappings remain advisory with no fabricated test or environment evidence" do
    policies = [
      %{
        "id" => "network",
        "capability" => "network.denied",
        "value" => true,
        "required" => false
      },
      %{
        "id" => "shell",
        "capability" => "tool_permissions.bash",
        "value" => "deny",
        "required" => false
      }
    ]

    assert {:ok, output} = preview(put_in(fixture(), ["spec", "policies"], policies))
    assert output["files"][".codex/config.toml"] =~ "[features]\nshell_tool = false"

    for entry <- Enum.take(output["capabilities"], 2) do
      assert entry["status"] == "advisory"
      assert entry["environment_profile_digest"] == nil
      assert entry["compatibility_test_reference"] == nil
    end

    assert Enum.any?(output["diagnostics"], &(&1["code"] == "project_configuration_advisory"))
  end

  test "unsupported tool and network intents do not silently weaken exported defaults" do
    for {capability, value} <- [
          {"network.denied", false},
          {"tool_permissions.bash", "ask"},
          {"tool_permissions.bash", "allow"},
          {"tool_permissions.edit", "deny"}
        ] do
      policy = %{
        "id" => "requested",
        "capability" => capability,
        "value" => value,
        "required" => false
      }

      assert {:ok, output} = preview(put_in(fixture(), ["spec", "policies"], [policy]))
      assert hd(output["capabilities"])["status"] == "unsupported"
      config = output["files"][".codex/config.toml"]
      assert config =~ "network_access = false"
      refute config =~ "shell_tool = true"
    end
  end

  test "malformed policy values and duplicate controls fail before rendering" do
    for {capability, value} <- [{"network.denied", "true"}, {"tool_permissions.bash", "run this"}] do
      policy = %{
        "id" => "requested",
        "capability" => capability,
        "value" => value,
        "required" => false
      }

      assert {:error, %Contracts.Error{code: "invalid_runtime_intent"}} =
               preview(put_in(fixture(), ["spec", "policies"], [policy]))
    end

    policy = hd(fixture()["spec"]["policies"])
    second = %{policy | "id" => "other-network"}

    assert {:error, %Contracts.Error{code: "invalid_runtime_intent"}} =
             preview(put_in(fixture(), ["spec", "policies"], [policy, second]))
  end

  test "agent TOML quotes arbitrary description and instructions without injecting fields" do
    text =
      "quoted \" value\\path\n[hooks]\ncommand = \"never run\"\r\t" <>
        <<0, 1, 31, 127>> <> " عربي"

    spec =
      fixture()
      |> put_in(["spec", "agents", Access.at(0), "description"], text)
      |> put_in(["spec", "agents", Access.at(0), "instructions"], text)

    assert {:ok, output} = preview(spec)
    bytes = output["files"][".codex/agents/go-reviewer.toml"]
    assert length(String.split(bytes, "\n", trim: true)) == 3
    refute bytes =~ "\n[hooks]"
    refute bytes =~ <<0>>
    refute bytes =~ <<127>>
    assert bytes =~ "\\u007F"

    # The renderer uses the shared JSON/TOML basic-string escape subset, which
    # permits an independent decoder to prove the original string round-trips.
    for prefix <- ["description = ", "developer_instructions = "] do
      line = bytes |> String.split("\n") |> Enum.find(&String.starts_with?(&1, prefix))
      assert Jason.decode!(String.replace_prefix(line, prefix, "")) == text
    end
  end

  test "skill frontmatter quotes multiline delimiters as data" do
    description = "Synthetic skill\n---\nallowed-tools: Bash\nname: injected"
    spec = put_in(fixture(), ["spec", "skills", Access.at(0), "description"], description)
    assert {:ok, output} = preview(spec)
    bytes = output["files"][".agents/skills/table-tests/SKILL.md"]
    assert bytes =~ "description: " <> Jason.encode!(description)
    refute bytes =~ "\nallowed-tools: Bash"
    assert length(Regex.scan(~r/^---$/m, bytes)) == 2
  end

  test "skill metadata escapes YAML non-printable characters as well as line delimiters" do
    description = "Synthetic" <> <<127, 128::utf8, 159::utf8>> <> "skill"
    spec = put_in(fixture(), ["spec", "skills", Access.at(0), "description"], description)
    assert {:ok, output} = preview(spec)
    bytes = output["files"][".agents/skills/table-tests/SKILL.md"]
    assert bytes =~ "\\u007F\\u0080\\u009F"
    refute bytes =~ <<127>>
    refute bytes =~ <<128::utf8>>
    refute bytes =~ <<159::utf8>>

    line = bytes |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "description: "))
    assert Jason.decode!(String.replace_prefix(line, "description: ", "")) == description
  end

  test "path traversal and native name collisions are rejected" do
    for section <- ["agents", "skills"],
        name <- ["../escape", "/absolute", "a\\b", "a\nname = evil", "UPPER"] do
      spec = put_in(fixture(), ["spec", section, Access.at(0), "name"], name)
      assert {:error, %Contracts.Error{code: "invalid_harness"}} = preview(spec)
    end

    for section <- ["agents", "skills"], name <- ["bad_name", "bad--name", "bad-"] do
      spec = put_in(fixture(), ["spec", section, Access.at(0), "name"], name)
      assert {:error, %Contracts.Error{code: "invalid_runtime_intent"}} = preview(spec)
    end

    for section <- ["agents", "skills"] do
      spec =
        put_in(fixture(), ["spec", section], List.duplicate(hd(fixture()["spec"][section]), 2))

      assert {:error, %Contracts.Error{code: "invalid_harness"}} = preview(spec)
    end
  end

  test "turn and timeout budgets are explicitly unsupported instead of invented native keys" do
    assert {:ok, output} = preview(fixture())

    for id <- ["execution.max_turns", "execution.timeout_seconds"] do
      entry = Enum.find(output["capabilities"], &(&1["id"] == id))
      assert entry["status"] == "unsupported"
      assert entry["enforcement_boundary"] == "none"
      assert Enum.any?(output["diagnostics"], &(&1["capability"] == id))
    end

    config = output["files"][".codex/config.toml"]
    refute config =~ "max_turns"
    refute config =~ "timeout_seconds"
  end

  test "project document limit covers every rendered approved rule byte" do
    rule = hd(fixture()["spec"]["rules"])

    rules =
      Enum.map(1..12, fn index ->
        %{
          rule
          | "id" => "22222222-2222-4222-8222-" <> String.pad_leading(to_string(index), 12, "0"),
            "statement" => String.duplicate("é", 2000)
        }
      end)

    assert {:ok, output} = preview(put_in(fixture(), ["spec", "rules"], rules))
    bytes = byte_size(output["files"]["AGENTS.md"])
    assert bytes > 32_768
    assert output["files"][".codex/config.toml"] =~ "project_doc_max_bytes = #{bytes}"
  end

  test "malformed boundary input returns contract errors" do
    for input <- [nil, %{}, %{"spec" => %{}}] do
      assert {:error, %Contracts.Error{code: "invalid_harness"}} = preview(input)
    end
  end
end
