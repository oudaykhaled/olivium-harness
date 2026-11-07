defmodule HarnessForgeWeb.CompanyAssessmentPresentationTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias HarnessForgeWeb.Company.{Assessment, Guide, Plan}

  @generation String.duplicate("e", 32)
  @plan_id "10000000-0000-4000-8000-000000000001"
  @goal_id "20000000-0000-4000-8000-000000000001"
  @claim_id "30000000-0000-4000-8000-000000000001"
  @rubric_id "40000000-0000-4000-8000-000000000001"
  @assessment_id "50000000-0000-4000-8000-000000000001"
  @source_id "60000000-0000-4000-8000-000000000001"
  @revision_id "70000000-0000-4000-8000-000000000001"
  @hash String.duplicate("a", 64)
  @digest String.duplicate("b", 64)
  @qualification "Owner-reported assessment; not independently verified; no runtime or release qualification."
  @oracle_path Path.expand("../fixtures/company_assessment/task-oracle.json", __DIR__)

  test "scope requires an explicit paired goal choice and exposes no result controls" do
    f = fixture()
    state = Map.put(f.state, "stage", "scope")
    html = panel(state)

    assert attr(html, "#company-assessment-scope-form", "phx-submit") == [
             "assessment_goal_change"
           ]

    assert attr(html, "#company-assessment-scope-form", "phx-change") == []
    assert attr(html, "#company-assessment-goal", "name") == ["scope[goal_snapshot]"]
    assert attr(html, "#company-assessment-goal option[selected]", "value") == [""]

    assert (f.goal["id"] <> ":" <> f.goal["content_hash"]) in attr(
             html,
             "#company-assessment-goal option",
             "value"
           )

    assert text(html) =~ @qualification
    assert text(html) =~ @digest
    assert Enum.empty?(query(html, "#company-assessment-results-form"))
    assert Enum.empty?(query(html, "[name='assessment[judgment]']"))
  end

  test "fixed independent four-obligation oracle is rendered before results with explicit mapping controls" do
    f = fixture()
    html = panel(f.state)
    ids = attr(html, "input[name$='[id]']", "value")

    assert Enum.sort(ids) ==
             Enum.sort(~w(goal-readiness named-review rollback-ready communication-owner))

    assert text(html) =~ "Mandatory obligations · 4 of at most 20"
    assert text(html) =~ "Editable suggestions — review before freezing"

    assert attr(html, "#company-assessment-rubric-form", "phx-change") == [
             "assessment_rubric_change"
           ]

    assert attr(html, "#company-assessment-rubric-form", "phx-submit") == [
             "assessment_rubric_freeze"
           ]

    assert attr(html, "#company-assessment-rubric-form", "data-company-reset-token") == ["9"]
    assert attr(html, "input[name='assessment_event_generation']", "value") == [@generation]
    assert Enum.count(query(html, "input[type='checkbox'][checked]")) == 3
    assert Enum.uniq(attr(html, "input[type='checkbox']", "value")) == [@claim_id <> ":" <> @hash]
    assert attr(html, "#company-assessment-add-guidance", "phx-value-action") == ["add_guidance"]
    assert Enum.empty?(query(html, "#company-assessment-obligation-0-remove"))

    assert attr(html, "#company-assessment-obligation-1-remove", "phx-value-action") == [
             "remove_row"
           ]

    assert text(html) =~ "No selected milestone covers this goal"
    assert text(html) =~ "Other package goals — outside this assessment"
    assert text(html) =~ "Separate documentation review"
    assert Enum.empty?(query(html, "#company-assessment-results-form"))
    assert_direct_envelopes(html)
    assert_unique_ids(html)
  end

  test "the shared qualified report keeps uncertainty, resolution, original excerpts and safe source navigation" do
    f = fixture()
    html = panel(f.state, sources: [f.source])
    report = "#company-assessment-recommendation-0"

    assert text(html, report) =~ "Original uncertainty retained"
    assert text(html, report) =~ "Saved human resolution: Explicit synthetic human review"
    assert text(html, report) =~ "Current source name (may have changed): Synthetic policy"
    assert text(html, report) =~ "Included source #{@source_id}"
    assert attr(html, report <> " a", "href") == ["https://example.com/policy"]
    assert attr(html, report <> " a", "target") == ["_blank"]
    assert attr(html, report <> " a", "rel") == ["noopener noreferrer"]
    assert attr(html, report <> " a", "phx-click") == []
    assert text(html, report <> " a") =~ "opens in a new tab"

    changed = put_in(f.source, ["latest_revision", "body_hash"], @digest)
    stale_html = panel(f.state, sources: [changed])
    assert attr(stale_html, report <> " a", "href") == []

    assert text(stale_html, report) =~
             "Current capture details are not shown from the loaded metadata"

    assert text(stale_html, report) =~ "Original policy excerpt"
  end

  test "observation controls start blank, account for all four exact IDs and retain negative draft text" do
    f = fixture()
    state = results_state(f)
    html = panel(state)

    assert Enum.count(query(html, "#company-assessment-results-form li")) == 4
    assert attr(html, "#company-assessment-task-status option[selected]", "value") == [""]
    assert attr(html, "#company-assessment-critical-status option[selected]", "value") == [""]
    assert attr(html, "#company-assessment-judgment option[selected]", "value") == [""]

    assert attr(
             html,
             "#company-assessment-results-form select[id$='-status'] option[selected]",
             "value"
           ) == List.duplicate("", 6)

    assert Enum.sort(attr(html, "input[name$='[obligation_id]']", "value")) ==
             Enum.sort(~w(goal-readiness named-review rollback-ready communication-owner))

    assert attr(html, "#company-assessment-results-form", "phx-change") == [
             "assessment_result_change"
           ]

    assert attr(html, "#company-assessment-results-form", "phx-submit") == ["assessment_record"]
    assert_direct_envelopes(html)

    draft = %{
      "task_status" => "interrupted",
      "critical_status" => "present",
      "judgment" => "accepted",
      "results" => [
        %{
          "obligation_id" => "named-review",
          "status" => "unmet",
          "observation" => "Reviewer unavailable — retain this literal draft."
        }
      ]
    }

    failed =
      state |> Map.put("result_draft", draft) |> Map.put("error", :acceptance_requirements_unmet)

    failed_html = panel(failed)

    assert text(failed_html) =~
             "Cannot accept: a critical violation is present. Choose Not accepted to record this attempt."

    assert text(failed_html) =~ "Interrupted work can be recorded as Not accepted"

    assert text(failed_html, "#company-assessment-result-1-observation") ==
             "Reviewer unavailable — retain this literal draft."

    assert attr(failed_html, "#company-assessment-result-2-status", "aria-invalid") == ["true"]
    assert attr(failed_html, "#company-assessment-error", "role") == ["alert"]
    assert attr(failed_html, "#company-assessment-error", "tabindex") == ["-1"]

    assert "#company-assessment-result-1-status" in attr(
             failed_html,
             "#company-assessment-error a",
             "href"
           )

    refute text(failed_html) =~ "Owner accepted this task assessment"
  end

  test "persisted captured judgment is separate from stale and restored applicability" do
    f = fixture()
    receipt = receipt(f)

    state =
      f.state
      |> Map.put("stage", "receipt")
      |> Map.put("frozen_rubric", f.rubric)
      |> Map.put("receipt", receipt)

    html = panel(state)
    assert text(html) =~ "Owner accepted this task assessment"
    assert text(html) =~ "Captured judgment: Accepted"
    assert text(html) =~ "Current applicability: Current"

    assert text(html) =~
             "Recorded by local-operator (local workspace access; corporate ownership and personal identity are not attested)"

    assert Enum.count(query(html, "#company-assessment-receipt li")) == 4
    expected_observation = f.oracle["obligations"] |> hd() |> Map.fetch!("met_observation")
    assert text(html) =~ expected_observation

    assert attr(html, "#company-assessment-another-attempt", "phx-click") == [
             "assessment_attempt_start"
           ]

    for status <- ["stale", "restored_historical"] do
      stale =
        put_in(state, ["receipt", "applicability"], %{"status" => status, "reason" => status})

      stale =
        put_in(stale, ["frozen_rubric", "applicability"], %{
          "status" => status,
          "reason" => status
        })

      stale_html = panel(stale)
      assert text(stale_html) =~ "Captured judgment: Accepted"
      assert text(stale_html) =~ "Recorded historical acceptance"
      refute text(stale_html) =~ "Owner accepted this task assessment"
      assert text(stale_html) =~ @qualification

      if status == "stale" do
        assert Enum.count(query(stale_html, "#company-assessment-another-attempt")) == 1

        assert attr(stale_html, "#company-assessment-another-attempt", "phx-click") == [
                 "assessment_attempt_start"
               ]

        assert attr(stale_html, "#company-assessment-another-attempt", "phx-value-rubric_id") == [
                 @rubric_id
               ]

        assert attr(
                 stale_html,
                 "#company-assessment-another-attempt",
                 "phx-value-expected_rubric_hash"
               ) == [@hash]

        assert text(stale_html, "#company-assessment-stale-attempt-help") =~
                 "Stale acceptance is unavailable. You may record complete unsuccessful observations as Not accepted"

        assert Enum.empty?(query(stale_html, "#company-assessment-results-form"))
        assert_direct_envelopes(stale_html)

        superseded = panel(put_in(stale, ["frozen_rubric", "superseded"], true))
        assert Enum.empty?(query(superseded, "#company-assessment-another-attempt"))
      else
        assert Enum.empty?(query(stale_html, "#company-assessment-another-attempt"))
      end

      if status == "restored_historical",
        do:
          assert(
            text(stale_html) =~ "Restored history — a new rubric and assessment are required"
          )
    end
  end

  test "rubric-only history is read-only and lineage actions carry exactly a rubric identity" do
    f = fixture()
    predecessor = "40000000-0000-4000-8000-000000000002"
    successor = "40000000-0000-4000-8000-000000000003"

    rubric =
      f.rubric
      |> Map.put("supersedes_id", predecessor)
      |> Map.put("successor_id", successor)
      |> Map.put("superseded", true)

    state =
      f.state
      |> Map.put("stage", "receipt")
      |> Map.put("context", nil)
      |> Map.put("frozen_rubric", rubric)
      |> Map.put("receipt", nil)

    html = panel(state)
    assert text(html) =~ "Unassessed — choose a recorded assessment below"
    assert text(html) =~ f.oracle["task"]
    assert text(html) =~ "Captured other package goals — outside this assessment"
    assert text(html) =~ "20000000-0000-4000-8000-000000000002"
    assert Enum.empty?(query(html, "form, textarea, select"))

    assert attr(html, "#company-assessment-predecessor", "phx-click") == [
             "assessment_history_open"
           ]

    assert attr(html, "#company-assessment-predecessor", "phx-value-rubric_id") == [predecessor]
    assert attr(html, "#company-assessment-predecessor", "phx-value-assessment_id") == []

    assert attr(html, "#company-assessment-successor-history", "phx-value-rubric_id") == [
             successor
           ]

    assert Enum.empty?(
             query(html, "#company-assessment-another-attempt, #company-assessment-successor")
           )

    current = panel(Map.put(state, "frozen_rubric", f.rubric), package_label: "Mercury · 1.0.0")
    assert text(current) =~ "Exact selected package: Mercury · 1.0.0"

    assert attr(current, "#company-assessment-another-attempt", "phx-click") == [
             "assessment_attempt_start"
           ]

    assert attr(current, "#company-assessment-successor", "phx-value-action") == ["successor"]
    assert_direct_envelopes(html)
    assert_unique_ids(html)
  end

  test "historical unsuccessful receipt and safe history event never manufacture acceptance" do
    f = fixture()

    receipt =
      receipt(f)
      |> put_in(["payload", "judgment"], "not_accepted")
      |> put_in(["payload", "task_status"], "interrupted")

    state =
      f.state
      |> Map.put("stage", "receipt")
      |> Map.put("frozen_rubric", f.rubric)
      |> Map.put("receipt", receipt)
      |> Map.put("history", [receipt])

    html = panel(state)
    assert text(html) =~ "Recorded — not accepted"
    assert text(html) =~ "Captured judgment: Not accepted"
    refute text(html) =~ "Owner accepted this task assessment"

    assert attr(html, "#company-assessment-history-" <> @assessment_id, "phx-value-assessment_id") ==
             [@assessment_id]

    assert attr(html, "#company-assessment-history-" <> @assessment_id, "phx-click") == [
             "assessment_history_open"
           ]
  end

  test "departure choices are explicit stage actions and preserve the mounted values" do
    f = fixture()

    for {state, action, label} <- [
          {f.state, "freeze", "Freeze rubric and leave"},
          {results_state(f), "record_not_accepted", "Record not accepted and leave"}
        ] do
      state = Map.put(state, "pending_destination", %{"tab" => "evidence"})
      html = panel(state)
      assert text(html) =~ "This assessment has unsaved changes"
      assert text(html) =~ label

      assert Enum.sort(attr(html, "#company-assessment-departure button", "phx-value-action")) ==
               Enum.sort(["keep", "discard", action])

      assert Enum.uniq(attr(html, "#company-assessment-departure button", "phx-click")) == [
               "assessment_departure_resolve"
             ]

      assert attr(html, "#company-assessment-departure", "tabindex") == ["-1"]
      assert_direct_envelopes(html)
    end
  end

  test "literal task, obligation, observation and report content stay escaped; errors use fixed copy" do
    f = fixture()
    hostile = "<script>alert('company')</script><svg onload='hostile()'> & literal"
    state = put_in(f.state, ["rubric_draft", "task"], hostile)
    state = put_in(state, ["rubric_draft", "obligations", Access.at(0), "text"], hostile)

    state =
      put_in(
        state,
        ["context", "recommendations", Access.at(0), "basis", "report", "uncertainty"],
        hostile
      )

    html = panel(state)
    assert text(html, "#company-assessment-task") == hostile
    assert text(html, "#company-assessment-obligation-0-text") == hostile
    assert Enum.empty?(query(html, "script, svg, [onload]"))
    assert html =~ "&lt;script&gt;"

    assert Assessment.error_message("private-provider-detail: #{hostile}") ==
             Assessment.error_message(:unknown_reason)

    refute Assessment.error_message("private-provider-detail: #{hostile}") =~
             "private-provider-detail"

    assert Assessment.error_message(:assessment_storage_failed) =~ "Retry the same attempt"
    refute Assessment.error_message(:assessment_storage_failed) =~ "reanalysis"
  end

  test "Guide and built-package continuations need the root verified exact binding and parent generation" do
    f = fixture()

    selected = %{
      "id" => @plan_id,
      "revision_hash" => @hash,
      "status" => "approved",
      "superseded" => false,
      "payload" => %{"name" => "Mercury", "package_version" => "1.0.0"}
    }

    binding = %{
      "plan_id" => @plan_id,
      "expected_plan_revision_hash" => @hash,
      "artifact_digest" => @digest
    }

    guide = %{
      unavailable: false,
      profile_name: "Synthetic",
      repository_count: 1,
      projects: [],
      reset_token: 9,
      scope: nil,
      claim_review_count: 0,
      plan_review_count: 0,
      tasks: [],
      selected: selected,
      preflight: :eligible,
      next: %{section: nil, message: "Built exact package"}
    }

    html =
      render_component(&Guide.workflow/1,
        data: guide,
        target: "company-component",
        company_event_generation: "child-generation",
        assessment_event_generation: @generation,
        assessment_binding: binding
      )

    assert_continuation(html, "#company-guide-assess")

    legacy =
      render_component(&Guide.workflow/1,
        data: guide,
        target: "company-component",
        company_event_generation: "child-generation"
      )

    assert Enum.empty?(query(legacy, "#company-guide-assess"))

    for bad_binding <- [
          nil,
          Map.put(binding, "plan_id", "foreign"),
          Map.put(binding, "expected_plan_revision_hash", @digest)
        ] do
      bad =
        render_component(&Guide.workflow/1,
          data: guide,
          target: "company-component",
          company_event_generation: "child-generation",
          assessment_event_generation: @generation,
          assessment_binding: bad_binding
        )

      assert Enum.empty?(query(bad, "#company-guide-assess"))
    end

    plan_html = render_component(&Plan.builder/1, plan_assigns(f, selected, binding))
    assert_continuation(plan_html, "#company-built-assess")

    wrong =
      render_component(
        &Plan.builder/1,
        plan_assigns(f, selected, Map.put(binding, "artifact_digest", @hash))
      )

    assert Enum.empty?(query(wrong, "#company-built-assess"))
  end

  defp fixture do
    oracle = @oracle_path |> File.read!() |> Jason.decode!()
    goal = Map.put(oracle["goal"], "id", @goal_id)
    goal = Map.put(goal, "content_hash", HarnessForge.Goals.content_hash(goal))
    ref = %{"id" => @claim_id, "revision_hash" => @hash}
    source_ref = %{"source_id" => @source_id, "revision_id" => @revision_id, "body_hash" => @hash}

    guidance =
      Map.new(~w(rule workflow check evaluation_criterion), &{&1, "Synthetic approved #{&1}"})

    claim = %{
      "id" => @claim_id,
      "workspace_id" => "synthetic-workspace",
      "revision_hash" => @hash,
      "text" => oracle["edited_guidance_expected_in_export"],
      "status" => "approved",
      "superseded" => false,
      "basis" => %{
        "kind" => "company_analysis",
        "goal_id" => @goal_id,
        "goal_content_hash" => goal["content_hash"],
        "project_id" => @plan_id,
        "provider" => "synthetic",
        "model" => "not-requested",
        "review_resolution" => "Explicit synthetic human review",
        "guidance" => guidance,
        "context" => %{"sources" => [source_ref]},
        "report" => %{
          "uncertainty" => "Original uncertainty retained",
          "recommendation" =>
            Map.merge(guidance, %{
              "status" => "uncertain",
              "goal_rationale" => "Saved future intent"
            }),
          "findings" => [
            %{
              "kind" => "conflict",
              "statement" => "Original synthetic conflict",
              "citations" => [
                %{
                  "source_id" => @source_id,
                  "revision_id" => @revision_id,
                  "start_byte" => 0,
                  "end_byte" => 23,
                  "snippet" => "Original policy excerpt"
                }
              ]
            }
          ]
        }
      }
    }

    source = %{
      "id" => @source_id,
      "workspace_id" => "synthetic-workspace",
      "status" => "active",
      "title" => "Synthetic policy",
      "latest_revision_id" => @revision_id,
      "latest_revision" => %{
        "id" => @revision_id,
        "source_id" => @source_id,
        "workspace_id" => "synthetic-workspace",
        "body_hash" => @hash,
        "body" => "Original policy excerpt",
        "captured_at" => "2026-01-10T10:11:12Z",
        "source_url" => "https://example.com/policy"
      }
    }

    outside = %{
      "id" => "20000000-0000-4000-8000-000000000002",
      "content_hash" => @digest,
      "title" => "Separate documentation review",
      "owner" => "Synthetic operator",
      "acceptance" => "Review documentation separately"
    }

    binding = %{
      "plan_id" => @plan_id,
      "plan_revision_hash" => @hash,
      "artifact_digest" => @digest
    }

    obligations =
      Enum.map(oracle["obligations"], fn row ->
        row
        |> Map.take(~w(id kind text mandatory))
        |> Map.put(
          "claim_refs",
          if(row["kind"] == "approved_analysis_guidance", do: [ref], else: [])
        )
      end)

    context = %{
      "binding" => binding,
      "goals" => [goal, outside],
      "selected_goal" => goal,
      "required_claim_refs" => [ref],
      "recommendations" => [claim],
      "milestones" => [],
      "outside_goals" => [outside],
      "plan_snapshot" => %{
        "goals" => [Map.take(goal, ~w(id content_hash)), Map.take(outside, ~w(id content_hash))]
      },
      "applicability" => current()
    }

    rubric = %{
      "id" => @rubric_id,
      "family_id" => @rubric_id,
      "supersedes_id" => nil,
      "revision_hash" => @hash,
      "superseded" => false,
      "successor_id" => nil,
      "applicability" => current(),
      "payload" => %{
        "task" => oracle["task"],
        "goal" => goal,
        "binding" => binding,
        "obligations" => obligations,
        "required_claim_refs" => [ref],
        "claim_contexts" => [],
        "plan_snapshot" => context["plan_snapshot"]
      }
    }

    state = %{
      "stage" => "rubric",
      "context" => context,
      "scope_input" => %{},
      "rubric_draft" => %{"task" => oracle["task"], "obligations" => obligations},
      "result_draft" => %{},
      "history" => [],
      "dirty" => false
    }

    %{oracle: oracle, goal: goal, source: source, state: state, rubric: rubric}
  end

  defp results_state(f),
    do:
      f.state
      |> Map.put("stage", "results")
      |> Map.put("frozen_rubric", f.rubric)
      |> Map.put("attempt", %{
        "attempt_id" => @assessment_id,
        "attempt_token" => "synthetic-test-token"
      })

  defp receipt(f) do
    results =
      Enum.map(
        f.oracle["obligations"],
        &%{"obligation_id" => &1["id"], "status" => "met", "observation" => &1["met_observation"]}
      )

    %{
      "id" => @assessment_id,
      "rubric_id" => @rubric_id,
      "attempt_id" => @assessment_id,
      "assessment_hash" => @digest,
      "inserted_at" => "2026-11-02T10:00:00Z",
      "applicability" => current(),
      "payload" => %{
        "judgment" => "accepted",
        "operator" => "local-operator",
        "task_status" => "completed",
        "critical_status" => "none",
        "authority_at_record" => "current",
        "rubric_revision_hash" => @hash,
        "results" => results
      }
    }
  end

  defp current, do: %{"status" => "current", "reason" => nil}

  defp panel(state, opts \\ []),
    do:
      render_component(
        &Assessment.panel/1,
        Keyword.merge(
          [state: state, assessment_event_generation: @generation, company_reset_token: 9],
          opts
        )
      )

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp text(html, selector \\ nil)

  defp text(html, nil),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> normalize_text()

  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text() |> normalize_text()
  defp normalize_text(value), do: value |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp attr(html, selector, name),
    do: html |> query(selector) |> LazyHTML.attribute(name)

  defp assert_direct_envelopes(html) do
    assert Enum.empty?(query(html, "[phx-target], [phx-debounce], [phx-throttle]"))

    assert Enum.uniq(attr(html, "button[phx-click]", "phx-value-assessment_event_generation")) in [
             [],
             [@generation]
           ]
  end

  defp assert_unique_ids(html) do
    ids = attr(html, "[id]", "id")
    assert length(ids) == length(Enum.uniq(ids))
  end

  defp assert_continuation(html, selector) do
    assert attr(html, selector, "phx-click") == ["company_assessment_open"]
    assert attr(html, selector, "phx-value-plan_id") == [@plan_id]
    assert attr(html, selector, "phx-value-expected_plan_revision_hash") == [@hash]
    assert attr(html, selector, "phx-value-artifact_digest") == [@digest]
    assert attr(html, selector, "phx-value-assessment_event_generation") == [@generation]
    assert attr(html, selector, "phx-target") == []
  end

  defp plan_assigns(_f, selected, binding) do
    payload =
      Map.merge(
        %{
          "project_id" => "",
          "repository_ids" => [],
          "claim_refs" => [],
          "goal_ids" => [],
          "runtime" => "opencode",
          "runtime_version" => "unqualified",
          "execution" => %{"max_turns" => 1, "timeout_seconds" => 1},
          "template_ids" => [],
          "milestones" => []
        },
        selected["payload"]
      )

    selected = Map.put(selected, "payload", payload)

    [
      target: "company-component",
      company_event_generation: "child-generation",
      assessment_event_generation: @generation,
      assessment_binding: binding,
      profile: nil,
      sources: [],
      goals: [],
      repositories: [],
      projects: [],
      approved: [],
      plans: [],
      draft: %{
        "project_id" => "",
        "supersedes_id" => "",
        "name" => "",
        "package_version" => "",
        "repository_ids" => [],
        "claim_refs" => [],
        "goal_ids" => [],
        "template_ids" => [],
        "runtime" => "opencode",
        "runtime_version" => "unqualified",
        "execution" => %{"max_turns" => 1, "timeout_seconds" => 1},
        "milestones" => []
      },
      selected: selected,
      artifacts: [],
      built: %{"digest" => @digest},
      diff: nil,
      open_sections: MapSet.new(["build"]),
      plan_preflight: :eligible,
      company_reset_token: 9
    ]
  end
end
