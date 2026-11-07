defmodule HarnessForge.ExecutionTest do
  use ExUnit.Case, async: false
  alias HarnessForge.Execution
  alias HarnessForge.Execution.Docker

  test "profile identity is deterministic and denies caller-selected commands" do
    assert Docker.profile_digest() == HarnessForge.Contracts.digest(Docker.profile())

    assert {:error, {:execution_start_failed, :unsupported_execution_kind}} =
             Execution.start(Ecto.UUID.generate(), "/bin/echo")

    assert {:error, {:execution_start_failed, :invalid_run_id}} =
             Execution.start("--privileged", :version)

    assert {:error, :cleanup_failed} = Execution.cleanup("someone-elses-container")
  end

  test "effective container inspection rejects missing isolation controls" do
    assert {:error, :container_profile_mismatch} = Docker.verify_profile(%{})

    assert {:error, :container_profile_mismatch} =
             Docker.verify_profile(%{"Config" => %{"User" => "0"}})
  end

  @tag :docker
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "actual pinned OpenCode and hostile checks run inside enforced confinement" do
    assert {:ok, _} = Execution.probe()

    for {kind, expected} <- [version: "1.19.5", containment: "containment_checks_passed"] do
      id = Ecto.UUID.generate()
      on_exit(fn -> Execution.cleanup(id) end)
      assert {:ok, handle} = Execution.start(id, kind)
      assert {:ok, inspection} = Execution.inspect_owned(id)
      assert :ok = Docker.verify_profile(inspection)
      assert {:ok, result} = Execution.await(handle)
      assert result["outcome"] == "passed", inspect(result)
      assert String.trim(result["output"]) == expected
      assert result["cleanup_status"] == "complete"
      assert {:error, :container_unavailable_or_not_owned} = Execution.inspect_owned(id)
    end
  end

  @tag :docker
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "actual effective OpenCode configuration disables providers and plugins" do
    id = Ecto.UUID.generate()
    on_exit(fn -> Execution.cleanup(id) end)
    assert {:ok, handle} = Execution.start(id, :config)
    assert {:ok, result} = Execution.await(handle)
    assert result["outcome"] == "passed", inspect(result)
    config = Jason.decode!(result["output"])
    assert config["enabled_providers"] == []
    assert config["plugin"] == []
    assert config["mcp"] == %{}
    assert result["cleanup_status"] == "complete"
  end

  @tag :docker
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "real cancellation kills only owned container and verifies absence" do
    id = Ecto.UUID.generate()
    on_exit(fn -> Execution.cleanup(id) end)
    assert {:ok, handle} = Execution.start(id, :timeout_probe)
    task = Task.async(fn -> Execution.await(handle) end)
    Process.sleep(400)
    assert :ok = Execution.cancel(id)
    assert {:ok, %{"cleanup_status" => "complete"}} = Task.await(task, 20_000)
    assert {:error, :container_unavailable_or_not_owned} = Execution.inspect_owned(id)
  end

  @tag :docker
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "actual flood is bounded and container is removed" do
    id = Ecto.UUID.generate()
    on_exit(fn -> Execution.cleanup(id) end)
    assert {:ok, handle} = Execution.start(id, :output_probe)
    assert {:ok, result} = Execution.await(handle)
    assert result["outcome"] == "failed"
    assert result["reason"] == "output_limit"
    assert result["cleanup_status"] == "complete"
  end

  @tag :docker
  @tag timeout: 30_000
  @tag skip: System.get_env("HARNESSFORGE_DOCKER_TESTS") != "1"
  test "actual wall time limit stops a running container" do
    id = Ecto.UUID.generate()
    on_exit(fn -> Execution.cleanup(id) end)
    assert {:ok, handle} = Execution.start(id, :timeout_probe)
    assert {:ok, result} = Execution.await(handle)
    assert result["outcome"] == "timed_out"
    assert result["reason"] == "time_limit"
    assert result["cleanup_status"] == "complete"
    assert result["duration_ms"] < 25_000
  end
end
