defmodule HarnessForge.WorkspacesTest do
  use ExUnit.Case, async: false

  test "SQLite ownership excludes another OS connection and releases cleanly" do
    root = Path.join(System.tmp_dir!(), "hf-lock-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, lock} = HarnessForge.Workspaces.acquire(root)
    assert {:error, :workspace_in_use} = HarnessForge.Workspaces.acquire(root)
    assert :ok = HarnessForge.Workspaces.release(lock)
    assert {:ok, second} = HarnessForge.Workspaces.acquire(root)
    assert :ok = HarnessForge.Workspaces.release(second)
  end
end
