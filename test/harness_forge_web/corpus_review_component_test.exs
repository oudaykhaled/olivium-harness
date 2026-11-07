defmodule HarnessForgeWeb.CorpusReviewComponentTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias HarnessForgeWeb.Company.{Analysis, Catalog, CorpusReview}

  @generation String.duplicate("a", 32)
  @hash String.duplicate("b", 64)
  @revision "20000000-0000-4000-8000-000000000001"
  @source "10000000-0000-4000-8000-000000000001"
  @claim "30000000-0000-4000-8000-000000000001"

  test "scope starts as an explicit choice and does not preload evidence text" do
    html = review_html(state())

    assert text(html) =~ "Build from company evidence"

    assert attrs(html, "a[href^='/?setup=']", "href") ==
             ["/?setup=company", "/?setup=goals", "/?setup=connections"]

    assert attrs(html, "#corpus-connection option[selected]", "value") == [""]
    assert attrs(html, "#corpus-project option[selected]", "value") == [""]
    assert attrs(html, "#corpus-goal option[selected]", "value") == [""]
    assert attrs(html, "#corpus-scope-form", "phx-submit") == ["corpus_scope_open"]

    assert attrs(html, "#corpus-scope-form input[name=corpus_generation]", "value") == [
             @generation
           ]

    assert Enum.empty?(query(html, "#corpus-results, #corpus-passage, #corpus-original-report"))
    refute html =~ "SENSITIVE_BODY_CANARY"
    refute html =~ "scope-secret-token"
  end

  test "a separately retained selected choice survives its browse page changing" do
    state =
      state()
      |> Map.put(:selection, %{"connection_id" => "old", "project_id" => "", "goal_id" => ""})
      |> put_in([:selected_choices, :connections], %{"id" => "old", "title" => "Saved corpus"})
      |> put_in([:choices, :connections], %{
        "rows" => [%{"id" => "new", "title" => "Another corpus"}],
        "next_cursor" => "cursor-secret"
      })

    html = review_html(state)
    assert attrs(html, "#corpus-connection option[selected]", "value") == ["old"]

    assert text(html, "#corpus-connection") =~
             "Saved corpus · current selection outside this page"

    assert attrs(html, "#corpus-connection-choices-next", "phx-value-kind") == ["connection"]
    refute html =~ "cursor-secret"
  end

  test "metadata page exposes actual local counts and unknown coverage without body hydration" do
    source = Map.put(source(), "body", "SENSITIVE_BODY_CANARY")
    source = put_in(source, ["latest_revision", "body"], "SENSITIVE_BODY_CANARY")
    html = review_html(scoped_state([source]))

    assert Enum.count(query(html, ".corpus-counts > div")) == 3

    for {{label, count}, index} <-
          Enum.with_index(
            [
              {"Locally captured", "5000"},
              {"Current available captures", "4998"},
              {"Unavailable captures", "2"}
            ],
            1
          ) do
      entry = ".corpus-counts > div:nth-child(#{index})"
      assert text(html, entry <> " > dt") == label
      assert text(html, entry <> " > dd") == count
    end

    assert text(html) =~ "Discovery coverage: unknown"
    assert text(html) =~ "Whole-corpus model coverage: unknown"
    assert text(html) =~ "Project source assignments: 3"
    assert text(html) =~ "does not assign its sources to the project"
    assert text(html, "#corpus-source-#{@source}") =~ "Candidate evidence · needs review"
    refute text(html, "#corpus-source-#{@source}") =~ "Supporting evidence"
    assert attrs(html, "#corpus-source-open-#{@source}", "phx-value-start_byte") == ["0"]
    assert text(html, "#corpus-source-open-#{@source}") == "Open first text window"

    assert text(html) =~
             "Document status: unknown · effective date: unknown · event date: unknown"

    refute html =~ "SENSITIVE_BODY_CANARY"
    refute html =~ "scope-secret-token"
  end

  test "selected context stays concise while cold setup and all scope controls remain reachable" do
    cold = review_html(state())
    assert attrs(cold, "#corpus-scope-settings", "open") == [""]
    selected = review_html(scoped_state([]))
    assert attrs(selected, "#corpus-scope-settings", "open") == []
    assert text(selected, "#corpus-scope-summary") =~ "Synthetic project"
    assert text(selected, "#corpus-scope-summary") =~ "Rehearse rollback"
    assert Enum.empty?(query(selected, "#corpus-scope-summary .corpus-counts"))
    assert Enum.count(query(selected, "#corpus-scope-settings .corpus-counts > div")) == 3

    assert attrs(selected, "#corpus-scope-settings #corpus-scope-form", "phx-submit") == [
             "corpus_scope_open"
           ]
  end

  test "a captured scope puts its question action before receipt details and retains limits and search choices" do
    capture = %{
      "state" => "completed",
      "capture" => %{"checkpoint" => 2, "complete" => true, "counts" => %{"captured" => 4}},
      "fts" => %{"indexed" => 4, "expected" => 4},
      "error_code" => nil
    }

    html = pipeline_html(%{capture: capture})
    assert attrs(html, "#company-corpus-capture-details", "open") == []
    assert attrs(html, "#company-corpus-question-settings", "open") == []
    assert attrs(html, "#company-corpus-question-text", "maxlength") == ["256"]

    assert attrs(html, "#company-corpus-question-settings #company-corpus-retrieval-mode", "name") ==
             ["retrieval[mode]"]

    assert Regex.match?(
             ~r/id="company-corpus-question".*?id="company-corpus-retrieve".*?id="company-corpus-question-settings".*?id="company-corpus-capture-details"/s,
             html
           )

    assert text(html, "#company-corpus-capture-brief") =~
             "Discovery and semantic coverage remain unknown"
  end

  test "match offsets are exact scalar pins and raw matches get no semantic classification" do
    source = Map.put(source(), "match_start_byte", 12)
    html = review_html(scoped_state([source]))
    button = "#corpus-source-open-#{@source}"
    assert attrs(html, button, "phx-value-source_id") == [@source]
    assert attrs(html, button, "phx-value-revision_id") == [@revision]
    assert attrs(html, button, "phx-value-body_hash") == [@hash]
    assert attrs(html, button, "phx-value-start_byte") == ["12"]
    assert attrs(html, button, "phx-value-corpus_generation") == [@generation]
    assert text(html, button) == "Open matching passage"
    assert Enum.empty?(query(html, "#corpus-passage-text"))
  end

  test "zero matches explicitly leaves contradictory evidence unknown" do
    html = review_html(scoped_state([]))
    assert text(html, "#corpus-results") =~ "No matching captured sources"

    assert text(html, "#corpus-results") =~
             "does not establish that obligations, relevant evidence or contradictions are absent"

    assert attrs(html, "#corpus-page-previous", "disabled") == [""]
    assert attrs(html, "#corpus-page-next", "disabled") == [""]
    refute Enum.empty?(query(html, "#corpus-recommendation-choices"))
    refute text(html) =~ "No conflicts found"
  end

  test "the only open text is escaped exact context with exclusive offsets and replacement navigation" do
    passage_text = "<script>hostile()</script> Café retains parent context."

    passage = %{
      "source" => source(),
      "revision_id" => @revision,
      "body_hash" => @hash,
      "start_byte" => 7,
      "end_byte" => 7 + byte_size(passage_text),
      "text" => passage_text,
      "body_bytes" => 9000,
      "truncated_before" => true,
      "truncated_after" => true,
      "next_start_byte" => 7 + byte_size(passage_text)
    }

    html = review_html(Map.put(scoped_state([source()]), :passage, passage))
    assert text(html, "#corpus-passage-text") == passage["text"]
    assert Enum.empty?(query(html, "script"))
    assert html =~ "&lt;script&gt;"

    assert text(html, "#corpus-passage") =~
             "UTF-8 bytes 7–#{passage["end_byte"]} (exclusive end) of 9000 bytes"

    assert text(html, "#corpus-passage") =~ "Partial parent context"
    assert text(html, "#corpus-passage") =~ "Earlier text is omitted"
    assert text(html, "#corpus-passage") =~ "Later text is omitted"

    assert attrs(html, "#corpus-passage-next", "phx-value-start_byte") == [
             Integer.to_string(passage["next_start_byte"])
           ]

    assert attrs(html, "#corpus-passage-close", "phx-click") == ["corpus_passage_close"]
    assert attrs(html, "#corpus-passage-text", "tabindex") == ["0"]
  end

  test "a late matching passage can request omitted parent context from the exact pinned start" do
    prefix = "Incident context: this was an unapproved experiment. "
    matching_text = "An untested rollback failed."
    full_text = prefix <> matching_text

    passage = %{
      "source" => put_in(source(), ["latest_revision", "body_bytes"], byte_size(full_text)),
      "revision_id" => @revision,
      "body_hash" => @hash,
      "start_byte" => byte_size(prefix),
      "end_byte" => byte_size(full_text),
      "text" => matching_text,
      "body_bytes" => byte_size(full_text),
      "truncated_before" => true,
      "truncated_after" => false,
      "next_start_byte" => nil
    }

    html = review_html(Map.put(scoped_state([source()]), :passage, passage))
    assert text(html, "#corpus-passage-text") == matching_text
    refute text(html, "#corpus-passage-text") =~ prefix
    assert Enum.empty?(query(html, "#corpus-passage-next"))
    assert text(html, "#corpus-passage-start") == "Read context from start"
    assert attrs(html, "#corpus-passage-start", "phx-click") == ["corpus_passage_open"]
    assert attrs(html, "#corpus-passage-start", "phx-value-source_id") == [@source]
    assert attrs(html, "#corpus-passage-start", "phx-value-revision_id") == [@revision]
    assert attrs(html, "#corpus-passage-start", "phx-value-body_hash") == [@hash]
    assert attrs(html, "#corpus-passage-start", "phx-value-start_byte") == ["0"]
    assert attrs(html, "#corpus-passage-start", "phx-value-corpus_generation") == [@generation]

    from_start = %{
      passage
      | "start_byte" => 0,
        "text" => full_text,
        "truncated_before" => false
    }

    replacement = review_html(Map.put(scoped_state([source()]), :passage, from_start))
    assert Enum.count(query(replacement, "#corpus-passage-text")) == 1
    assert text(replacement, "#corpus-passage-text") == full_text
    assert byte_size(full_text) <= 4096
    assert Enum.empty?(query(replacement, "#corpus-passage-start"))
    refute text(replacement, "#corpus-passage") =~ "Earlier text is omitted"
  end

  test "unsafe stored URLs are withheld while hostile source titles remain escaped" do
    source =
      source()
      |> Map.put("title", "<svg onload=hostile()>Policy</svg>")
      |> put_in(["latest_revision", "source_url"], "javascript:hostile()")

    html = review_html(scoped_state([source]))
    assert Enum.empty?(query(html, "svg, script, a[href^='javascript:']"))
    assert text(html) =~ source["title"]
    assert text(html) =~ "Source link unavailable"
    refute html =~ "javascript:hostile()"
  end

  test "original report keeps its input count, actual kinds and resolution separate from preview" do
    recommendation = recommendation()
    html = review_html(Map.put(scoped_state([source()]), :recommendation, recommendation))

    assert text(html, "#corpus-preview-title") == "Supplementary inspection"
    assert text(html) =~ "Not part of this recommendation’s model input"

    assert text(html, "#corpus-original-report") =~
             "Original analyzed scope: 4 explicitly selected sources"

    assert text(html, "#corpus-original-report") =~ "Original recommendation status: supported"
    assert text(html, "#corpus-original-report") =~ "sources outside the selected captured corpus"
    assert text(html, "#corpus-original-finding-0 h4") == "Decision"
    assert text(html, "#corpus-original-finding-1 h4") == "Conflict"
    assert text(html, "#corpus-original-finding-2 h4") == "Unknown"
    assert text(html) =~ "Human resolution is required before approval"
    assert text(html) =~ "Recorded conflict findings: 1 · recorded unknown findings: 1"
    assert attrs(html, "#corpus-continue-review", "phx-value-claim_id") == [@claim]
    assert attrs(html, "#corpus-continue-review", "phx-value-revision_hash") == [@hash]
    assert attrs(html, "#corpus-continue-review", "phx-value-corpus_generation") == [@generation]
    assert attrs(html, "#corpus-continue-review", "phx-value-source_id") == []
    assert attrs(html, "#corpus-continue-review", "phx-value-text") == []
  end

  test "status and refusal targets can receive fixed keyboard focus without repeating removed text" do
    state = %{
      scoped_state([])
      | error: "The capture changed. Refresh and choose a new current passage.",
        notice: "Showing a fresh live page."
    }

    html = review_html(state)
    assert attrs(html, "#corpus-error", "role") == ["alert"]
    assert attrs(html, "#corpus-error", "tabindex") == ["-1"]
    assert attrs(html, "#corpus-notice", "role") == ["status"]
    assert attrs(html, "#corpus-results", "tabindex") == ["-1"]
    assert Enum.empty?(query(html, "#corpus-passage, #corpus-original-report"))
  end

  test "primary pipeline precedes inspection and binds the scoped draft without automatic search" do
    html = pipeline_html(%{question: "Café 東京 rollback?", mode: "graphiti_hybrid"})
    assert text(html, "#company-corpus-question-text") == "Café 東京 rollback?"

    assert attrs(html, "#company-corpus-retrieval-mode option[selected]", "value") == [
             "graphiti_hybrid"
           ]

    assert attrs(html, "#company-corpus-question", "phx-change") == ["corpus_question_change"]
    assert text(html) =~ "a fresh page requires re-selection"

    [_, pipeline, inspection] =
      Regex.run(~r/(company-corpus-pipeline).*?(corpus-preview-title)/s, html)

    assert pipeline == "company-corpus-pipeline"
    assert inspection == "corpus-preview-title"
  end

  test "named provisional cards escape metadata, disclose pins and keep parent text outside lists" do
    row = %{
      "passage_id" => "passage",
      "title" => "<svg>Policy café</svg>",
      "lane" => "contrary",
      "relation" => "provisional",
      "selected_order" => nil,
      "snippet" => "<script>quoted()</script>",
      "revision_id" => @revision,
      "body_hash" => @hash,
      "source_url" => "javascript:hostile()",
      "parent_text" => "UNOPENED_PARENT_CANARY"
    }

    html =
      pipeline_html(%{
        run: %{"state" => "ready", "selected_count" => 1, "mode" => "fts"},
        page: %{"rows" => [row]}
      })

    assert text(html, ".corpus-result h4") == row["title"]
    assert text(html, ".corpus-result blockquote") == row["snippet"]
    assert text(html, ".corpus-result") =~ "additional candidate outside selected synthesis input"

    assert text(html, ".corpus-result") =~
             "Document status: unknown · event: unknown · effective: unknown · captured: unknown"

    assert text(html, ".corpus-result button") == "Inspect exact context from " <> row["title"]
    assert text(html, ".corpus-result details") =~ @revision
    assert text(html, "#company-corpus-results") =~ "Semantic coverage remains unknown"
    assert Enum.empty?(query(html, "svg, script, a[href^='javascript:']"))
    refute html =~ "UNOPENED_PARENT_CANARY"
    refute text(html, ".corpus-result") =~ "Shortened excerpt"
  end

  test "question diagnostics use sealed run values rather than the draft or displayed page" do
    run = question_run("lexical", 7, 3, ["custody", "<script>policy</script>"])

    html =
      pipeline_html(%{
        run: run,
        question: "Edited draft awaiting a new search",
        submitted_question: "Original submitted question",
        page: %{"rows" => []}
      })

    assert text(html, "#company-corpus-question-coverage") =~
             "Question-derived candidates: 7 · selected for synthesis: 3"

    assert text(html, "#company-corpus-results") =~ "Selected passages: 4"

    assert text(html, "#company-corpus-question-coverage") =~
             "Matches do not establish that this question can be answered"

    assert text(html, "#company-corpus-question-search-details") =~ "custody"
    assert text(html, "#company-corpus-question-search-details") =~ "<script>policy</script>"
    assert text(html, "#company-corpus-question-search-details") =~ "query_plan_v3"
    refute text(html, "#company-corpus-question-coverage") =~ "Edited draft"
    assert Enum.empty?(query(html, "script"))
  end

  test "zero question hits warn about background evidence without granting or removing approval" do
    html = pipeline_html(%{run: question_run("lexical", 0, 0, [])})

    assert text(html, "#company-corpus-question-coverage") =~
             "No question-matched evidence found; background evidence only"

    assert text(html, "#company-corpus-question-coverage") =~
             "Goal and follow-up searches may supply background evidence"

    assert text(html, "#company-corpus-results") =~ "Review synthesis scope"
    assert attrs(html, "#company-corpus-retry-question", "type") == ["button"]

    [focus] = attrs(html, "#company-corpus-retry-question", "phx-click")
    assert focus =~ "focus"
    assert focus =~ "#company-corpus-question-text"
    refute focus =~ "push"
  end

  test "historical and graph question diagnostics remain unknown instead of invented zeros" do
    for run <- [
          %{"state" => "ready", "selected_count" => 4, "mode" => "fts"},
          question_run("unknown", nil, nil, nil) |> Map.put("mode", "graphiti_hybrid")
        ] do
      html = pipeline_html(%{run: run})

      assert text(html, "#company-corpus-question-coverage") =~
               "Question search details: unknown for this run"

      refute text(html, "#company-corpus-question-coverage") =~ "candidates: 0"
      refute text(html, "#company-corpus-question-coverage") =~ "background evidence only"
      assert Enum.empty?(query(html, "#company-corpus-question-search-details"))
    end
  end

  test "question candidates excluded from synthesis are disclosed and busy retry is disabled" do
    html = pipeline_html(%{run: question_run("lexical", 2, 0, ["custody"]), busy: true})

    assert text(html, "#company-corpus-question-coverage") =~
             "Question-matched candidates were found; none were selected for synthesis"

    assert Enum.count(query(html, "#company-corpus-retry-question[disabled]")) == 1
  end

  test "long Unicode previews retain original passage pins and escaped complete context on open" do
    snippet = "<script>quoted()</script>" <> String.duplicate("東京é", 130) <> " OMITTED_SUFFIX"
    finish = 17 + byte_size(snippet)
    snippet_hash = String.duplicate("c", 64)

    row = %{
      "passage_id" => "unicode-passage",
      "title" => "Policy 東京",
      "selected_order" => 0,
      "snippet" => snippet,
      "start_byte" => 17,
      "end_byte" => finish,
      "snippet_hash" => snippet_hash
    }

    attrs = %{
      run: %{"state" => "ready", "selected_count" => 1, "mode" => "fts"},
      page: %{"rows" => [row]}
    }

    html = pipeline_html(attrs)
    preview = text(html, ".corpus-result blockquote")
    assert String.valid?(preview)
    assert String.length(preview) == 360
    assert byte_size(preview) > 360
    assert preview == String.slice(snippet, 0, 360)

    assert text(html, ".corpus-result") =~
             "Shortened excerpt—open exact context for the complete passage"

    assert text(html, ".corpus-result details") =~
             "Original passage UTF-8 bytes 17–#{finish} (exclusive end)"

    assert text(html, ".corpus-result details") =~ snippet_hash
    assert text(html, ".corpus-result button") == "Inspect exact context from Policy 東京"
    assert attrs(html, ".corpus-result button", "phx-value-passage_id") == ["unicode-passage"]
    assert Enum.empty?(query(html, "script"))
    assert html =~ "&lt;script&gt;"
    refute html =~ "OMITTED_SUFFIX"

    opened =
      pipeline_html(
        Map.put(attrs, :passage, %{
          "title" => row["title"],
          "parent_start_byte" => 17,
          "parent_end_byte" => finish,
          "parent_text" => snippet
        })
      )

    assert text(opened, "#company-corpus-exact-passage pre") == snippet
    assert Enum.empty?(query(opened, "script"))
  end

  test "capture reports observed entries and active-member indexing while remote capture is unavailable" do
    capture = %{
      "state" => "paused",
      "capture" => %{
        "checkpoint" => 7,
        "complete" => false,
        "counts" => %{"captured" => 3, "excluded" => 2, "failed" => 1}
      },
      "fts" => %{"indexed" => 2, "expected" => 3},
      "error_code" => "scanner_unavailable"
    }

    html = pipeline_html(%{capture: capture}, "github")
    assert attrs(html, "#company-corpus-capture", "disabled") == [""]
    assert text(html) =~ "Directory capture is unsupported"
    assert text(html) =~ "checkpoint 7 · local scan complete: no"
    assert text(html) =~ "captured: 3 · excluded: 2 · failed: 1"
    assert text(html) =~ "Keyword index: 2 / 3 active captured members"
    assert text(html) =~ "Capture reason: scanner_unavailable"
    assert text(html) =~ "A complete local scan is not complete company coverage"
    assert text(html) =~ "Resuming a paused capture is not available in this view"
    assert attrs(html, "#company-corpus-capture-details", "open") == [""]
    assert text(html, "#company-corpus-capture-recovery") =~ "Review capture status and recovery"
  end

  test "catalog keeps off-page and unavailable exact selections as explicit checked controls" do
    options = [%{key: "visible", value: "visible", label: "Visible source"}]

    html =
      render_component(&Catalog.choices/1,
        id: "sources",
        name: "profile[source_ids][]",
        label: "Sources",
        options: options,
        selected: ["off-page", "missing"],
        selected_options: [%{key: "off-page", value: "off-page", label: "Saved off-page source"}]
      )

    assert attrs(html, "input[type=checkbox][checked]", "value") == ["off-page", "missing"]
    assert attrs(html, "#sources-visible", "checked") == []
    assert attrs(html, "#sources-off-page", "name") == ["profile[source_ids][]"]
    assert attrs(html, "#sources-missing", "disabled") == []
    assert text(html) =~ "Keep checked to preserve; uncheck only to remove that selection"
    assert text(html) =~ "Saved off-page source"
    assert text(html) =~ "Unavailable saved selection"
  end

  test "summary readiness requires validated eligibility and exact positive-length metadata" do
    assert Analysis.current_source?(source())
    refute Analysis.current_source?(Map.put(source(), "eligible", false))
    refute Analysis.current_source?(put_in(source(), ["latest_revision", "body_bytes"], 0))

    refute Analysis.current_source?(
             put_in(source(), ["latest_revision", "body_hash"], "tampered")
           )

    refute Analysis.current_source?(put_in(source(), ["latest_revision", "id"], "tampered"))
    refute Analysis.current_source?(put_in(source(), ["latest_revision", "source_id"], @claim))

    legacy =
      source()
      |> Map.delete("eligible")
      |> Map.put("latest_revision_id", @revision)
      |> put_in(["latest_revision", "body"], "Actual legacy captured bytes")

    assert Analysis.current_source?(legacy)
    refute Analysis.current_source?(put_in(legacy, ["latest_revision", "body"], ""))
  end

  defp state do
    %{
      choices:
        Map.new(
          ~w(connections projects goals recommendations)a,
          &{&1, %{"rows" => [], "next_cursor" => nil}}
        ),
      selected_choices: Map.new(~w(connections projects goals recommendations)a, &{&1, nil}),
      selection: %{
        "connection_id" => "",
        "project_id" => "",
        "goal_id" => "",
        "goal_content_hash" => ""
      },
      scope: nil,
      page: nil,
      query: "",
      passage: nil,
      recommendation: nil,
      previous?: false,
      error: nil,
      notice: nil,
      token: "scope-secret-token"
    }
  end

  defp scoped_state(rows) do
    scope = %{
      "connection" => %{
        "id" => "connection",
        "name" => "Synthetic corpus",
        "provider" => "local_directory",
        "sync_state" => "idle",
        "sync_complete" => true,
        "last_synced_at" => "2026-01-01T00:00:00Z"
      },
      "project" => %{"id" => "project", "name" => "Synthetic project", "content_hash" => @hash},
      "goal" => %{
        "id" => "goal",
        "title" => "Rehearse rollback",
        "owner" => "Synthetic owner",
        "acceptance" => "Keep evidence",
        "content_hash" => @hash
      },
      "assignment_counts" => %{
        "project_sources" => 3,
        "profile_sources" => 2,
        "distinct_sources" => 4
      }
    }

    state()
    |> Map.put(:scope, scope)
    |> Map.put(:page, %{
      "scope" => scope,
      "rows" => rows,
      "next_cursor" => nil,
      "counts" => %{
        "captured" => 5000,
        "current" => 4998,
        "unavailable" => 2,
        "matches" => length(rows),
        "discovery_total" => nil,
        "semantic_coverage" => "unknown"
      }
    })
  end

  defp source do
    %{
      "id" => @source,
      "workspace_id" => "synthetic-workspace",
      "connection_id" => "connection",
      "title" => "Captured synthetic policy",
      "status" => "active",
      "eligible" => true,
      "latest_revision" => %{
        "id" => @revision,
        "source_id" => @source,
        "workspace_id" => "synthetic-workspace",
        "body_hash" => @hash,
        "body_bytes" => 9000,
        "captured_at" => "2026-01-01T00:00:00Z",
        "source_updated_at" => nil,
        "source_url" => "https://example.com/policy",
        "metadata" => %{}
      }
    }
  end

  defp recommendation do
    citation = %{
      "source_id" => @source,
      "revision_id" => @revision,
      "start_byte" => 0,
      "end_byte" => 6,
      "snippet" => "Policy"
    }

    guidance = Map.new(Analysis.fields(), &{&1, "Original #{&1}"})

    %{
      "claim_id" => @claim,
      "revision_hash" => @hash,
      "status" => "proposed",
      "superseded" => false,
      "eligible" => true,
      "outside_inspection_connection" => true,
      "guidance" => guidance,
      "review_resolution" => nil,
      "analyzed_sources" =>
        Enum.map(1..4, fn number ->
          %{
            "source_id" => numbered_id("1", number),
            "revision_id" => numbered_id("2", number),
            "body_hash" => @hash
          }
        end),
      "report" => %{
        "recommendation" =>
          Map.merge(guidance, %{
            "status" => "supported",
            "goal_rationale" => "Supports saved intent"
          }),
        "uncertainty" => "Company-wide coverage is unknown",
        "findings" => [
          %{"kind" => "decision", "statement" => "Original decision", "citations" => [citation]},
          %{
            "kind" => "conflict",
            "statement" => "Original contrary incident",
            "citations" => [
              Map.merge(citation, %{
                "source_id" => numbered_id("1", 2),
                "revision_id" => numbered_id("2", 2),
                "end_byte" => 8,
                "snippet" => "Incident"
              })
            ]
          },
          %{
            "kind" => "unknown",
            "statement" => "Uncaptured obligations remain unknown",
            "citations" => []
          }
        ]
      }
    }
  end

  defp numbered_id(prefix, number),
    do:
      prefix <>
        "0000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")

  defp review_html(state),
    do: render_component(&CorpusReview.review/1, state: state, generation: @generation)

  defp question_run(status, candidates, selected, terms) do
    %{
      "state" => "ready",
      "selected_count" => 4,
      "mode" => "fts",
      "coverage" => %{
        "search" => %{
          "question" => %{
            "status" => status,
            "searched_terms" => terms,
            "query_plan_version" => "query_plan_v3",
            "candidates" => candidates,
            "selected" => selected
          }
        }
      }
    }
  end

  defp pipeline_html(attrs, provider \\ "local") do
    state = scoped_state([]) |> put_in([:scope, "connection", "provider"], provider)

    pipeline =
      Map.merge(
        %{
          corpus: %{},
          capture: nil,
          busy: false,
          error: nil,
          question: "",
          mode: "fts",
          submitted_question: nil,
          run: nil,
          page: nil,
          passage: nil,
          stage: nil,
          claim: nil
        },
        attrs
      )

    render_component(&CorpusReview.review/1,
      state: state,
      pipeline: pipeline,
      generation: @generation
    )
  end

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp attrs(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)
  defp text(html, selector \\ nil)
  defp text(html, nil), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> normalize()
  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text() |> normalize()
  defp normalize(value), do: value |> String.replace(~r/\s+/u, " ") |> String.trim()
end
