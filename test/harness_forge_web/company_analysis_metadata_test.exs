defmodule HarnessForgeWeb.CompanyAnalysisMetadataTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias HarnessForgeWeb.Company.Analysis

  @source_id "10000000-0000-4000-8000-000000000001"
  @revision_id "20000000-0000-4000-8000-000000000001"
  @other_source_id "10000000-0000-4000-8000-000000000002"
  @other_revision_id "20000000-0000-4000-8000-000000000002"
  @hash String.duplicate("a", 64)
  @date "2026-01-10T10:11:12.123456+02:00"
  @url "https://example.com/captured-policy?view=original&lang=en#review"
  @link_text "Open stored source link (opens in a new tab)"
  @fallback "Current capture details are not shown from the loaded metadata. The original excerpt and pin are retained; this display alone does not establish whether the capture changed."

  test "exact match reaches the shared report and Company's builder with metadata outside the quote" do
    f = fixture()

    for {html, id} <- [
          {report_html(f.claim, [f.source]), "evidence-report"},
          {builder_html(f.claim, [f.source]), "company-analysis-original"}
        ] do
      assert_original_pin(html, f.claim)

      assert text(html, "##{id}") =~
               "Current source name (may have changed): Synthetic current policy"

      assert attributes(html, "##{id} time", "datetime") == [@date]
      assert text(html, "##{id} time") == @date
      assert hrefs(html, "##{id} a") == [@url]
      refute text(html, "##{id} blockquote") =~ "Current source name"
      refute text(html, "##{id} blockquote") =~ "Captured at:"
      refute text(html, "##{id}") =~ @fallback

      assert text(html, "##{id}") =~
               "This link was stored with the capture. Its destination may have changed."

      assert text(html, "##{id}") =~ @hash
      assert attributes(html, "##{id} a", "target") == ["_blank"]
      assert attributes(html, "##{id} a", "rel") == ["noopener noreferrer"]

      assert attributes(html, "##{id} a", "aria-label") == [
               @link_text <> ", finding 1, excerpt 1"
             ]

      for attribute <- ~w(phx-click phx-hook data-phx-link tabindex) do
        assert attributes(html, "##{id} a", attribute) == []
      end
    end
  end

  test "changing only the current name keeps the qualifier and exact capture" do
    f = fixture()
    source = Map.put(f.source, "title", "Renamed CURRENT source")
    html = report_html(f.claim, [source])
    assert text(html) =~ "Current source name (may have changed): Renamed CURRENT source"
    refute text(html) =~ "Synthetic current policy"
    assert attributes(html, "time", "datetime") == [@date]
    assert hrefs(html) == [@url]
    assert_original_pin(html, f.claim)
  end

  test "validated body-free summary supplies the exact capture without a legacy latest pointer" do
    f = fixture()

    summary =
      f.source
      |> Map.delete("latest_revision_id")
      |> Map.put("eligible", true)
      |> put_in(["latest_revision", "body_bytes"], byte_size(f.source["latest_revision"]["body"]))
      |> update_in(["latest_revision"], &Map.delete(&1, "body"))

    html = report_html(f.claim, [summary])
    assert text(html) =~ "Synthetic current policy"
    assert hrefs(html) == [@url]
    assert attributes(html, "time", "datetime") == [@date]
    assert_original_pin(html, f.claim)

    for unavailable <- [
          Map.put(summary, "eligible", false),
          put_in(summary, ["latest_revision", "body_bytes"], 0),
          Map.put(summary, "latest_revision_id", @other_revision_id)
        ] do
      assert_whole_pin_fallback(report_html(f.claim, [unavailable]), f.claim)
    end
  end

  for {field, value, fallback} <- [
        {"title", nil, "Current source name unavailable."},
        {"title", " \t ", "Current source name unavailable."},
        {"title", %{"unusable" => true}, "Current source name unavailable."},
        {"title", <<255>>, "Current source name unavailable."},
        {"captured_at", nil, "Capture date unavailable."},
        {"captured_at", "2026-02-30T10:00:00Z", "Capture date unavailable."},
        {"captured_at", "2026-01-10", "Capture date unavailable."},
        {"captured_at", <<255>>, "Capture date unavailable."},
        {"source_url", nil, "Source link unavailable."},
        {"source_url", "javascript:hostile-metadata()", "Source link unavailable."}
      ] do
    @field field
    @value value
    @field_fallback fallback
    test "missing or unusable #{field}=#{inspect(value)} has an independent fallback" do
      f = fixture()

      source =
        if @field == "title",
          do: Map.put(f.source, @field, @value),
          else: put_in(f.source, ["latest_revision", @field], @value)

      html = report_html(f.claim, [source])
      assert text(html) =~ @field_fallback
      refute text(html) =~ @fallback
      assert_original_pin(html, f.claim)

      if @field != "title", do: assert(text(html) =~ "Synthetic current policy")
      if @field != "captured_at", do: assert(attributes(html, "time", "datetime") == [@date])
      if @field != "source_url", do: assert(hrefs(html) == [@url])
      if @field == "source_url", do: assert(hrefs(html) == [])
      if @field == "source_url" and is_binary(@value), do: refute(html =~ @value)
    end
  end

  for scenario <- ~w(
        missing_source incomplete_source duplicate_source malformed_source struct_source missing_ref duplicate_ref
        conflicting_duplicate_ref malformed_ref struct_ref malformed_ref_list missing_context
        wrong_ref_source wrong_ref_revision invalid_ref_id missing_ref_hash malformed_ref_hash
        wrong_source_id old_revision wrong_latest_pointer wrong_revision_source
        same_hash_other_revision same_hash_other_source wrong_hash invalid_revision_hash invalid_matching_hashes
        inactive_source hidden_revision malformed_revision struct_revision missing_claim_workspace
        blank_claim_workspace wrong_source_workspace wrong_revision_workspace
        missing_source_workspace missing_revision_workspace all_missing_workspaces
        missing_citation_source missing_citation_revision malformed_citation_source malformed_citation_revision
      ) do
    @scenario scenario
    test "#{scenario} refuses the entire metadata projection while retaining the original pin" do
      f = fixture()
      {claim, sources} = mismatch(f, @scenario)
      assert_whole_pin_fallback(report_html(claim, sources), claim)
    end
  end

  test "a stale capture also falls back through the builder's real report call" do
    f = fixture()
    {claim, sources} = mismatch(f, "old_revision")
    html = builder_html(claim, sources)
    assert_whole_pin_fallback(html, claim, "#company-analysis-original")
    assert hrefs(html, "#company-analysis-original a") == []
  end

  test "older callers safely default to empty sources" do
    f = fixture()
    html = render_component(&Analysis.report/1, claim: f.claim, id: "legacy-report")
    assert_whole_pin_fallback(html, f.claim)
  end

  test "valid uncited context remains fully disclosed without borrowing its metadata" do
    f = fixture()

    uncited = %{
      "source_id" => @other_source_id,
      "revision_id" => @other_revision_id,
      "body_hash" => String.duplicate("b", 64)
    }

    claim = put_in(f.claim, ["basis", "context", "sources"], [f.ref, uncited])
    html = report_html(claim, [f.source])
    assert text(html) =~ "Included source #{@other_source_id}"
    assert text(html) =~ @other_revision_id
    assert text(html) =~ uncited["body_hash"]
    assert hrefs(html) == [@url]
    assert_original_pin(html, claim)
  end

  test "same body hash on a different identity cannot replace the cited source" do
    f = fixture()

    other =
      f.source
      |> Map.put("id", @other_source_id)
      |> Map.put("title", "Another source with identical bytes")
      |> Map.put("latest_revision_id", @other_revision_id)
      |> put_in(["latest_revision", "id"], @other_revision_id)
      |> put_in(["latest_revision", "source_id"], @other_source_id)

    assert_whole_pin_fallback(report_html(f.claim, [other]), f.claim)
    html = report_html(f.claim, [other, f.source])
    assert text(html) =~ "Synthetic current policy"
    refute text(html) =~ "Another source with identical bytes"
    assert hrefs(html) == [@url]
  end

  test "hostile current titles and original excerpts remain escaped text in both render paths" do
    f = fixture()
    title = "<script>alert('title')</script><img src=x onerror=alert(1)>"
    snippet = "<svg onload=alert('excerpt')>Café & policy</svg>"

    claim =
      put_in(
        f.claim,
        ["basis", "report", "findings", Access.at(0), "citations", Access.at(0), "snippet"],
        snippet
      )

    source = Map.put(f.source, "title", title)

    for html <- [report_html(claim, [source]), builder_html(claim, [source])] do
      assert text(html) =~ title
      assert text(html, "blockquote") =~ snippet
      assert Enum.empty?(query(html, "script, img, svg"))
      assert html =~ "&lt;script&gt;"
      assert html =~ "&lt;svg"
      assert hrefs(html, ".company-analysis-report a") == [@url]
    end
  end

  test "repeated original citations retain distinct ordinal links and report-scoped associations" do
    f = fixture()
    finding = hd(f.claim["basis"]["report"]["findings"])
    repeated = Map.put(finding, "citations", finding["citations"] ++ finding["citations"])
    claim = put_in(f.claim, ["basis", "report", "findings"], [repeated, finding])

    html =
      report_html(claim, [f.source], "report-one") <> report_html(claim, [f.source], "report-two")

    assert Enum.count(query(html, "blockquote")) == 6
    ids = attributes(html, "a", "id")
    assert length(ids) == 6
    assert length(Enum.uniq(ids)) == 6
    assert Enum.all?(attributes(html, "a", "aria-label"), &String.starts_with?(&1, @link_text))

    for id <- attributes(html, "a", "aria-describedby") do
      assert Enum.count(query(html, "##{id}")) == 1
    end
  end

  @url_prefix "https://example.com/"
  @url_at_limit @url_prefix <> String.duplicate("a", 2048 - byte_size(@url_prefix))
  @multibyte_at_limit @url_prefix <>
                        String.duplicate("a", 2048 - byte_size(@url_prefix) - 2) <> "é"

  for url <- [
        "http://localhost/source",
        "http://127.0.0.1:8878/source",
        "https://example.com:1/source",
        "https://example.com:65535/source",
        "https://example.com:00080/source",
        "HTTP://EXAMPLE.COM/capture",
        "https://xn--bcher-kva.example/a%20path?x=%2F#stored",
        "https://valid-host.example./capture",
        "http://[::1]:8878/source",
        "https://[2001:db8::1]/source",
        @url,
        @url_at_limit,
        @multibyte_at_limit
      ] do
    @accepted_url url
    test "selector and report preserve accepted URL bytes #{inspect(String.slice(url, 0, 90))} (#{byte_size(url)} bytes, #{String.length(url)} characters)" do
      f = fixture()
      source = put_in(f.source, ["latest_revision", "source_url"], @accepted_url)
      assert hrefs(report_html(f.claim, [source])) == [@accepted_url]
      assert hrefs(builder_html(nil, [source]), ".company-analysis-source a") == [@accepted_url]
    end
  end

  for {name, url} <- [
        {"absent", nil},
        {"nontext", 42},
        {"empty", ""},
        {"javascript", "javascript:hostile-url()"},
        {"data", "data:text/html,hostile-url"},
        {"relative", "/hostile-url"},
        {"protocol relative", "//example.com/hostile-url"},
        {"missing authority", "https:example.com/hostile-url"},
        {"userinfo", "https://user:password@example.com/hostile-url"},
        {"empty userinfo", "https://@example.com/hostile-url"},
        {"leading space", " https://example.com/hostile-url"},
        {"trailing space", "https://example.com/hostile-url "},
        {"newline", "https://example.com/hostile-url\n"},
        {"tab", "https://example.com/hostile\turl"},
        {"unicode separator", "https://example.com/hostile\u00a0url"},
        {"unicode format", "https://example.com/hostile\u200burl"},
        {"control", "https://example.com/hostile" <> <<1>> <> "url"},
        {"delete", "https://example.com/hostile" <> <<127>> <> "url"},
        {"backslash", "https://example.com/hostile\\url"},
        {"bad percent", "https://example.com/hostile%XZurl"},
        {"short percent", "https://example.com/hostile%2"},
        {"encoded C0", "https://example.com/hostile%00url"},
        {"encoded newline", "https://example.com/hostile%0Aurl"},
        {"encoded unit separator", "https://example.com/hostile%1furl"},
        {"encoded delete", "https://example.com/hostile%7Furl"},
        {"encoded backslash", "https://example.com/hostile%5curl"},
        {"empty host", "https:///hostile-url"},
        {"unicode host", "https://bücher.example/hostile-url"},
        {"encoded host", "https://%65xample.com/hostile-url"},
        {"underscore host", "https://bad_host.example/hostile-url"},
        {"empty DNS label", "https://bad..example/hostile-url"},
        {"leading host hyphen", "https://-bad.example/hostile-url"},
        {"trailing host hyphen", "https://bad-.example/hostile-url"},
        {"oversized DNS label",
         "https://" <> String.duplicate("a", 64) <> ".example/hostile-url"},
        {"bad IPv4", "https://256.1.2.3/hostile-url"},
        {"short IPv4", "https://127.1/hostile-url"},
        {"numeric host", "https://2130706433/hostile-url"},
        {"hex numeric host", "https://0x7f000001/hostile-url"},
        {"ambiguous IPv4", "https://0177.0.0.1/hostile-url"},
        {"unbracketed IPv6", "https://::1/hostile-url"},
        {"broken IPv6 bracket", "https://[::1/hostile-url"},
        {"bad IPv6", "https://[gg::1]/hostile-url"},
        {"bracketed IPv4", "https://[127.0.0.1]/hostile-url"},
        {"IPv6 suffix", "https://[::1]bad/hostile-url"},
        {"zero port", "https://example.com:0/hostile-url"},
        {"large port", "https://example.com:65536/hostile-url"},
        {"empty port", "https://example.com:/hostile-url"},
        {"negative port", "https://example.com:-1/hostile-url"},
        {"signed port", "https://example.com:+80/hostile-url"},
        {"text port", "https://example.com:abc/hostile-url"},
        {"double port", "https://example.com:80:90/hostile-url"},
        {"invalid UTF8", "https://example.com/hostile" <> <<255>>},
        {"2049 bytes", @url_at_limit <> "a"},
        {"multibyte 2049 bytes", @multibyte_at_limit <> "a"},
        {"many multibyte bytes", @url_prefix <> String.duplicate("é", 1100)}
      ] do
    @rejected_url url
    test "selector and report refuse #{name} without echoing rejected URL data" do
      f = fixture()
      source = put_in(f.source, ["latest_revision", "source_url"], @rejected_url)

      for html <- [report_html(f.claim, [source]), builder_html(nil, [source])] do
        assert hrefs(html) == []
        assert text(html) =~ "Source link unavailable."
        if is_binary(@rejected_url) and @rejected_url != "", do: refute(html =~ @rejected_url)
      end
    end
  end

  defp fixture do
    citation = %{
      "source_id" => @source_id,
      "revision_id" => @revision_id,
      "start_byte" => 7,
      "end_byte" => 35,
      "snippet" => "Café retains two reviewers."
    }

    ref = %{"source_id" => @source_id, "revision_id" => @revision_id, "body_hash" => @hash}
    guidance = Map.new(Analysis.fields(), &{&1, "Synthetic original #{&1}"})

    claim = %{
      "id" => "30000000-0000-4000-8000-000000000001",
      "workspace_id" => "synthetic-workspace",
      "revision_hash" => String.duplicate("c", 64),
      "text" => "Synthetic recommendation",
      "status" => "proposed",
      "basis" => %{
        "kind" => "company_analysis",
        "project_id" => "synthetic-project",
        "goal_id" => "synthetic-goal",
        "goal_content_hash" => String.duplicate("d", 64),
        "context" => %{"sources" => [ref]},
        "provider" => "synthetic",
        "model" => "not-requested",
        "guidance" => guidance,
        "report" => %{
          "recommendation" =>
            Map.merge(guidance, %{
              "status" => "supported",
              "goal_rationale" => "Saved synthetic intent"
            }),
          "uncertainty" => "Synthetic presentation fixture only",
          "findings" => [
            %{"kind" => "practice", "statement" => "Retain review", "citations" => [citation]}
          ]
        }
      }
    }

    source = %{
      "id" => @source_id,
      "workspace_id" => "synthetic-workspace",
      "status" => "active",
      "title" => "Synthetic current policy",
      "latest_revision_id" => @revision_id,
      "latest_revision" => %{
        "id" => @revision_id,
        "source_id" => @source_id,
        "workspace_id" => "synthetic-workspace",
        "body_hash" => @hash,
        "body" => "prefix Café retains two reviewers.",
        "captured_at" => @date,
        "source_url" => @url,
        "source_updated_at" => "not-a-capture-date"
      }
    }

    %{claim: claim, source: source, ref: ref}
  end

  defp mismatch(f, scenario) do
    refs = ["basis", "context", "sources"]

    case scenario do
      "missing_source" ->
        {f.claim, []}

      "incomplete_source" ->
        {f.claim, [Map.take(f.source, ["id"])]}

      "duplicate_source" ->
        {f.claim, [f.source, f.source]}

      "malformed_source" ->
        {f.claim, [f.source, "not-a-DTO"]}

      "struct_source" ->
        {f.claim, [f.source, %URI{}]}

      "missing_ref" ->
        {put_in(f.claim, refs, []), [f.source]}

      "duplicate_ref" ->
        {put_in(f.claim, refs, [f.ref, f.ref]), [f.source]}

      "conflicting_duplicate_ref" ->
        {put_in(f.claim, refs, [f.ref, Map.put(f.ref, "revision_id", @other_revision_id)]),
         [f.source]}

      "malformed_ref" ->
        {put_in(f.claim, refs, [f.ref, "not-a-ref"]), [f.source]}

      "struct_ref" ->
        {put_in(f.claim, refs, [f.ref, %URI{}]), [f.source]}

      "malformed_ref_list" ->
        {put_in(f.claim, refs, %{}), [f.source]}

      "missing_context" ->
        {update_in(f.claim, ["basis"], &Map.delete(&1, "context")), [f.source]}

      "wrong_ref_source" ->
        {put_in(f.claim, refs, [Map.put(f.ref, "source_id", @other_source_id)]), [f.source]}

      "wrong_ref_revision" ->
        {put_in(f.claim, refs, [Map.put(f.ref, "revision_id", @other_revision_id)]), [f.source]}

      "invalid_ref_id" ->
        {put_in(f.claim, refs, [Map.put(f.ref, "source_id", "not-a-UUID")]), [f.source]}

      "missing_ref_hash" ->
        {put_in(f.claim, refs, [Map.delete(f.ref, "body_hash")]), [f.source]}

      "malformed_ref_hash" ->
        {put_in(f.claim, refs, [Map.put(f.ref, "body_hash", %{})]), [f.source]}

      "wrong_source_id" ->
        {f.claim, [Map.put(f.source, "id", @other_source_id)]}

      "old_revision" ->
        {f.claim,
         [
           f.source
           |> Map.put("latest_revision_id", @other_revision_id)
           |> put_in(["latest_revision", "id"], @other_revision_id)
         ]}

      "wrong_latest_pointer" ->
        {f.claim, [Map.put(f.source, "latest_revision_id", @other_revision_id)]}

      "wrong_revision_source" ->
        {f.claim, [put_in(f.source, ["latest_revision", "source_id"], @other_source_id)]}

      "same_hash_other_revision" ->
        {f.claim, [put_in(f.source, ["latest_revision", "id"], @other_revision_id)]}

      "same_hash_other_source" ->
        {f.claim, [put_in(f.source, ["latest_revision", "source_id"], @other_source_id)]}

      "wrong_hash" ->
        {f.claim, [put_in(f.source, ["latest_revision", "body_hash"], String.duplicate("b", 64))]}

      "invalid_revision_hash" ->
        {f.claim, [put_in(f.source, ["latest_revision", "body_hash"], "bad-hash")]}

      "invalid_matching_hashes" ->
        {put_in(f.claim, refs, [Map.put(f.ref, "body_hash", "bad-hash")]),
         [put_in(f.source, ["latest_revision", "body_hash"], "bad-hash")]}

      "inactive_source" ->
        {f.claim, [Map.put(f.source, "status", "revoked")]}

      "hidden_revision" ->
        {f.claim, [Map.put(f.source, "latest_revision", nil)]}

      "malformed_revision" ->
        {f.claim, [Map.put(f.source, "latest_revision", "not-a-revision")]}

      "struct_revision" ->
        {f.claim, [Map.put(f.source, "latest_revision", %URI{})]}

      "missing_claim_workspace" ->
        {Map.delete(f.claim, "workspace_id"), [f.source]}

      "blank_claim_workspace" ->
        {Map.put(f.claim, "workspace_id", " "), [f.source]}

      "wrong_source_workspace" ->
        {f.claim, [Map.put(f.source, "workspace_id", "different-workspace")]}

      "wrong_revision_workspace" ->
        {f.claim, [put_in(f.source, ["latest_revision", "workspace_id"], "different-workspace")]}

      "missing_source_workspace" ->
        {f.claim, [Map.delete(f.source, "workspace_id")]}

      "missing_revision_workspace" ->
        {f.claim, [update_in(f.source, ["latest_revision"], &Map.delete(&1, "workspace_id"))]}

      "all_missing_workspaces" ->
        {Map.delete(f.claim, "workspace_id"),
         [
           f.source
           |> Map.delete("workspace_id")
           |> update_in(["latest_revision"], &Map.delete(&1, "workspace_id"))
         ]}

      "missing_citation_source" ->
        {update_citation(f.claim, &Map.delete(&1, "source_id")), [f.source]}

      "missing_citation_revision" ->
        {update_citation(f.claim, &Map.delete(&1, "revision_id")), [f.source]}

      "malformed_citation_source" ->
        {update_citation(f.claim, &Map.put(&1, "source_id", 42)), [f.source]}

      "malformed_citation_revision" ->
        {update_citation(f.claim, &Map.put(&1, "revision_id", "")), [f.source]}
    end
  end

  defp update_citation(claim, fun),
    do:
      update_in(
        claim,
        ["basis", "report", "findings", Access.at(0), "citations", Access.at(0)],
        fun
      )

  defp report_html(claim, sources, id \\ "evidence-report"),
    do: render_component(&Analysis.report/1, claim: claim, sources: sources, id: id)

  defp builder_html(claim, sources) do
    project = %{
      "id" => "synthetic-project",
      "payload" => %{"name" => "Synthetic project", "source_ids" => Enum.map(sources, & &1["id"])}
    }

    render_component(&Analysis.builder/1,
      target: "#company-panel",
      generation: "synthetic-generation",
      reset_token: 1,
      draft: %{"project_id" => project["id"], "source_ids" => [], "goal_id" => ""},
      pins: %{},
      projects: [project],
      sources: sources,
      goals: [],
      profile: nil,
      claims: [],
      selected: claim,
      edit: if(claim, do: Analysis.edit(claim)),
      dirty: false,
      pending: nil,
      error: nil,
      notice: nil,
      model_status: %{"availability" => "unavailable"},
      open: true
    )
  end

  defp assert_original_pin(html, claim, selector \\ ".company-analysis-report") do
    citation = hd(hd(claim["basis"]["report"]["findings"])["citations"])
    quoted = text(html, selector <> " blockquote")
    assert quoted =~ citation["snippet"]
    assert quoted =~ "Source #{citation["source_id"]}"
    assert quoted =~ "revision #{citation["revision_id"]}"

    assert quoted =~
             "UTF-8 bytes #{citation["start_byte"]}–#{citation["end_byte"]} (exclusive end)"
  end

  defp assert_whole_pin_fallback(html, claim, selector \\ ".company-analysis-report") do
    assert_original_pin(html, claim, selector)
    assert text(html, selector) =~ @fallback
    refute text(html, selector) =~ "Current source name"
    refute text(html, selector) =~ "Captured at:"
    refute text(html, selector) =~ "Source link unavailable."
    assert hrefs(html, selector <> " a") == []
    assert Enum.empty?(query(html, selector <> " time"))
  end

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp text(html, selector \\ nil)

  defp text(html, nil),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> normalize_text()

  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text() |> normalize_text()
  defp normalize_text(value), do: value |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp attributes(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)
  defp hrefs(html, selector \\ "a"), do: attributes(html, selector, "href")
end
