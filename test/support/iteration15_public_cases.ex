defmodule HarnessForge.Iteration15PublicCases do
  @moduledoc "Independently frozen synthetic public development cases; no semantic-quality oracle."

  @specification Jason.decode!(~S"""
                 {
                 "format": "iteration15-public-development-cases-v1",
                 "frozen_before_candidate_results": true,
                 "domain": "Synthetic public archive lending room",
                 "goal": {
                   "title": "Future goal: reduce visitor queue confusion",
                   "owner": "Synthetic public archive steward",
                   "acceptance": "Explore shelf orientation prompts as a future improvement; this goal authorises no change to object movement duties."
                 },
                 "documents": [
                   {
                     "id": "custody-policy",
                     "external_id": "custody-policy.md",
                     "title": "Standing custody ledger policy — approved January",
                     "body": "2026-01-12 approved standing policy. Custody ledger is the receipt register for every outgoing object. A numbered ledger entry and signed handoff receipt are mandatory before any movement. A condition photograph is required. This standing obligation has no expiry."
                   },
                   {
                     "id": "ceramic-exception",
                     "external_id": "ceramic-exception.md",
                     "title": "Ceramic courier concession — approved March",
                     "body": "2026-03-02 approved scoped exception. Ceramic courier loans sealed before opening may use a numbered crate label instead of a condition photograph. This concession applies only to sealed ceramic courier loans. The custody ledger and signed handoff receipt remain mandatory."
                   },
                   {
                     "id": "cracked-tray-incident",
                     "external_id": "cracked-tray-incident.md",
                     "title": "Cracked tray incident — observed March",
                     "body": "2026-03-07 incident review. A ceramic courier consignment arrived with a cracked tray after its foam cradle was omitted. Contrary evidence: the numbered crate label did not prevent impact damage. The incident recommends checking the foam cradle; it does not approve a new standing obligation or revoke the photographic exception."
                   },
                   {
                     "id": "barcode-current",
                     "external_id": "barcode-current.md",
                     "title": "Barcode register instruction — approved April",
                     "body": "2026-04-05 approved current guidance. Barcode register entries are required at the receiving desk. This instruction replaces the superseded paper docket guidance dated 2026-02-01. It does not change custody ledger duties."
                   },
                   {
                     "id": "paper-superseded",
                     "external_id": "paper-superseded.md",
                     "title": "Paper docket guidance — superseded February",
                     "body": "2026-02-01 superseded guidance. Paper docket entries were sufficient at the receiving desk. This historical instruction was replaced by the approved barcode register instruction on 2026-04-05 and is no longer current."
                   },
                   {
                     "id": "waiver-abandoned",
                     "external_id": "waiver-abandoned.md",
                     "title": "Ledger waiver discussion — abandoned April",
                     "body": "2026-04-08 abandoned discussion. A proposal suggested waiving the custody ledger for trusted borrowers. The waiver discussion was closed without approval. It changes no standing obligation and must not be described as adopted guidance."
                   },
                   {
                     "id": "automation-future",
                     "external_id": "automation-future.md",
                     "title": "Automation aspiration — future intent April",
                     "body": "2026-04-10 future aspiration. Automation could reduce visitor queue confusion through shelf orientation prompts. This future automation goal has no approved implementation, deadline or current procedural authority."
                   },
                   {
                     "id": "archive-transport",
                     "external_id": "archive-transport.md",
                     "title": "Archive transport planning note",
                     "body": "Archive transport planning lists van departure times and route distances. It describes vehicle scheduling only and establishes no custody controls."
                   },
                   {
                     "id": "exhibition-rosters",
                     "external_id": "exhibition-rosters.md",
                     "title": "Exhibition rosters",
                     "body": "Exhibition rosters list gallery attendants and public opening hours. They establish no object movement requirements."
                   },
                   {
                     "id": "volunteer-shifts",
                     "external_id": "volunteer-shifts.md",
                     "title": "Volunteer shift calendars",
                     "body": "Volunteer shift calendars allocate welcome-desk staffing. Shift swaps change staffing availability only."
                   },
                   {
                     "id": "visitor-timetables",
                     "external_id": "visitor-timetables.md",
                     "title": "Visitor timetables",
                     "body": "Visitor timetables advertise guided tours, café hours and accessible entrances. They are public visitor information."
                   },
                   {
                     "id": "packing-checklists",
                     "external_id": "packing-checklists.md",
                     "title": "Packing checklist stationery stock",
                     "body": "Packing checklists is the label on a stationery stock shelf. The stock inventory records blank form counts only and prescribes no packing procedure."
                   },
                   {
                     "id": "empty-filler",
                     "external_id": "empty-filler.md",
                     "title": "Unrelated astronomy notice",
                     "body": "The astronomy notice lists telescope cleaning dates and star map print sizes. It contains no lending-room procedure or insurance amounts."
                   }
                 ],
                 "cases": [
                   {
                     "id": "middle-policy",
                     "category": "position-middle",
                     "question": "Explain archive transport planning and custody ledger duties alongside exhibition rosters, volunteer shifts, visitor timetables and packing checklists.",
                     "indispensable": [
                       "custody-policy"
                     ],
                     "contrary": [],
                     "relevant": [
                       "custody-policy"
                     ],
                     "expected": "The numbered ledger entry and signed handoff receipt remain mandatory; the standing photograph requirement is general guidance.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "start-policy",
                     "category": "position-start",
                     "question": "Custody ledger duties: explain archive transport planning alongside exhibition rosters, volunteer shifts, visitor timetables and packing checklists.",
                     "indispensable": [
                       "custody-policy"
                     ],
                     "contrary": [],
                     "relevant": [
                       "custody-policy"
                     ],
                     "expected": "Same standing ledger obligation as middle-policy.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "end-policy",
                     "category": "position-end",
                     "question": "Explain archive transport planning alongside exhibition rosters, volunteer shifts, visitor timetables and packing checklists: custody ledger duties.",
                     "indispensable": [
                       "custody-policy"
                     ],
                     "contrary": [],
                     "relevant": [
                       "custody-policy"
                     ],
                     "expected": "Same standing ledger obligation as middle-policy.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "linked-middle",
                     "category": "policy-exception-contrary",
                     "question": "Explain archive transport planning around custody ledger duties, ceramic courier exceptions and cracked tray incidents alongside exhibition rosters and volunteer shift calendars.",
                     "indispensable": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "contrary": [
                       "cracked-tray-incident"
                     ],
                     "relevant": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "expected": "Preserve the ledger and receipt, limit the photograph concession to sealed ceramic courier loans, and show foam-cradle damage evidence without promoting it to approved policy.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "linked-reordered",
                     "category": "reordered",
                     "question": "Volunteer shift calendars and exhibition rosters accompany cracked tray incidents, ceramic courier exceptions and custody ledger duties in archive transport planning. Explain their applicable obligations.",
                     "indispensable": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "contrary": [
                       "cracked-tray-incident"
                     ],
                     "relevant": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "expected": "Same three source obligations as linked-middle after reordering.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "linked-focused",
                     "category": "focused-baseline-positive",
                     "question": "What do custody ledger rules and ceramic courier exceptions require after the cracked tray incident?",
                     "indispensable": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "contrary": [
                       "cracked-tray-incident"
                     ],
                     "relevant": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "expected": "Same three source obligations as linked-middle; retained as a focused positive control.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "lexical-paraphrase",
                     "category": "lexically-labelled-paraphrase",
                     "question": "Which receipt register obligation survives the ceramic courier concession, and what foam cradle failure challenges its use?",
                     "indispensable": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "contrary": [
                       "cracked-tray-incident"
                     ],
                     "relevant": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "expected": "Receipt register, concession and foam cradle are explicit source aliases. This exercises lexical paraphrase, not synonym inference.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "semantic-paraphrase-limit",
                     "category": "semantic-paraphrase-lexical-limit",
                     "question": "Which paperwork proves each handoff when delicate pottery travels, and what cushioning mishap warns against shortcuts?",
                     "indispensable": [],
                     "contrary": [],
                     "relevant": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "expected": "Diagnostic probe only. Human semantic relevance is declared, but synonym-only recall is outside this lexical change's acceptance promise; do not claim semantic matching.",
                     "acceptance": "diagnostic_only"
                   },
                   {
                     "id": "guidance-status",
                     "category": "current-history-abandoned-future",
                     "question": "For barcode register guidance, distinguish the approved current instruction, superseded paper docket, abandoned waiver discussion and future automation goal.",
                     "indispensable": [
                       "barcode-current",
                       "paper-superseded",
                       "waiver-abandoned",
                       "automation-future"
                     ],
                     "contrary": [],
                     "relevant": [
                       "barcode-current",
                       "paper-superseded",
                       "waiver-abandoned",
                       "automation-future"
                     ],
                     "expected": "Distinguish current barcode instruction, historical paper instruction, unapproved abandoned waiver and nonbinding future aspiration; infer no automatic temporal authority.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "repeated-policy",
                     "category": "repeated-terms",
                     "question": "Custody custody ledger ledger: which numbered ledger entry and signed handoff receipt duties remain?",
                     "indispensable": [
                       "custody-policy"
                     ],
                     "contrary": [],
                     "relevant": [
                       "custody-policy"
                     ],
                     "expected": "Repeated words do not erase the standing ledger obligation or create extra searches.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "unicode-linked",
                     "category": "unicode",
                     "question": "Café transport: which custody ledger duties remain for ceramic courier loans after the cracked tray incident?",
                     "indispensable": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "contrary": [
                       "cracked-tray-incident"
                     ],
                     "relevant": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "expected": "Valid UTF-8 question and exact UTF-8 selected source bytes; same linked obligations.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "max-admitted-characters",
                     "category": "max-input",
                     "question": "Explain archive transport planning and custody ledger duties with ceramic courier exceptions, cracked tray incidents, exhibition rosters, volunteer shift calendars, visitor timetables and packing checklists; preserve each obligation during review..........",
                     "indispensable": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "contrary": [
                       "cracked-tray-incident"
                     ],
                     "relevant": [
                       "custody-policy",
                       "ceramic-exception",
                       "cracked-tray-incident"
                     ],
                     "expected": "Exactly 256 characters, within 1024 bytes; no silent term truncation. Same linked source obligations.",
                     "acceptance": "source_obligations"
                   },
                   {
                     "id": "no-answer",
                     "category": "no-answer",
                     "question": "What is the annual insurance premium for the lunar observatory?",
                     "indispensable": [],
                     "contrary": [],
                     "relevant": [],
                     "expected": "No source establishes this amount. Retrieval may return goal/background evidence and be structurally ready. No supported insurance rule may be claimed; question-derived zero-hit checks await the candidate interface.",
                     "acceptance": "no_answer_probe"
                   },
                   {
                     "id": "max-admitted-utf8-bytes",
                     "category": "max-input-no-content-terms",
                     "question": "🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭🧭",
                     "indispensable": [],
                     "contrary": [],
                     "relevant": [],
                     "expected": "Exactly 256 graphemes and 1024 UTF-8 bytes. Accept input and preserve goal-only fallback without a new answerability gate.",
                     "acceptance": "admission_only"
                   },
                   {
                     "id": "reject-over-character-limit",
                     "category": "rejected-input",
                     "question": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                     "indispensable": [],
                     "contrary": [],
                     "relevant": [],
                     "expected": "257 characters: reject as invalid_input before search.",
                     "acceptance": "invalid_input"
                   },
                   {
                     "id": "reject-over-byte-limit",
                     "category": "rejected-input",
                     "question": "👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦👩‍👩‍👧‍👦",
                     "indispensable": [],
                     "contrary": [],
                     "relevant": [],
                     "expected": "42 grapheme clusters but 1050 UTF-8 bytes: reject as invalid_input before search.",
                     "acceptance": "invalid_input"
                   }
                 ],
                 "source_obligation_policy": "All indispensable and applicable contrary logical IDs must be candidates and selected for source_obligations cases. Relevant IDs determine noise accounting. Other probes add no semantic answerability gate. Historical iteration14 regression remains separate.",
                 "comparison_policy": "Root executes baseline before A code, then candidate against this frozen spec. Prefer same captured revisions. Reconstituted scopes disclose different UUIDs and prove body/goal SHA256 parity. Preserve all failed case data, candidate/selected IDs, critical/contrary misses, noise count/bytes, context/citations/caps, run IDs/digests, monotonic timing, repetitions and cold/warm conditions."
                 }
                 """)

  def specification, do: @specification
  def documents, do: @specification["documents"]
  def cases, do: @specification["cases"]
  def goal, do: @specification["goal"]

  @doc "Fetch one already frozen case without changing its question or obligations."
  def fetch_case!(id) do
    Enum.find(cases(), &(&1["id"] == id)) ||
      raise ArgumentError, "unknown frozen public case: #{inspect(id)}"
  end

  def frozen_specification_hash,
    do: "e12934f407f484a988a8eb737cf16084c00e59846d650c44feb541b1a0d9387c"

  alias HarnessForge.{Company, Contracts, Evidence, Goals}
  alias HarnessForge.Evidence.{Capture, Corpora, Goal, Passages, Store}

  @doc "Public CRUD plus an actual local capture; the caller owns sandbox/scanner lifetime."
  def create!(root, caller) do
    directory = Path.join(root, "public-archive-documents")
    File.mkdir_p!(directory)

    {:ok, connection} =
      Evidence.connect(%{
        "name" => "Iteration15 synthetic public archive",
        "provider" => "local",
        "directory" => directory
      })

    sources =
      Enum.map(documents(), fn document ->
        File.write!(Path.join(directory, document["external_id"]), document["body"])

        {:ok, source} =
          Evidence.import_markdown(connection["id"], %{
            "external_id" => document["external_id"],
            "title" => document["title"],
            "body" => document["body"],
            "metadata" => %{"synthetic" => true}
          })

        source
      end)

    {:ok, goal} = Goals.add_goal(goal())

    {:ok, profile} =
      Company.save_profile(%{
        "name" => "Synthetic public archive",
        "source_ids" => [],
        "goal_ids" => [goal["id"]]
      })

    {:ok, repository} =
      Company.create_repository(%{
        "name" => "Public archive catalogue",
        "identity" => "synthetic-public/archive-catalogue",
        "purpose" => "Synthetic public development evidence",
        "owner" => "Public archive steward"
      })

    {:ok, project} =
      Company.create_project(%{
        "name" => "Public archive lending",
        "repository_ids" => [repository["id"]],
        "source_ids" => []
      })

    {:ok, corpus} = Corpora.create(%{"name" => "Iteration15 public archive corpus"}, caller)

    changes =
      Enum.map(sources, fn source ->
        %{
          "source_id" => source["id"],
          "revision_id" => source["latest_revision"]["id"],
          "action" => "include"
        }
      end)

    {:ok, current} = Corpora.apply_members(corpus["id"], 0, changes, caller)

    {:ok, _} =
      Company.bind_corpus(
        project["id"],
        corpus["id"],
        profile["content_hash"],
        project["content_hash"],
        caller
      )

    {:ok, capture} =
      Capture.start_capture(
        corpus["id"],
        connection["id"],
        current["semantic_generation"],
        caller
      )

    {:ok, captured} = Capture.run(capture["run_id"])
    true = captured["capture"]["complete"]
    {:ok, all_sources} = Evidence.list_sources()

    sources_by_logical_id =
      Map.new(documents(), fn document ->
        source =
          Enum.find(all_sources, fn source ->
            source["connection_id"] == connection["id"] and
              source["external_id"] == document["external_id"]
          end)

        true = is_map(source)
        true = source["latest_revision"]["body"] == document["body"]
        {:ok, _} = Passages.index_revision(source["latest_revision"]["id"])
        {document["id"], source}
      end)

    {:ok, current} = Corpora.get(corpus["id"])
    {:ok, goal_record} = Store.get(Goal, goal["id"])

    %{
      connection: connection,
      corpus: current,
      profile: profile,
      project: project,
      goal: goal,
      capture: captured,
      sources: sources_by_logical_id,
      input: %{
        "corpus_id" => corpus["id"],
        "project_id" => project["id"],
        "goal_id" => goal["id"],
        "goal_hash" => Goals.content_hash(goal_record),
        "expected_generation" => current.semantic_generation,
        "mode" => "fts"
      },
      frozen_goal_payload_hash: Contracts.digest(goal())
    }
  end
end
