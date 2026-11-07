defmodule HarnessForge.CompanyAnalysisFixture do
  @moduledoc "Explicitly synthetic company corpus and scripted protocol oracle, never a model-quality claim."
  alias HarnessForge.{Company, Contracts, Evidence, Goals}

  def create!(root) do
    directory = Path.join(root, "synthetic-company-documents")
    File.mkdir_p!(directory)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Synthetic company corpus — workflow demonstration",
        "provider" => "local",
        "directory" => directory
      })

    documents = [
      {"policy.md", "Synthetic policy — January",
       "2026-01-10 approved policy: Every production change requires two reviewers. Café release notes record the decision."},
      {"incidents.md", "Synthetic recurring incidents — February",
       "2026-02-14 incident review: Three emergency releases lacked a rollback rehearsal. The on-call owner requested a recorded rollback check."},
      {"decision.md", "Synthetic decision and abandoned discussion — March",
       "2026-03-02 approved exception: One on-call reviewer may authorize emergency patches. Abandoned discussion: remove every review gate; this was never approved."},
      {"inventory.md", "Synthetic service inventory — examined but uncited",
       "2026-03-05 inventory: The synthetic payments service belongs to the Platform team. This inventory establishes context but supplies no recommendation citation."}
    ]

    sources =
      Enum.map(documents, fn {external_id, title, body} ->
        {:ok, source} =
          Evidence.import_markdown(connection["id"], %{
            "external_id" => external_id,
            "title" => title,
            "body" => body,
            "metadata" => %{"synthetic" => true}
          })

        source
      end)

    {:ok, goal} =
      Goals.add_goal(%{
        "title" => "Synthetic goal: safer emergency releases",
        "owner" => "Synthetic Platform owner",
        "acceptance" =>
          "Every emergency patch records its reviewer, exception reason and successful rollback rehearsal."
      })

    {:ok, profile} =
      Company.save_profile(%{
        "name" => "Synthetic Company — protocol/workflow demonstration",
        "source_ids" => Enum.take(sources, 2) |> Enum.map(& &1["id"]),
        "goal_ids" => [goal["id"]]
      })

    {:ok, repository} =
      Company.create_repository(%{
        "name" => "Synthetic payments",
        "identity" => "synthetic-company/payments",
        "purpose" => "Synthetic emergency release workflow",
        "owner" => "Platform"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Synthetic safer releases",
        "repository_ids" => [repository["id"]],
        "source_ids" => Enum.drop(sources, 2) |> Enum.map(& &1["id"])
      })

    [policy, incidents, decision, uncited] = sources

    findings = [
      finding(
        "practice",
        "The approved policy requires two reviewers.",
        policy,
        "Every production change requires two reviewers."
      ),
      finding(
        "failure",
        "Repeated emergency releases missed rollback rehearsal.",
        incidents,
        "Three emergency releases lacked a rollback rehearsal."
      ),
      finding(
        "decision",
        "A later approved emergency exception permits one reviewer.",
        decision,
        "One on-call reviewer may authorize emergency patches."
      ),
      %{
        "kind" => "conflict",
        "statement" =>
          "General policy and emergency exception differ; a human must resolve the applicable scope.",
        "citations" => [
          citation(policy, "Every production change requires two reviewers."),
          citation(decision, "One on-call reviewer may authorize emergency patches.")
        ]
      },
      finding(
        "discussion",
        "Removing every gate was discussed but never approved.",
        decision,
        "Abandoned discussion: remove every review gate; this was never approved."
      ),
      %{
        "kind" => "unknown",
        "statement" =>
          "The corpus does not establish whether the emergency exception remains current outside these captured documents.",
        "citations" => []
      }
    ]

    report = %{
      "findings" => findings,
      "recommendation" => %{
        "rule" => "Synthetic proposal: record the emergency exception and named reviewer.",
        "workflow" =>
          "Record scope and owner; rehearse rollback; obtain the applicable review before release.",
        "check" =>
          "Confirm a reviewer, exception reason and rollback rehearsal result are recorded.",
        "evaluation_criterion" =>
          "A representative emergency patch lacking any required record must fail review.",
        "goal_rationale" =>
          "The goal addresses recurring rollback failures while retaining the explicitly approved emergency exception.",
        "status" => "conflicted"
      },
      "uncertainty" =>
        "Synthetic provider and corpus: protocol/workflow demonstration. A human must resolve the general-policy versus emergency-exception scope; real-company model quality is unqualified."
    }

    input = %{
      "project_id" => project["id"],
      "goal_id" => goal["id"],
      "goal_content_hash" => Goals.content_hash(goal),
      "source_refs" =>
        sources
        |> Enum.map(fn s ->
          %{
            "source_id" => s["id"],
            "revision_id" => s["latest_revision"]["id"],
            "body_hash" => s["latest_revision"]["body_hash"]
          }
        end)
        |> Enum.sort_by(& &1["source_id"])
    }

    %{
      input: input,
      sources: sources,
      uncited_source: uncited,
      goal: goal,
      profile: profile,
      project: project,
      repository: repository,
      report: report,
      connection: connection,
      oracle: %{
        "synthetic" => true,
        "finding_kinds" => Enum.map(findings, & &1["kind"]),
        "uncited_source_id" => uncited["id"],
        "input_digest" => Contracts.digest(input)
      }
    }
  end

  def response(report),
    do: %{
      "response" => Jason.encode!(report),
      "done" => true,
      "prompt_eval_count" => 200,
      "eval_count" => 200
    }

  def plan_attrs(fixture, claim),
    do: %{
      "name" => "synthetic-company-harness",
      "package_version" => "1.0.0",
      "project_id" => fixture.project["id"],
      "repository_ids" => [fixture.repository["id"]],
      "claim_refs" => [Map.take(claim, ~w(id revision_hash))],
      "goal_ids" => [fixture.goal["id"]],
      "template_ids" => ["reviewed-change-v1"],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => 10, "timeout_seconds" => 120},
      "milestones" => []
    }

  def decision(dto, kind \\ "approve"),
    do: %{
      "actor" => "Synthetic human reviewer",
      "decision" => kind,
      "expected_revision_hash" => dto["revision_hash"]
    }

  defp finding(kind, statement, source, snippet),
    do: %{"kind" => kind, "statement" => statement, "citations" => [citation(source, snippet)]}

  defp citation(source, snippet) do
    {offset, length} = :binary.match(source["latest_revision"]["body"], snippet)

    %{
      "source_id" => source["id"],
      "revision_id" => source["latest_revision"]["id"],
      "start_byte" => offset,
      "end_byte" => offset + length,
      "snippet" => snippet
    }
  end
end
