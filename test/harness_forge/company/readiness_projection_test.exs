defmodule HarnessForge.Company.ReadinessProjectionTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Company.ReadinessProjection

  @hash String.duplicate("a", 64)
  @scope %{
    "workspace_id" => "workspace",
    "project_id" => "project",
    "project_hash" => @hash,
    "goal_id" => "goal",
    "goal_hash" => @hash,
    "corpus_id" => "corpus",
    "semantic_generation" => 3,
    "authorization_generation" => 2
  }

  test "unread observations remain six independent unknown facts without a global completion value" do
    projected = ReadinessProjection.project(%{})
    assert projected["version"] == "company-readiness.v1"

    assert Enum.sort(Map.keys(projected["facts"])) ==
             Enum.sort(~w(capture understanding review candidate evaluation release))

    assert Enum.all?(projected["facts"], fn {_, fact} -> fact["status"] == "unknown" end)
    assert projected["next_action"] == nil
    for key <- ~w(score complete ready released), do: refute(Map.has_key?(projected, key))
  end

  test "failed or abstained synthesis never overrides a separately verified scoped capture" do
    capture =
      fact(
        "complete_for_selected_scope",
        "capture_verified",
        Map.merge(@scope, %{"capture_run_id" => "capture", "capture_revision" => 2}),
        "current_content",
        [Map.put(ref("capture", "capture", nil), "revision", 2)]
      )

    for {status, reason} <- [
          {"blocked", "analysis_failed"},
          {"needs_input", "analysis_abstained"}
        ] do
      understanding =
        fact(
          status,
          reason,
          Map.merge(@scope, %{"run_id" => "run", "run_digest" => @hash}),
          "current_session"
        )

      projected = project(%{"capture" => capture, "understanding" => understanding})
      assert projected["facts"]["capture"]["status"] == "complete_for_selected_scope"
      assert projected["facts"]["understanding"]["status"] == status
      assert projected["facts"]["understanding"]["reason_code"] == reason
      assert projected["facts"]["release"]["status"] == "unknown"
    end
  end

  test "a pinned built candidate and static evaluation do not establish actual release" do
    pins =
      Map.merge(@scope, %{
        "claim_id" => "claim",
        "claim_revision_hash" => @hash,
        "plan_id" => "plan",
        "plan_revision_hash" => @hash,
        "artifact_digest" => @hash,
        "evaluation_id" => "evaluation"
      })

    refs = [ref("plan", "plan", @hash), ref("artifact", @hash, @hash)]
    candidate = fact("complete_for_selected_scope", "artifact_verified", pins, "static", refs)

    evaluation =
      fact(
        "complete_for_selected_scope",
        "evaluation_recorded",
        pins,
        "static",
        refs ++ [ref("evaluation", "evaluation", nil)]
      )

    forged_release = fact("complete_for_selected_scope", "release_verified", pins, "static", refs)

    projected =
      project(%{
        "candidate" => candidate,
        "evaluation" => evaluation,
        "release" => forged_release
      })

    assert projected["facts"]["candidate"]["status"] == "complete_for_selected_scope"
    assert projected["facts"]["evaluation"]["evidence_kind"] == "static"
    refute projected["facts"]["release"]["status"] == "complete_for_selected_scope"
    assert projected["next_action"] == nil
  end

  test "missing pins and changed generations withhold old completion and record references" do
    pins = Map.merge(@scope, %{"capture_run_id" => "capture", "capture_revision" => 2})

    completed =
      fact("complete_for_selected_scope", "capture_verified", pins, "current_content", [
        ref("capture", "capture", nil)
      ])

    stale = project(%{"capture" => put_in(completed, ["pins", "semantic_generation"], 2)})
    assert stale["facts"]["capture"]["status"] == "stale"
    assert stale["facts"]["capture"]["references"] == []

    missing =
      project(%{"capture" => Map.put(completed, "pins", Map.delete(pins, "capture_run_id"))})

    assert missing["facts"]["capture"]["status"] == "unknown"
    assert missing["facts"]["capture"]["reason_code"] == "missing_required_pins"

    unavailable =
      project(%{"capture" => fact("unknown", "backing_record_unavailable", %{}, "unknown")})

    assert unavailable["facts"]["capture"]["status"] == "unknown"
    assert unavailable["next_action"] == nil
  end

  test "claim approval alone cannot replace an exact separate plan decision" do
    pins =
      Map.merge(@scope, %{
        "claim_id" => "claim",
        "claim_revision_hash" => @hash,
        "plan_id" => "plan",
        "plan_revision_hash" => @hash
      })

    claim_only =
      fact("complete_for_selected_scope", "exact_review_verified", pins, "current_content", [
        ref("claim", "claim", @hash)
      ])

    projected = project(%{"review" => claim_only})
    assert projected["facts"]["review"]["status"] == "unknown"

    exact =
      Map.put(claim_only, "references", [ref("claim", "claim", @hash), ref("plan", "plan", @hash)])

    assert project(%{"review" => exact})["facts"]["review"]["status"] ==
             "complete_for_selected_scope"

    stale =
      project(%{"review" => put_in(exact, ["pins", "project_hash"], String.duplicate("b", 64))})

    assert stale["facts"]["review"]["status"] == "stale"
    assert stale["facts"]["review"]["references"] == []
  end

  test "only optional omissions bound to the checked declaration and receipt are preserved" do
    omission = %{
      "connector_id" => "optional-slack",
      "connector_name" => "Optional <Slack> history",
      "scope_id" => "declared-channel",
      "requirement" => "optional",
      "reason_code" => "optional_source_unavailable",
      "declaration_id" => "declaration",
      "declaration_revision" => 2,
      "declaration_digest" => @hash,
      "capture_run_id" => "failed-capture",
      "capture_revision" => 4
    }

    pins =
      Map.merge(
        @scope,
        Map.take(omission, ~w(declaration_id declaration_revision declaration_digest))
      )

    capture =
      fact("complete_for_selected_scope", "declared_scope_verified", pins, "current_content", [
        Map.put(ref("declaration", "declaration", @hash), "revision", 2)
      ])

    input = %{
      "scope" => @scope,
      "facts" => %{"capture" => capture},
      "omissions" => [
        omission,
        Map.delete(omission, "requirement"),
        Map.put(omission, "requirement", "required")
      ],
      "next_action" => %{"code" => "execute", "url" => "https://example.invalid"},
      "body" => "BODY_CANARY"
    }

    projected = ReadinessProjection.project(input)
    assert projected["omissions"] == [omission]
    assert projected["next_action"] == nil
    refute Jason.encode!(projected) =~ "BODY_CANARY"
    assert projected["facts"]["understanding"]["status"] == "unknown"
    assert ReadinessProjection.project(%{input | "facts" => %{}})["omissions"] == []

    assert ReadinessProjection.project(
             put_in(input, ["facts", "capture", "pins", "semantic_generation"], 1)
           )["omissions"] == []

    assert ReadinessProjection.project(%{
             input
             | "omissions" => [Map.delete(omission, "capture_revision")]
           })["omissions"] == []
  end

  test "unsafe nested metadata is withheld rather than becoming a source link or authority" do
    unsafe =
      fact("blocked", "analysis_failed", @scope, "current_session", [
        %{
          "kind" => "claim",
          "id" => "claim",
          "destination_code" => "https://example.invalid",
          "body" => "NESTED_BODY_CANARY"
        }
      ])

    projected = project(%{"understanding" => unsafe})
    assert projected["facts"]["understanding"]["status"] == "unknown"
    assert projected["facts"]["understanding"]["references"] == []
    refute Jason.encode!(projected) =~ "NESTED_BODY_CANARY"
  end

  test "completion requires exact supporting capture and analysis references" do
    pins = Map.merge(@scope, %{"capture_run_id" => "capture", "capture_revision" => 2})
    no_receipt = fact("complete_for_selected_scope", "capture_verified", pins, "current_content")
    assert project(%{"capture" => no_receipt})["facts"]["capture"]["status"] == "unknown"

    wrong_receipt =
      Map.put(no_receipt, "references", [Map.put(ref("capture", "capture", nil), "revision", 1)])

    assert project(%{"capture" => wrong_receipt})["facts"]["capture"]["status"] == "unknown"

    pins =
      Map.merge(@scope, %{
        "run_id" => "run",
        "run_digest" => @hash,
        "claim_id" => "claim",
        "claim_revision_hash" => @hash
      })

    analysis =
      fact("complete_for_selected_scope", "analysis_proposed", pins, "current_session", [
        ref("retrieval", "run", @hash)
      ])

    assert project(%{"understanding" => analysis})["facts"]["understanding"]["status"] ==
             "unknown"

    complete = Map.update!(analysis, "references", &(&1 ++ [ref("claim", "claim", @hash)]))

    assert project(%{"understanding" => complete})["facts"]["understanding"]["status"] ==
             "complete_for_selected_scope"
  end

  defp project(facts), do: ReadinessProjection.project(%{"scope" => @scope, "facts" => facts})

  defp fact(status, reason, pins, kind, refs \\ []),
    do: %{
      "status" => status,
      "reason_code" => reason,
      "pins" => pins,
      "references" => refs,
      "evidence_kind" => kind
    }

  defp ref(kind, id, digest),
    do: %{"kind" => kind, "id" => id, "digest" => digest, "destination_code" => "company"}
end
