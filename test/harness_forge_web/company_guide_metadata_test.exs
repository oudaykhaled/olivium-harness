defmodule HarnessForgeWeb.CompanyGuideMetadataTest do
  use ExUnit.Case, async: true
  alias HarnessForgeWeb.Company.Guide

  @source_id "10000000-0000-4000-8000-000000000001"
  @revision_id "20000000-0000-4000-8000-000000000001"

  test "saved guide counts an eligible assigned metadata summary without fabricating a body" do
    source = source()
    refute Map.has_key?(source["latest_revision"], "body")
    assert Guide.project(assigns([source])).source_count == 1

    for unavailable <- [
          Map.put(source, "eligible", false),
          Map.put(source, "status", "revoked"),
          put_in(source, ["latest_revision", "body_bytes"], 0),
          put_in(source, ["latest_revision", "body_hash"], "invalid"),
          put_in(source, ["latest_revision", "source_id"], "foreign")
        ] do
      assert Guide.project(assigns([unavailable])).source_count == 0
    end
  end

  test "legacy full captured DTO remains compatible and unassigned sources do not count" do
    legacy =
      source()
      |> Map.delete("eligible")
      |> Map.put("latest_revision_id", @revision_id)
      |> put_in(["latest_revision", "body"], "Actual captured text")

    assert Guide.project(assigns([legacy])).source_count == 1

    other = Map.put(source(), "id", "10000000-0000-4000-8000-000000000002")
    assert Guide.project(assigns([other])).source_count == 0
  end

  test "a saved project without approved guidance leads to corpus analysis without source assignment" do
    data = Guide.project(assigns([]))
    assert data.next.corpus
    assert data.next.section == nil
    assert data.next.message =~ "Manual per-document assignments are not required"
    assert data.claim_count == 0
    refute Enum.find(data.tasks, &(&1.name == "evidence")).saved
  end

  defp source do
    %{
      "id" => @source_id,
      "workspace_id" => "synthetic-workspace",
      "status" => "active",
      "eligible" => true,
      "latest_revision" => %{
        "id" => @revision_id,
        "source_id" => @source_id,
        "workspace_id" => "synthetic-workspace",
        "body_hash" => String.duplicate("a", 64),
        "body_bytes" => 19
      }
    }
  end

  defp assigns(sources) do
    %{
      sources: sources,
      repositories: [%{"id" => "repository"}],
      profile: %{"id" => "profile", "payload" => %{"name" => "Synthetic company"}},
      projects: [
        %{
          "id" => "project",
          "payload" => %{
            "name" => "Synthetic project",
            "repository_ids" => ["repository"],
            "source_ids" => [@source_id]
          }
        }
      ],
      guide_project_id: "project",
      approved: [],
      company_load_error: false,
      data_errors: [],
      selected_plan: nil,
      plans: [],
      company_reset_token: 0,
      claim_review_count: 0,
      plan_preflight: :unavailable,
      built_artifact: nil
    }
  end
end
