defmodule HarnessForge.Privacy.PurgeSynchronizationTest do
  use ExUnit.Case, async: false

  alias HarnessForge.Privacy.Purge
  alias HarnessForge.Workspaces

  setup do
    previous = Workspaces.current_id()
    workspace = Ecto.UUID.generate()
    Application.put_env(:harness_forge, :workspace_id, workspace)
    on_exit(fn -> Application.put_env(:harness_forge, :workspace_id, previous) end)
    %{workspace: workspace}
  end

  test "a nested fence cannot release the outer owner's lock", %{workspace: workspace} do
    assert :outer_result =
             Purge.synchronize(fn ->
               assert {:ok, :inner_result} = Purge.synchronize(fn -> {:ok, :inner_result} end)
               refute competing_caller_can_lock?(workspace)
               :outer_result
             end)

    assert competing_caller_can_lock?(workspace)
  end

  test "caught nested exceptions, throws and exits retain the outer fence", %{
    workspace: workspace
  } do
    assert :outer_result =
             Purge.synchronize(fn ->
               assert_raise RuntimeError, "synthetic nested failure", fn ->
                 Purge.synchronize(fn -> raise "synthetic nested failure" end)
               end

               refute competing_caller_can_lock?(workspace)

               assert catch_throw(Purge.synchronize(fn -> throw(:synthetic_throw) end)) ==
                        :synthetic_throw

               refute competing_caller_can_lock?(workspace)

               assert catch_exit(Purge.synchronize(fn -> exit(:synthetic_exit) end)) ==
                        :synthetic_exit

               refute competing_caller_can_lock?(workspace)
               :outer_result
             end)

    assert competing_caller_can_lock?(workspace)
  end

  test "an outer failure releases ownership and does not leave a nested-call marker", %{
    workspace: workspace
  } do
    assert_raise RuntimeError, "synthetic outer failure", fn ->
      Purge.synchronize(fn -> raise "synthetic outer failure" end)
    end

    assert competing_caller_can_lock?(workspace)

    assert :new_owner =
             Purge.synchronize(fn ->
               refute competing_caller_can_lock?(workspace)
               :new_owner
             end)

    assert competing_caller_can_lock?(workspace)
  end

  test "nested ownership remains distinct for each workspace", %{workspace: workspace} do
    other_workspace = Ecto.UUID.generate()

    assert :outer_result =
             Purge.synchronize(fn ->
               Application.put_env(:harness_forge, :workspace_id, other_workspace)

               try do
                 assert :other_result =
                          Purge.synchronize(fn ->
                            refute competing_caller_can_lock?(workspace)
                            refute competing_caller_can_lock?(other_workspace)
                            :other_result
                          end)
               after
                 Application.put_env(:harness_forge, :workspace_id, workspace)
               end

               refute competing_caller_can_lock?(workspace)
               assert competing_caller_can_lock?(other_workspace)
               :outer_result
             end)

    assert competing_caller_can_lock?(workspace)
    assert competing_caller_can_lock?(other_workspace)
  end

  # Zero retries probes actual independent-process lock ownership, without sleeps
  # or treating the absence of an asynchronously scheduled callback as success.
  defp competing_caller_can_lock?(workspace) do
    Task.async(fn ->
      lock = {{Purge, workspace}, self()}
      acquired = :global.set_lock(lock, [node()], 0)
      if acquired, do: :global.del_lock(lock, [node()])
      acquired
    end)
    |> Task.await(5_000)
  end
end
