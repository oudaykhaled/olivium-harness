defmodule HarnessForge.Company.SetupSessions do
  @moduledoc "Versioned workspace-local operator setup drafts; navigation grants no domain authority."
  import Ecto.Query
  alias HarnessForge.{Audit, Contracts, Goals, Repo, Workspaces}

  alias HarnessForge.Company.{
    AssessmentAttempts,
    CorpusReview,
    Profile,
    Project,
    Repository,
    SetupSession,
    SetupRuns
  }

  alias HarnessForge.Evidence.{Corpora, Corpus, Goal, Requirements, Store}
  alias HarnessForge.Privacy.Purge

  @steps ~w(outcome scope understanding review candidate evaluation release)
  @selection ~w(profile project repository goal corpus_id declaration)
  @catalog ~w(profile project repository goal)
  @scope_keys ~w(workspace_id corpus_id semantic_generation authorization_generation profile_id profile_hash project_id project_hash goal_id goal_hash)
  @expected_keys ~w(semantic_generation authorization_generation profile_hash project_hash goal_hash revision)
  @focus %{
    "profile" => "setup-profile",
    "project" => "setup-project",
    "repository" => "setup-repository",
    "goal" => "setup-goal",
    "corpus_id" => "setup-corpus",
    "declaration" => "setup-declaration"
  }

  def create(attrs, caller) do
    fenced(caller, fn workspace, owner ->
      with :ok <- exact(attrs, []),
           {:ok, record} <-
             transaction(caller, workspace, fn ->
               with {:ok, record} <-
                      Repo.insert(%SetupSession{
                        workspace_id: workspace,
                        owner: owner,
                        payload: %{
                          "selection" => empty_selection(),
                          "draft" => %{},
                          "scope_pin" => nil,
                          "operation_refs" => [],
                          "decision_refs" => []
                        }
                      }),
                    {:ok, _} <-
                      Audit.append("company.setup_created", %{
                        "setup_session_id" => record.id,
                        "version" => record.lock_version
                      }) do
                 {:ok, record}
               end
             end) do
        present(record, caller)
      end
    end)
  end

  def get(attrs, caller) do
    fenced(caller, fn workspace, owner ->
      with :ok <- exact(attrs, ["id"]),
           :ok <- valid_id(attrs["id"]),
           {:ok, record} <-
             transaction(caller, workspace, fn -> owned(attrs["id"], workspace, owner) end) do
        present(record, caller)
      end
    end)
  end

  def list(attrs, caller) do
    fenced(caller, fn workspace, owner ->
      with :ok <- exact(attrs, []),
           {:ok, rows} <-
             transaction(caller, workspace, fn ->
               rows =
                 Repo.all(
                   from s in SetupSession,
                     where: s.workspace_id == ^workspace and s.owner == ^owner,
                     order_by: [desc: s.updated_at, desc: s.id],
                     limit: 20,
                     select: {s.id, s.lock_version, s.step, s.updated_at}
                 )

               {:ok,
                Enum.map(rows, fn {id, version, step, updated} ->
                  %{
                    "id" => id,
                    "version" => version,
                    "step" => step,
                    "updated_at" => timestamp(updated)
                  }
                end)}
             end) do
        {:ok, rows}
      end
    end)
  end

  def command(envelope, caller) do
    result =
      fenced(caller, fn workspace, owner ->
        with :ok <- envelope(envelope),
             {:ok, record} <-
               transaction(caller, workspace, fn -> owned(envelope["id"], workspace, owner) end),
             :ok <- check(record.lock_version == envelope["expected_version"], "conflict"),
             {:ok, _} <- stored_payload(record),
             {:ok, observation} <- observe(record.payload, caller),
             {:ok, next} <- apply_command(record, envelope, observation, caller),
             {:ok, saved} <-
               transaction(caller, workspace, fn ->
                 save(record, next, envelope["command"], workspace, owner)
               end) do
          # Expected stale reference results must never be caught inside a successful
          # outer DB transaction: the reused APIs roll back their own transactions.
          # Observe before CAS and after commit under the same privacy fence instead.
          present(saved, caller)
        end
      end)

    case result do
      {:error, %{"code" => "conflict"} = failure} ->
        case get(%{"id" => envelope["id"]}, caller) do
          {:ok, current} -> {:error, Map.put(failure, "current", current)}
          error -> error
        end

      other ->
        other
    end
  end

  defp fenced(caller, fun) do
    workspace = Store.workspace()
    owner = Workspaces.operator()

    with :ok <- authorized(caller, workspace) do
      Purge.synchronize(fn ->
        with :ok <- authorized(caller, workspace),
             :ok <- ready(),
             {:ok, result} <- fun.(workspace, owner),
             :ok <- authorized(caller, workspace),
             :ok <- ready() do
          {:ok, result}
        else
          {:error, %{"code" => _}} = error -> error
          _ -> error("unavailable")
        end
      end)
    end
  rescue
    _ -> error("unavailable")
  catch
    :throw, {:setup_error, code} -> error(code)
    _, _ -> error("unavailable")
  end

  defp authorized(caller, workspace) do
    with :ok <- AssessmentAttempts.options(caller),
         :ok <- AssessmentAttempts.authorize(caller),
         true <- Store.workspace() == workspace do
      :ok
    else
      _ -> error("unauthorized")
    end
  end

  defp ready do
    case Purge.ready() do
      :ok -> :ok
      _ -> error("unavailable")
    end
  end

  defp transaction(caller, workspace, fun) do
    Store.transaction(fn ->
      with :ok <- authorized(caller, workspace),
           :ok <- ready(),
           {:ok, result} <- fun.(),
           :ok <- authorized(caller, workspace),
           :ok <- ready() do
        {:ok, result}
      else
        {:error, %{"code" => _}} = error -> error
        _ -> error("unavailable")
      end
    end)
  end

  defp owned(id, workspace, owner) do
    case Repo.one(
           from s in SetupSession,
             where: s.workspace_id == ^workspace and s.owner == ^owner and s.id == ^id
         ) do
      nil -> error("not_found")
      record -> {:ok, record}
    end
  end

  defp envelope(value) do
    with :ok <- exact(value, ~w(id expected_version command payload)),
         :ok <- valid_id(value["id"]),
         :ok <-
           check(
             is_integer(value["expected_version"]) and value["expected_version"] > 0,
             "invalid_input"
           ),
         :ok <- check(value["command"] in ~w(save change back continue), "invalid_input") do
      case value["command"] do
        "save" ->
          with :ok <- exact(value["payload"], ["draft"]),
               do: valid_draft(value["payload"]["draft"])

        "change" ->
          with :ok <- exact(value["payload"], ["selection"]),
               do: valid_selection(value["payload"]["selection"])

        _ ->
          exact(value["payload"], [])
      end
    end
  end

  defp apply_command(record, %{"command" => "save", "payload" => %{"draft" => draft}}, _, _) do
    payload = Map.update!(record.payload, "draft", &Map.merge(&1, draft))
    {:ok, %{record | payload: payload}}
  end

  defp apply_command(
         record,
         %{"command" => "change", "payload" => %{"selection" => input}},
         _,
         caller
       ) do
    selection = Map.merge(empty_selection(), input)

    payload = %{
      record.payload
      | "selection" => selection,
        "scope_pin" => nil,
        "operation_refs" => [],
        "decision_refs" => []
    }

    with {:ok, pin} <- new_scope_pin(selection, caller),
         payload = Map.put(payload, "scope_pin", pin),
         {:ok, observation} <- observe(payload, caller),
         :ok <- changed_references(observation) do
      {:ok, %{record | payload: payload}}
    end
  end

  defp apply_command(record, %{"command" => "back"}, _, _) do
    index = Enum.find_index(@steps, &(&1 == record.step))
    {:ok, %{record | step: Enum.at(@steps, max(index - 1, 0))}}
  end

  defp apply_command(
         %{schema_version: 2, step: "scope"} = record,
         %{"command" => "continue"},
         _,
         caller
       ) do
    with {:ok, _} <- SetupRuns.scope_authorized(record.id, caller),
         do: {:ok, %{record | step: "understanding"}}
  end

  defp apply_command(record, %{"command" => "continue"}, observation, _) do
    required = if record.step == "outcome", do: @catalog, else: @selection

    cond do
      record.step not in ~w(outcome scope) ->
        error("capability_unavailable")

      Enum.any?(required, &(observation["fields"][&1] != "current")) ->
        fields =
          Map.take(observation["fields"], required)
          |> Enum.reject(fn {_, state} -> state == "current" end)
          |> Map.new()

        error("stale_reference", fields)

      true ->
        {:ok, %{record | step: if(record.step == "outcome", do: "scope", else: "understanding")}}
    end
  end

  defp save(previous, next, command, workspace, owner) do
    with :ok <-
           check(byte_size(Contracts.canonical_json(next.payload)) <= 16_384, "invalid_input"),
         :ok <- invalidate_run(previous, next, command),
         {:ok, %{num_rows: count}} <-
           Repo.query(
             "UPDATE setup_sessions SET step=?,payload=?,lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND owner=? AND id=? AND lock_version=? AND schema_version=?",
             [
               next.step,
               Contracts.canonical_json(next.payload),
               Corpora.now(),
               workspace,
               owner,
               previous.id,
               previous.lock_version,
               previous.schema_version
             ],
             log: false
           ),
         :ok <- check(count == 1, "conflict"),
         {:ok, record} <- owned(previous.id, workspace, owner),
         {:ok, _} <-
           Audit.append("company.setup_changed", %{
             "setup_session_id" => record.id,
             "version" => record.lock_version,
             "command" => command
           }) do
      {:ok, record}
    else
      {:error, %{"code" => _}} = error -> error
      _ -> error("unavailable")
    end
  end

  defp invalidate_run(%{schema_version: 2} = previous, next, command) do
    if command == "change" or
         previous.payload["draft"]["outcome_note"] != next.payload["draft"]["outcome_note"],
       do: SetupRuns.invalidate_session(previous.id),
       else: :ok
  end

  defp invalidate_run(_, _, _), do: :ok

  defp present(record, caller) do
    with {:ok, _} <- stored_payload(record),
         {:ok, observation} <- observe(record.payload, caller) do
      selection =
        Map.new(record.payload["selection"], fn {key, value} ->
          {key, if(observation["fields"][key] == "unavailable", do: nil, else: value)}
        end)

      {:ok,
       %{
         "id" => record.id,
         "version" => record.lock_version,
         "step" => record.step,
         "selection" => selection,
         "draft" => record.payload["draft"],
         "steps" =>
           Enum.map(@steps, fn step ->
             %{
               "code" => step,
               "label" => String.capitalize(step),
               "state" =>
                 if(step in ~w(outcome scope), do: "editable", else: "capability_unavailable"),
               "reason" =>
                 if(step in ~w(outcome scope),
                   do: "implemented_step",
                   else: "capability_unavailable"
                 )
             }
           end),
         "next_action" => setup_next_action(record, selection, observation, caller),
         "reference_status" => observation,
         "updated_at" => timestamp(record.updated_at)
       }}
    end
  end

  defp setup_next_action(
         %{schema_version: 2, step: "scope"} = record,
         selection,
         observation,
         caller
       ) do
    case SetupRuns.scope_authorized(record.id, caller) do
      {:ok, _} ->
        %{
          "code" => "continue",
          "reason" => "saved_scope_ready",
          "bound_ids" => %{},
          "focus" => "setup-continue"
        }

      _ ->
        next_action(record.step, selection, observation)
        |> Map.merge(%{
          "code" => "select_scope",
          "reason" => "run_authorization_required",
          "focus" => "setup-analysis"
        })
    end
  end

  defp setup_next_action(record, selection, observation, _),
    do: next_action(record.step, selection, observation)

  defp observe(payload, caller) do
    selection = payload["selection"]
    catalog = Map.new(@catalog, &{&1, catalog_reference(&1, selection[&1], caller)})
    states = Map.new(catalog, fn {key, {state, _}} -> {key, state} end)
    states = relationships(states, catalog, selection)

    with {:ok, corpus_state} <- corpus_reference(selection, payload["scope_pin"], states, caller),
         {:ok, declaration_state} <-
           declaration_reference(selection, payload["scope_pin"], corpus_state, caller) do
      fields =
        Map.merge(states, %{
          "corpus_id" => corpus_state,
          "declaration" => declaration_state,
          "measurement" => "unknown"
        })

      status =
        cond do
          Enum.any?(fields, fn {key, state} -> key != "measurement" and state == "unavailable" end) ->
            "unavailable"

          Enum.any?(fields, fn {key, state} -> key != "measurement" and state == "stale" end) ->
            "stale"

          Enum.all?(@selection, &(fields[&1] == "current")) ->
            "current"

          true ->
            "needs_input"
        end

      {:ok, %{"status" => status, "fields" => fields}}
    end
  end

  defp catalog_reference(_, nil, _), do: {"missing", nil}

  defp catalog_reference(kind, pin, caller) do
    schema =
      case kind do
        "profile" -> Profile
        "project" -> Project
        "repository" -> Repository
        "goal" -> Goal
      end

    case Store.get(schema, pin["id"]) do
      {:ok, record} ->
        hash = if kind == "goal", do: Goals.content_hash(record), else: record.content_hash

        cond do
          kind != "goal" and Contracts.digest(record.payload) != hash ->
            {"unavailable", nil}

          kind in ~w(profile project) and not source_access?(record.payload, caller) ->
            {"unavailable", nil}

          hash != pin["content_hash"] ->
            {"stale", record}

          true ->
            {"current", record}
        end

      _ ->
        {"unavailable", nil}
    end
  end

  defp source_access?(payload, caller) do
    ids = payload["source_ids"] || []

    case CorpusReview.summary_refs(%{"profile_ids" => ids}, caller) do
      {:ok, %{"unavailable_ids" => []}} -> true
      {:ok, _} -> false
      {:error, :operator_session_revoked} -> throw({:setup_error, "unauthorized"})
      _ -> throw(:source_observation_unavailable)
    end
  end

  defp relationships(states, catalog, selection) do
    project = elem(catalog["project"], 1)
    profile = elem(catalog["profile"], 1)

    states =
      if project && selection["repository"] &&
           selection["repository"]["id"] not in project.payload["repository_ids"],
         do: Map.put(states, "repository", "stale"),
         else: states

    assigned =
      if(profile, do: profile.payload["goal_ids"], else: []) ++
        if project, do: project.payload["goal_ids"], else: []

    if selection["goal"] && (profile || project) && selection["goal"]["id"] not in assigned,
      do: Map.put(states, "goal", "stale"),
      else: states
  end

  defp new_scope_pin(selection, caller) do
    with true <-
           not is_nil(selection["corpus_id"]) and
             Enum.all?(~w(profile project goal), &(not is_nil(selection[&1]))),
         {:ok, pin} <-
           Requirements.context(
             selection["corpus_id"],
             selection["project"]["id"],
             selection["goal"]["id"],
             selection["goal"]["content_hash"],
             caller
           ) do
      if pin["scope"]["profile_id"] == selection["profile"]["id"] and
           pin["scope"]["profile_hash"] == selection["profile"]["content_hash"] and
           pin["scope"]["project_hash"] == selection["project"]["content_hash"],
         do: {:ok, pin},
         else: error("stale_reference", %{"corpus_id" => "stale"})
    else
      false ->
        {:ok, nil}

      {:error, reason} when reason in [:operator_session_revoked, :invalid_input] ->
        error("unauthorized")

      {:error, reason}
      when reason in [:privacy_operation_incomplete, :privacy_state_unavailable] ->
        error("unavailable")

      _ ->
        error("stale_reference", %{"corpus_id" => "stale"})
    end
  end

  defp corpus_reference(%{"corpus_id" => nil}, _, _, _), do: {:ok, "missing"}

  defp corpus_reference(selection, pin, states, caller) do
    case Store.get(Corpus, selection["corpus_id"]) do
      {:ok, %{state: "active"}} ->
        cond do
          Enum.any?(~w(profile project goal), &(states[&1] == "unavailable")) ->
            {:ok, "unavailable"}

          Enum.any?(~w(profile project goal), &(states[&1] == "stale")) ->
            {:ok, "stale"}

          not Enum.all?(~w(profile project goal), &(states[&1] == "current")) ->
            {:ok, "missing"}

          is_nil(pin) ->
            {:ok, "missing"}

          true ->
            case new_scope_pin(selection, caller) do
              {:ok, ^pin} -> {:ok, "current"}
              {:ok, _} -> {:ok, "stale"}
              {:error, %{"code" => "stale_reference"}} -> {:ok, "stale"}
              error -> error
            end
        end

      _ ->
        {:ok, "unavailable"}
    end
  end

  defp declaration_reference(%{"declaration" => nil}, _, _, _), do: {:ok, "missing"}

  defp declaration_reference(_, _, state, _) when state != "current",
    do: {:ok, if(state == "unavailable", do: "unavailable", else: "stale")}

  defp declaration_reference(selection, pin, _, caller) do
    ref = selection["declaration"]

    case Requirements.summary(ref["id"], ref["digest"], caller) do
      {:ok, summary} ->
        {:ok, if(summary["scope"] == pin["scope"], do: "current", else: "stale")}

      {:error, reason} when reason in [:operator_session_revoked, :invalid_input] ->
        error("unauthorized")

      {:error, reason}
      when reason in [:privacy_operation_incomplete, :privacy_state_unavailable] ->
        error("unavailable")

      {:error, :not_found} ->
        {:ok, "unavailable"}

      _ ->
        {:ok, "stale"}
    end
  end

  defp changed_references(observation) do
    invalid =
      Map.take(observation["fields"], @selection)
      |> Enum.filter(fn {_, state} -> state in ~w(stale unavailable) end)
      |> Map.new()

    if invalid == %{}, do: :ok, else: error("stale_reference", invalid)
  end

  defp next_action(step, selection, observation) do
    required = if step == "outcome", do: @catalog, else: @selection
    field = Enum.find(required, &(observation["fields"][&1] != "current"))

    {code, reason, focus} =
      cond do
        step not in ~w(outcome scope) ->
          {"capability_unavailable", "later_step_unavailable", "setup-back"}

        field && observation["fields"][field] in ~w(stale unavailable) ->
          {"repair_selection",
           if(observation["fields"][field] == "unavailable",
             do: "reference_unavailable",
             else: "stale_reference"
           ), @focus[field]}

        field ->
          {if(step == "outcome", do: "select_outcome", else: "select_scope"),
           if(step == "outcome",
             do: "outcome_references_required",
             else: "scope_references_required"
           ), @focus[field]}

        true ->
          {"continue",
           if(step == "outcome", do: "saved_outcome_ready", else: "saved_scope_ready"),
           "setup-continue"}
      end

    ids =
      Map.new(Enum.filter(selection, fn {_, value} -> not is_nil(value) end), fn {key, value} ->
        {key, if(is_map(value), do: value["id"], else: value)}
      end)

    %{"code" => code, "reason" => reason, "bound_ids" => ids, "focus" => focus}
  end

  defp stored_payload(record) do
    with :ok <-
           check(
             record.schema_version in [1, 2] and record.step in @steps and
               is_integer(record.lock_version) and record.lock_version > 0,
             "unavailable"
           ),
         :ok <-
           exact(
             record.payload,
             ~w(selection draft scope_pin operation_refs decision_refs) ++
               if(record.schema_version == 2, do: ["refs"], else: [])
           ),
         :ok <- valid_run_refs(record),
         :ok <- exact(record.payload["selection"], @selection),
         :ok <- valid_selection(record.payload["selection"]),
         :ok <- valid_draft(record.payload["draft"]),
         :ok <-
           check(
             record.payload["operation_refs"] == [] and record.payload["decision_refs"] == [] and
               valid_scope_pin?(record.payload["scope_pin"]) and
               byte_size(Contracts.canonical_json(record.payload)) <= 16_384,
             "unavailable"
           ) do
      {:ok, record.payload}
    else
      _ -> error("unavailable")
    end
  end

  defp valid_run_refs(%{schema_version: 1}), do: :ok

  defp valid_run_refs(record) do
    refs = record.payload["refs"]
    ref = if is_map(refs), do: refs["run_ref"]

    check(
      exact(refs, ["run_ref"]) == :ok and
        (is_nil(ref) or
           (exact(ref, ~w(id digest)) == :ok and Corpora.uuid?(ref["id"]) and
              Corpora.digest?(ref["digest"]))),
      "unavailable"
    )
  end

  defp valid_selection(value) do
    valid =
      Corpora.keys(value, [], @selection) == :ok and
        Enum.all?(value, fn
          {key, pin} when key in @catalog ->
            is_nil(pin) or
              (exact(pin, ~w(id content_hash)) == :ok and Corpora.uuid?(pin["id"]) and
                 Corpora.digest?(pin["content_hash"]))

          {"corpus_id", id} ->
            is_nil(id) or Corpora.uuid?(id)

          {"declaration", pin} ->
            is_nil(pin) or
              (exact(pin, ~w(id digest)) == :ok and Corpora.uuid?(pin["id"]) and
                 Corpora.digest?(pin["digest"]))
        end)

    check(valid, "invalid_input")
  end

  defp valid_draft(value) do
    valid =
      Corpora.keys(value, [], ~w(outcome_note scope_note)) == :ok and
        Enum.all?(value, fn {_, text} ->
          is_binary(text) and String.valid?(text) and byte_size(text) <= 2048
        end)

    check(valid, "invalid_input")
  end

  defp valid_scope_pin?(nil), do: true

  defp valid_scope_pin?(pin) do
    exact(pin, ~w(scope expected)) == :ok and exact(pin["scope"], @scope_keys) == :ok and
      exact(pin["expected"], @expected_keys) == :ok and
      is_binary(pin["scope"]["workspace_id"]) and String.valid?(pin["scope"]["workspace_id"]) and
      byte_size(pin["scope"]["workspace_id"]) in 1..256 and
      Enum.all?(~w(corpus_id profile_id project_id goal_id), &Corpora.uuid?(pin["scope"][&1])) and
      Enum.all?(~w(profile_hash project_hash goal_hash), &Corpora.digest?(pin["scope"][&1])) and
      Enum.all?(
        ~w(semantic_generation authorization_generation),
        &(is_integer(pin["scope"][&1]) and pin["scope"][&1] >= 0)
      ) and
      is_integer(pin["expected"]["revision"]) and pin["expected"]["revision"] >= 0 and
      Map.drop(pin["expected"], ["revision"]) ==
        Map.take(pin["scope"], @expected_keys -- ["revision"])
  end

  defp empty_selection, do: Map.new(@selection, &{&1, nil})
  defp valid_id(id), do: check(Corpora.uuid?(id), "invalid_input")
  defp exact(value, keys), do: check(Corpora.keys(value, keys) == :ok, "invalid_input")
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(_), do: "unknown"
  defp check(true, _), do: :ok
  defp check(_, code), do: error(code)
  defp error(code, fields \\ %{}), do: {:error, %{"code" => code, "fields" => fields}}
end
