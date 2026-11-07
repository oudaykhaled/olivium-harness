defmodule HarnessForge.Jobs.CaptureTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.Evidence.Store

  test "foreign and malformed jobs cannot dispatch capture" do
    assert {:cancel, :workspace_mismatch} =
             HarnessForge.Jobs.Capture.perform(%Oban.Job{
               args: %{"workspace_id" => "foreign", "run_id" => Ecto.UUID.generate()}
             })

    assert {:cancel, :invalid_job} =
             HarnessForge.Jobs.Capture.perform(%Oban.Job{
               args: %{
                 "workspace_id" => Store.workspace(),
                 "run_id" => Ecto.UUID.generate(),
                 "body" => "forbidden"
               }
             })

    assert {:cancel, :invalid_job} =
             HarnessForge.Jobs.PassageIndex.perform(%Oban.Job{
               args: %{
                 "workspace_id" => Store.workspace(),
                 "revision_id" => Ecto.UUID.generate(),
                 "body" => "forbidden"
               }
             })
  end
end
