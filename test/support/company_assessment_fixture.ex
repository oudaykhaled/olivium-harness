defmodule HarnessForge.CompanyAssessmentFixture do
  @moduledoc "Public synthetic domain fixture; fixed oracle observations are testimony, never actual work or model-quality evidence."
  alias HarnessForge.{Company, Contracts, Decisions, Evidence, Goals, Harnesses}
  alias HarnessForge.Company.Analysis
  @directory Path.expand("../fixtures/company_assessment", __DIR__)

  def oracle, do: File.read!(Path.join(@directory, "task-oracle.json")) |> Jason.decode!()

  def server_opts,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.digest(%{"fixture" => "controlled server session"}),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]

  def create!(root) do
    oracle = oracle()
    directory = Path.join(root, "assessment-public-corpus")
    File.mkdir_p!(directory)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Public synthetic Mercury corpus",
        "provider" => "local",
        "directory" => directory
      })

    sources =
      Enum.map(~w(01-policy.md 02-incident.md 03-decision.md 04-discussion.md), fn name ->
        {:ok, source} =
          Evidence.import_markdown(connection["id"], %{
            "external_id" => name,
            "title" => "Synthetic Mercury " <> name,
            "body" => File.read!(Path.join([@directory, "corpus", name]))
          })

        source
      end)

    {:ok, goal} = Goals.add_goal(oracle["goal"])

    {:ok, outside_goal} =
      Goals.add_goal(%{
        "title" => "Synthetic documentation follow-up",
        "owner" => "Synthetic operator",
        "acceptance" => "Record the separately scoped documentation review."
      })

    {:ok, profile} =
      Company.save_profile(%{
        "name" => "Synthetic Mercury",
        "source_ids" => Enum.map(Enum.take(sources, 2), & &1["id"]),
        "goal_ids" => [goal["id"], outside_goal["id"]]
      })

    {:ok, repository} =
      Company.create_repository(%{
        "name" => "Synthetic release service",
        "identity" => "synthetic-mercury/release",
        "purpose" => "Public emergency-release exercise",
        "owner" => "Synthetic platform"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Synthetic Mercury readiness",
        "repository_ids" => [repository["id"]],
        "source_ids" => Enum.map(Enum.drop(sources, 2), & &1["id"])
      })

    [policy, incident, decision, uncited] = sources

    finding_rows = [
      {"practice", "A named reviewer and recorded exception are required.", policy,
       "An emergency release requires a named reviewer before merge and a recorded exception when normal review cannot complete."},
      {"failure", "The exercise missed review, rollback and communication ownership.", incident,
       "The August exercise used an untested rollback and an unnamed reviewer."},
      {"decision", "The incident review chose rollback rehearsal and a communication owner.",
       decision,
       "The incident review chose to rehearse rollback before the next emergency release and identify the communication owner."}
    ]

    report_findings =
      Enum.map(finding_rows, fn {kind, statement, source, snippet} ->
        %{
          "kind" => kind,
          "statement" => statement,
          "citations" => [citation_input(source, snippet)]
        }
      end)

    report = %{
      "findings" => report_findings,
      "recommendation" => %{
        "rule" => oracle["rejected_guidance_must_be_absent_from_export"],
        "workflow" =>
          "Review the emergency record, rehearse rollback and acknowledge communication ownership.",
        "check" =>
          "Check named review, observed rollback readiness and communication acknowledgement.",
        "evaluation_criterion" =>
          "The public synthetic representative task declares all three conditions.",
        "goal_rationale" => "Address the captured emergency-release failures.",
        "status" => "supported"
      },
      "uncertainty" =>
        "Public synthetic fixture. Structural provenance and owner-reported observations do not establish semantic support or real work."
    }

    refs =
      Enum.map(sources, fn source ->
        %{
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "body_hash" => source["latest_revision"]["body_hash"]
        }
      end)
      |> Enum.sort_by(& &1["source_id"])

    context = %{
      "profile" => Map.take(profile, ~w(id content_hash)),
      "project" => Map.take(project, ~w(id content_hash)),
      "sources" => refs
    }

    guidance = Map.take(report["recommendation"], ~w(rule workflow check evaluation_criterion))

    citations =
      report_findings
      |> Enum.flat_map(& &1["citations"])
      |> Enum.map(fn input ->
        {:ok, citation} =
          Evidence.citation(input["revision_id"], input["start_byte"], input["end_byte"])

        citation
      end)

    basis = %{
      "kind" => "company_analysis",
      "version" => 1,
      "project_id" => project["id"],
      "goal_id" => goal["id"],
      "goal_content_hash" => Goals.content_hash(goal),
      "context" => context,
      "context_digest" => Contracts.digest(context),
      "report" => report,
      "guidance" => guidance,
      "provider" => "ollama",
      "model" => "synthetic:assessment-fixture",
      "config_fingerprint" => Contracts.digest(%{"synthetic" => true}),
      "run_id" => Ecto.UUID.generate(),
      "request_id" => Ecto.UUID.generate(),
      "review_resolution" => nil
    }

    {:ok, proposed} =
      Evidence.create_claim(%{
        "text" => Analysis.render_guidance(guidance),
        "basis" => basis,
        "citations" => citations
      })

    {:ok, rejected} = Decisions.decide(proposed["id"], decision(proposed, "reject"))

    edits =
      guidance
      |> Map.put("rule", oracle["edited_guidance_expected_in_export"])
      |> Map.put(
        "review_resolution",
        "Synthetic human review retained the named review, rollback rehearsal and communication owner; discussion did not approve removing ownership."
      )

    {:ok, revised} = Analysis.revise(rejected["id"], rejected["revision_hash"], edits)
    {:ok, claim} = Decisions.decide(revised["id"], decision(revised))

    plan_attrs = %{
      "name" => "synthetic-mercury-harness",
      "package_version" => "1.0.0",
      "project_id" => project["id"],
      "repository_ids" => [repository["id"]],
      "claim_refs" => [Map.take(claim, ~w(id revision_hash))],
      "goal_ids" => [goal["id"], outside_goal["id"]],
      "template_ids" => ["reviewed-change-v1"],
      "runtime" => "opencode",
      "runtime_version" => "unqualified",
      "execution" => %{"max_turns" => 10, "timeout_seconds" => 120},
      "milestones" => []
    }

    {:ok, plan} = Company.create_plan(plan_attrs)
    {:ok, plan} = Company.decide_plan(plan["id"], decision(plan))
    {:ok, artifact} = Harnesses.build_plan(plan["id"], plan["revision_hash"])

    binding = %{
      "plan_id" => plan["id"],
      "expected_plan_revision_hash" => plan["revision_hash"],
      "artifact_digest" => artifact["digest"],
      "goal_id" => goal["id"],
      "goal_content_hash" => Goals.content_hash(goal)
    }

    fixture = %{
      oracle: oracle,
      connection: connection,
      sources: sources,
      uncited_source: uncited,
      goal: goal,
      outside_goal: outside_goal,
      profile: profile,
      repository: repository,
      project: project,
      report: report,
      rejected: rejected,
      claim: claim,
      required_refs: [Map.take(claim, ~w(id revision_hash))],
      plan_attrs: plan_attrs,
      plan: plan,
      artifact: artifact,
      binding: binding
    }

    Map.put(fixture, :freeze_attrs, rubric_attrs(fixture))
  end

  def rubric_attrs(fixture) do
    obligations =
      Enum.map(fixture.oracle["obligations"], fn row ->
        row
        |> Map.take(~w(id kind text mandatory))
        |> Map.put(
          "claim_refs",
          if(row["kind"] == "approved_analysis_guidance", do: fixture.required_refs, else: [])
        )
      end)

    Map.merge(fixture.binding, %{"task" => fixture.oracle["task"], "obligations" => obligations})
  end

  def assessment_attrs(fixture, rubric) do
    {:ok, attempt} =
      HarnessForge.Company.Assessments.new_attempt(
        rubric["id"],
        rubric["revision_hash"],
        server_opts()
      )

    results =
      Enum.map(fixture.oracle["obligations"], fn row ->
        %{
          "obligation_id" => row["id"],
          "status" => "met",
          "observation" => row["met_observation"]
        }
      end)

    %{
      "rubric_id" => rubric["id"],
      "expected_rubric_hash" => rubric["revision_hash"],
      "attempt_id" => attempt["attempt_id"],
      "attempt_token" => attempt["attempt_token"],
      "task_status" => "completed",
      "critical_status" => "none",
      "judgment" => "accepted",
      "results" => results
    }
  end

  def decision(dto, kind \\ "approve"),
    do: %{
      "actor" => "Synthetic human reviewer",
      "decision" => kind,
      "expected_revision_hash" => dto["revision_hash"]
    }

  defp citation_input(source, snippet) do
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
