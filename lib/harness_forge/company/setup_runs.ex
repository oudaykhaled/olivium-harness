defmodule HarnessForge.Company.SetupRuns do
  @moduledoc "Explicit saved-setup runs with immutable intent, dual CAS and replay-safe work admission."
  import Ecto.Query
  alias HarnessForge.{Contracts, Goals, Repo, Workspaces}

  alias HarnessForge.Company.{
    AssessmentAttempts,
    SetupSession,
    SetupRunConfig,
    SetupRun,
    SetupRunState,
    SetupRunCommand,
    SetupRunOperation,
    SetupRunPreparation,
    Profile,
    Project,
    Repository,
    Retrieval
  }

  alias HarnessForge.Evidence.{Capture, Connection, Corpora, Goal, Requirements, Store}
  alias HarnessForge.Models.{RunAuthorization, RunAuthorizationRecord, StageAuthority}
  alias HarnessForge.Privacy.Purge

  @actions ~w(prepare acquire retrieve authorize analyze retry cancel new_run)
  @errors ~w(invalid_input unauthorized not_found conflict command_conflict phase_conflict stale_preparation stale_scope consent_required authorization_required authorization_expired run_replacement_required model_unavailable unsupported_configuration acquisition_incomplete acquisition_outcome_unknown budget_exhausted request_outcome_unknown cancelled unavailable)
  @capture_limits %{
    "max_files" => 500,
    "max_body_bytes" => 16_777_216,
    "max_file_bytes" => 1_048_576,
    "max_admitted_entries" => 10_000,
    "deadline_seconds" => 600
  }
  @model_limits %{
    "max_requests" => 2,
    "max_tokens" => 100_000,
    "max_cost_microusd" => 0,
    "deadline_seconds" => 300
  }
  @operation_fields ~w(id workspace_id owner_id session_id run_id config_id command_id operation_id kind preparation_id authorization_id expected_run_version generations_json)

  @doc false
  def restore_digest("config", %SetupRunConfig{} = record),
    do: Contracts.digest(record.scope_json)

  def restore_digest("run", %SetupRun{} = record),
    do: digest_fields(record, ~w(id workspace_id owner_id session_id config_id predecessor_id))

  def restore_digest("operation", %SetupRunOperation{} = record),
    do: digest_fields(record, @operation_fields)

  # The complete fence returns before any retrieval or provider work begins.
  # A matching receipt returns before observations and never re-executes work.
  def command(envelope, caller), do: command(envelope, caller, nil)

  def command(envelope, caller, context) do
    with :ok <- authenticate(caller),
         :ok <- source_context_matches(context, caller),
         :ok <- check(not Repo.in_transaction?(), "unavailable"),
         :ok <- validate_command(envelope),
         {:ok, replay} <- guarded(caller, fn -> replay(envelope) end) do
      if replay do
        {:ok, replay}
      else
        with {:ok, observation} <- observe_command(envelope, caller, context),
             {:ok, accepted} <- guarded(caller, fn -> accept(envelope, observation, caller, context) end) do
          case accepted do
            {:replayed, receipt} ->
              {:ok, receipt}

            {:fresh, receipt} ->
              safely_execute(receipt, caller, context)
              {:ok, receipt}
          end
        end
      end
    else
      failure -> normalize(failure)
    end
  end

  defp safely_execute(receipt, caller, context) do
    execute_fresh(receipt, caller, context)
  rescue
    _ -> settle_failure(receipt, error("request_outcome_unknown"), caller)
  catch
    _, _ -> settle_failure(receipt, error("request_outcome_unknown"), caller)
  end

  def get(id, caller), do: get(id, caller, nil)

  def get(id, caller, context) do
    guarded(caller, fn ->
      with :ok <- source_context_matches(context, caller),
           :ok <- check(Corpora.uuid?(id), "invalid_input"),
           {:ok, session} <- session(id),
           {:ok, current} <- current(session),
           {:ok, history} <- history_page(session, nil, caller),
           {:ok, view} <- run_view(current, caller, context) do
        {:ok,
         %{
           "version" => 1,
           "id" => id,
           "session_version" => session.lock_version,
           "run" => view,
           "predecessor_usage" => history["predecessor_usage"],
           "history_cursor" => history["history_cursor"],
           "available_actions" => actions(view)
         }}
      end
    end)
  end

  def history(id, cursor, caller) do
    guarded(caller, fn ->
      with :ok <- check(Corpora.uuid?(id), "invalid_input"),
           {:ok, session} <- session(id),
           {:ok, page} <- history_page(session, cursor, caller),
           do: {:ok, Map.merge(%{"version" => 1, "id" => id}, page)}
    end)
  end

  @doc false
  # Joins an existing Purge→SQL transaction. No physical observations or dispatch.
  def operation_binding(id, caller) do
    guarded(caller, fn ->
      with :ok <- check(Corpora.uuid?(id), "invalid_input"),
           {:ok, operation} <- operation(id),
           :ok <-
             check(operation.digest == digest_fields(operation, @operation_fields), "unavailable"),
           {:ok, session} <- session(operation.session_id),
           {:ok, {run, state, config}} <- current(session),
           :ok <-
             check(run.id == operation.run_id and config.id == operation.config_id, "stale_scope"),
           :ok <- live_state(state),
           :ok <- config_current(config, session),
           :ok <- operation_current(operation, state),
           {:ok, command} <- command_row(operation.command_id, session.id),
           {:ok, preparation} <- preparation_reference(operation.preparation_id),
           {:ok, authorization} <- optional(RunAuthorizationRecord, operation.authorization_id) do
        {:ok,
         %{
           "operation_ref" => ref(operation),
           "kind" => operation.kind,
           "command_ref" => %{"id" => command.id, "digest" => command.request_digest},
           "run_ref" => ref(run),
           "config_ref" => ref(config),
           "prepared_ref" => nullable_ref(preparation),
           "authorization_ref" => nullable_ref(authorization),
           "expected_run_version" => operation.expected_run_version,
           "generations" => operation.generations_json
         }}
      end
    end)
  end

  @doc false
  def publish_operation(operation_ref, expected_version, result_ref, caller), do: publish_operation(operation_ref, expected_version, result_ref, caller, nil)

  def publish_operation(operation_ref, expected_version, result_ref, caller, context) do
    guarded(caller, fn ->
      with :ok <- source_context_matches(context, caller),
           :ok <-
             check(
               valid_ref?(operation_ref) and valid_ref?(result_ref) and
                 is_integer(expected_version),
               "invalid_input"
             ),
           {:ok, op} <- operation(operation_ref["id"]),
           :ok <- check(ref(op) == operation_ref, "not_found"),
           {:ok, session} <- session(op.session_id),
           {:ok, {run, state, config}} <- current(session),
           :ok <- check(run.id == op.run_id and config.id == op.config_id, "stale_scope"),
           :ok <- live_state(state),
           :ok <- config_current(config, session),
           {:ok, changes} <- publication(op, result_ref, caller, context),
           :ok <- check(op.expected_run_version == expected_version, "conflict") do
        if published?(state, changes) and state.lock_version == expected_version + 1 do
          run_view({run, state, config}, caller, context)
        else
          with :ok <- check(state.lock_version == expected_version, "conflict"),
               {:ok, saved} <-
                 update_state(state, Map.put(changes, :lock_version, state.lock_version + 1)),
               do: run_view({run, saved, config}, caller, context)
        end
      end
    end)
  end

  @doc false
  def invalidate_session(id) do
    # Called by SetupSessions inside its acknowledged selection/draft CAS.
    with true <- Repo.in_transaction?(),
         {:ok, session} <- session(id),
         {:ok, current} <- current(session) do
      case current do
        nil ->
          :ok

        {run, state, _} ->
          with {:ok, _} <-
                 update_state(state, %{
                   phase: "cancelled",
                   failure_code: "stale_scope",
                   lock_version: state.lock_version + 1
                 }) do
            revoke_run(run.id, "stale_scope")
            :ok
          end
      end
    else
      _ -> error("unavailable")
    end
  end

  @doc false
  def scope_authorized(id, caller), do: scope_authorized(id, caller, nil)

  def scope_authorized(id, caller, context) do
    guarded(caller, fn ->
      with :ok <- source_context_matches(context, caller),
           {:ok, session} <- session(id),
           {:ok, {run, state, config}} <- current(session),
           :ok <- check(state.phase in ~w(ready running completed), "authorization_required"),
           :ok <- config_current(config, session),
           {:ok, _} <- RunAuthorization.ready_for_run(ref(run), caller, context),
           do: {:ok, ref(run)}
    end)
  end

  defp observe_command(%{"action" => action} = env, caller, _context)
       when action in ~w(prepare new_run acquire) do
    with {:ok, session} <- guarded(caller, fn -> session(env["id"]) end),
         {:ok, current} <- guarded(caller, fn -> current(session) end),
         connection <-
           if(action == "prepare",
             do: env["payload"]["connection_id"],
             else: current_connection(current)
           ),
         :ok <- check(Corpora.uuid?(connection), "phase_conflict"),
         {:ok, physical} <- Capture.preflight_for_setup(session.id, connection, caller),
         {:ok, descriptor} <- RunAuthorization.descriptor(),
         {:ok, proposal} <- proposal(session, connection, physical, descriptor) do
      {:ok, %{"physical" => physical, "proposal" => proposal}}
    else
      failure -> normalize(failure)
    end
  end

  defp observe_command(%{"action" => "retrieve"} = env, caller, context) do
    with {:ok, view} <- get(env["id"], caller, context),
         run when is_map(run) <- view["run"],
         {:ok, status} <- Capture.setup_status(run["capture_ref"], caller),
         :ok <-
           check(
             status["scan_complete"] == true and status["index_ready"] == true and
               status["incomplete"] == false,
             "acquisition_incomplete"
           ),
         do: {:ok, %{"capture_status" => status}},
         else: (failure -> normalize(failure, "acquisition_incomplete"))
  end

  defp observe_command(_, _, _), do: {:ok, %{}}

  defp accept(env, observation, caller, context) do
    with {:ok, session} <- session(env["id"]), {:ok, replay} <- replay(env) do
      if replay do
        {:ok, {:replayed, replay}}
      else
        with {:ok, current} <- current(session),
             :ok <- versions(env, session, current),
             {:ok, receipt} <- accept_action(env, session, current, observation, caller, context),
             do: {:ok, {:fresh, receipt}}
      end
    end
  end

  defp accept_action(%{"action" => "prepare"} = env, session, nil, observation, _, _context) do
    create_run(env, session, nil, observation["proposal"])
  end

  defp accept_action(
         %{"action" => "prepare"} = env,
         session,
         {run, state, config},
         observation,
         _,
         _context
       ) do
    with :ok <- live_state(state),
         :ok <- check(config.scope_json == observation["proposal"], "stale_scope"),
         do: store_command(env, session, run, state, nil)
  end

  defp accept_action(%{"action" => "new_run"} = env, session, {run, state, _}, observation, _, _context) do
    with :ok <- check(env["payload"]["predecessor_run_ref"] == ref(run), "stale_scope"),
         :ok <- check(effective_phase(state) in ~w(cancelled expired), "phase_conflict"),
         do: create_run(env, session, run, observation["proposal"])
  end

  defp accept_action(env, session, {run, state, config}, observation, caller, context) do
    action = env["action"]

    with :ok <- check(action != "new_run", "phase_conflict"),
         :ok <- if(action == "cancel", do: :ok, else: live_state(state)),
         :ok <- if(action == "cancel", do: :ok, else: config_current(config, session)),
         {:ok, changes, kind} <- action_changes(action, env, state, config, observation, caller, context),
         {:ok, next_session} <- advance_session(session, ref(run)),
         next_version = state.lock_version + 1,
         {:ok, op} <- register(kind, env, run, state, config, next_version),
         changes =
           changes
           |> Map.put(:lock_version, next_version)
           |> Map.put(:last_command_id, env["command_id"]),
         {:ok, next_state} <- update_state(state, changes),
         {:ok, receipt} <- store_command(env, next_session, run, next_state, op),
         {:ok, _} <- accepted_effect(action, config, next_state, receipt, caller, context) do
      {:ok, receipt}
    end
  end

  defp accept_action(_, _, _, _, _, _), do: error("phase_conflict")

  defp create_run(env, session, predecessor, proposal) do
    run_id = Ecto.UUID.generate()
    config_id = Ecto.UUID.generate()
    config_digest = Contracts.digest(proposal)

    existing =
      Repo.one(
        from c in SetupRunConfig,
          where:
            c.workspace_id == ^Store.workspace() and c.owner_id == ^Workspaces.operator() and
              c.session_id == ^session.id and c.digest == ^config_digest
      )

    config_id = if existing, do: existing.id, else: config_id

    run = %SetupRun{
      id: run_id,
      workspace_id: Store.workspace(),
      owner_id: Workspaces.operator(),
      session_id: session.id,
      config_id: config_id,
      predecessor_id: if(predecessor, do: predecessor.id)
    }

    run = %{
      run
      | digest:
          digest_fields(run, ~w(id workspace_id owner_id session_id config_id predecessor_id))
    }

    with :ok <- retire_predecessor(predecessor),
         {:ok, session} <- advance_session(session, ref(run), true),
         {:ok, _} <-
           if(existing,
             do: {:ok, existing},
             else:
               Repo.insert(%SetupRunConfig{
                 id: config_id,
                 workspace_id: Store.workspace(),
                 owner_id: Workspaces.operator(),
                 session_id: session.id,
                 digest: config_digest,
                 scope_json: proposal
               })
           ),
         {:ok, run} <- Repo.insert(run),
         {:ok, state} <-
           Repo.insert(%SetupRunState{
             workspace_id: Store.workspace(),
             owner_id: Workspaces.operator(),
             session_id: session.id,
             run_id: run.id,
             phase: "proposed",
             last_command_id: env["command_id"]
           }),
         do: store_command(env, session, run, state, nil)
  end

  defp retire_predecessor(nil), do: :ok

  defp retire_predecessor(run) do
    state =
      Repo.one!(
        from s in SetupRunState,
          where:
            s.workspace_id == ^Store.workspace() and s.owner_id == ^Workspaces.operator() and
              s.run_id == ^run.id
      )

    with {:ok, _} <-
           update_state(state, %{
             phase: effective_phase(state),
             lock_version: state.lock_version + 1
           }) do
      revoke_run(run.id, "cancelled")
      :ok
    end
  end

  defp action_changes("acquire", _, state, config, observation, _, _context) do
    with :ok <-
           check(
             state.phase == "proposed" and is_nil(state.capture_id),
             "run_replacement_required"
           ),
         :ok <- check(config.scope_json == observation["proposal"], "stale_scope"),
         do: {:ok, %{phase: "acquiring", failure_code: nil}, "capture"}
  end

  defp action_changes("retrieve", _, state, _, _, _, _context) do
    with :ok <-
           check(
             state.phase in ~w(acquiring captured) and is_nil(state.retrieval_id) and
               is_nil(state.preparation_id),
             "run_replacement_required"
           ),
         :ok <-
           check(
             not Repo.exists?(
               from o in SetupRunOperation,
                 where:
                   o.workspace_id == ^Store.workspace() and o.run_id == ^state.run_id and
                     o.kind == "retrieval"
             ),
             "run_replacement_required"
           ),
         do: {:ok, %{phase: "retrieving", failure_code: nil}, "retrieval"}
  end

  defp action_changes("authorize", env, state, _, _, caller, context) do
    with :ok <- check(state.phase in ~w(needs_input ready), "phase_conflict"),
         {:ok, preparation} <- preparation_reference(state.preparation_id),
         :ok <- check(ref(preparation) == env["payload"]["prepared_ref"], "stale_preparation"),
         {:ok, _} <- RunAuthorization.prepared_view(ref(preparation), caller, context),
         do: {:ok, %{phase: "needs_input", failure_code: nil}, nil}
  end

  defp action_changes(action, env, state, _, _, caller, context) when action in ~w(analyze retry) do
    with :ok <-
           check(
             (action == "analyze" and state.phase == "ready") or
               (action == "retry" and state.phase in ~w(blocked completed)),
             "phase_conflict"
           ),
         {:ok, prep} <- preparation_reference(state.preparation_id),
         :ok <- check(ref(prep) == env["payload"]["prepared_ref"], "stale_preparation"),
         {:ok, run} <- owned(SetupRun, state.run_id),
         {:ok, _} <- RunAuthorization.ready_for_run(ref(run), caller, context),
         {:ok, usage} <- RunAuthorization.usage(ref(run), caller),
         :ok <-
           check(
             usage["pending_requests"] == 0 and usage["uncertain_requests"] == 0,
             "request_outcome_unknown"
           ),
         :ok <-
           check(
             usage["remaining_requests"] > 0 and usage["remaining_tokens"] > 0 and
               usage["overrun"] == false,
             "budget_exhausted"
           ),
         :ok <- settled_attempts(state.run_id),
         do: {:ok, %{phase: "running", failure_code: nil}, "analysis"}
  end

  defp action_changes("cancel", _, _, _, _, _, _),
    do: {:ok, %{phase: "cancelled", failure_code: "cancelled"}, nil}

  defp action_changes(_, _, _, _, _, _, _), do: error("phase_conflict")

  defp register(nil, _, _, _, _, _), do: {:ok, nil}

  defp register(kind, env, run, state, config, version) do
    id = Ecto.UUID.generate()

    with {:ok, corpus} <-
           HarnessForge.Company.bound_corpus(config.scope_json["project_ref"]["id"]),
         :ok <- check(is_map(corpus) and corpus["state"] == "active", "stale_scope") do
      op = %SetupRunOperation{
        id: id,
        operation_id: id,
        workspace_id: Store.workspace(),
        owner_id: Workspaces.operator(),
        session_id: run.session_id,
        run_id: run.id,
        config_id: config.id,
        command_id: env["command_id"],
        kind: kind,
        expected_run_version: version,
        preparation_id: if(kind == "analysis", do: state.preparation_id),
        authorization_id: if(kind == "analysis", do: state.authorization_id),
        generations_json: [
          %{
            "corpus_id" => corpus["id"],
            "semantic_generation" => corpus["semantic_generation"],
            "authorization_generation" => corpus["authorization_generation"]
          }
        ]
      }

      Repo.insert(%{op | digest: digest_fields(op, @operation_fields)})
    end
  end

  defp accepted_effect("acquire", config, state, receipt, caller, _context) do
    with {:ok, result} <- Capture.start_for_setup(ref(config), receipt["command_ref"], caller),
         :ok <-
           check(
             result["operation_ref"] == receipt["operation_ref"] and
               valid_ref?(result["capture_ref"]),
             "unavailable"
           ),
         {:ok, saved} <- update_state(state, %{capture_id: result["capture_ref"]["id"]}),
         do: {:ok, saved}
  end

  defp accepted_effect("authorize", config, state, receipt, caller, context) do
    with {:ok, result} <- RunAuthorization.authorize(ref(config), receipt["prepared_ref"], caller, context),
         {:ok, saved} <-
           update_state(state, %{
             authorization_id: result["authorization_ref"]["id"],
             phase: "ready"
           }),
         do: {:ok, saved}
  end

  defp accepted_effect("cancel", _, state, _, _, _) do
    revoke_run(state.run_id, "cancelled")
    {:ok, state}
  end

  defp accepted_effect(_, _, state, _, _, _), do: {:ok, state}

  defp store_command(env, session, run, state, operation) do
    row_id = Ecto.UUID.generate()

    with {:ok, prep} <- preparation_reference(state.preparation_id) do
      receipt = %{
        "version" => 1,
        "command_ref" => %{"id" => row_id, "digest" => Contracts.digest(env)},
        "action" => env["action"],
        "run_ref" => ref(run),
        "operation_ref" => nullable_ref(operation),
        "prepared_ref" => nullable_ref(prep),
        "session_version" => session.lock_version,
        "run_version" => state.lock_version
      }

      with {:ok, _} <-
             Repo.insert(%SetupRunCommand{
               id: row_id,
               workspace_id: Store.workspace(),
               owner_id: Workspaces.operator(),
               session_id: session.id,
               run_id: run.id,
               command_id: env["command_id"],
               request_digest: Contracts.digest(env),
               request_json: env,
               receipt_json: receipt
             }),
           do: {:ok, receipt}
    end
  end

  defp execute_fresh(%{"action" => "retrieve"} = receipt, caller, context) do
    result =
      with {:ok, binding} <- operation_binding(receipt["operation_ref"]["id"], caller),
           {:ok, config} <-
             guarded(caller, fn -> owned(SetupRunConfig, binding["config_ref"]["id"]) end),
           scope = config.scope_json,
           {:ok, corpus} <-
             guarded(caller, fn ->
               HarnessForge.Company.bound_corpus(scope["project_ref"]["id"])
             end),
           {:ok, status} <- capture_for_retrieval(receipt, caller, context),
           {:ok, declaration} <- declare_capture(scope, corpus, status, caller),
           {:ok, retrieved} <-
             Retrieval.retrieve(
               %{
                 "corpus_id" => corpus["id"],
                 "project_id" => scope["project_ref"]["id"],
                 "goal_id" => scope["goal_ref"]["id"],
                 "goal_hash" => scope["goal_ref"]["digest"],
                 "expected_generation" => corpus["semantic_generation"],
                 "question" => scope["query_text"],
                 "mode" => "fts",
                 "declaration_ref" => Map.take(declaration, ~w(id digest))
               },
               caller,
               context
             ),
           :ok <- check(retrieved["state"] == "ready", "acquisition_incomplete"),
           {:ok, prepared} <-
             StageAuthority.prepare_setup_synthesis(
               receipt["operation_ref"],
               %{"id" => retrieved["run_id"], "digest" => retrieved["digest"]},
               caller,
               context
             ),
           do:
             publish_operation(
               receipt["operation_ref"],
               receipt["run_version"],
               prepared["prepared_ref"],
               caller,
               context
             )

    settle_failure(receipt, result, caller)
  end

  defp execute_fresh(%{"action" => action} = receipt, caller, context) when action in ~w(analyze retry) do
    result = HarnessForge.Company.AnalysisV2.analyze_prepared(receipt["operation_ref"], caller, context)
    settle_failure(receipt, result, caller)
  end

  defp execute_fresh(_, _, _), do: :ok

  defp capture_for_retrieval(receipt, caller, context) do
    with {:ok, view} <- get_by_run(receipt["run_ref"], caller, context),
         do: Capture.setup_status(view["capture_ref"], caller)
  end

  defp declare_capture(scope, corpus, status, caller) do
    with :ok <-
           check(
             status["scan_complete"] == true and status["index_ready"] == true and
               status["incomplete"] == false,
             "acquisition_incomplete"
           ),
         {:ok, context} <-
           Requirements.context(
             corpus["id"],
             scope["project_ref"]["id"],
             scope["goal_ref"]["id"],
             scope["goal_ref"]["digest"],
             caller
           ),
         {:ok, captured} <- Capture.read_summary(status["run_id"], caller),
         do:
           Requirements.declare(
             corpus["id"],
             context["expected"],
             %{
               "project_id" => scope["project_ref"]["id"],
               "goal_id" => scope["goal_ref"]["id"],
               "primary_connection_id" => scope["connection_id"],
               "entries" => [
                 %{
                   "connection_id" => scope["connection_id"],
                   "requirement" => "required",
                   "capture_run_id" => status["run_id"],
                   "capture_revision" => captured["revision"]
                 }
               ]
             },
             caller
           )
  end

  defp settle_failure(_, {:ok, _}, _), do: :ok

  defp settle_failure(receipt, failure, caller) do
    {:error, normalized} = normalize(failure)

    guarded(caller, fn ->
      with {:ok, session} <- session_by_run(receipt["run_ref"]),
           {:ok, {_, state, _}} <- current(session),
           :ok <-
             check(
               state.lock_version == receipt["run_version"] and
                 state.phase in ~w(retrieving running),
               "conflict"
             ),
           {:ok, _} <-
             update_state(state, %{
               phase: "blocked",
               failure_code: normalized["code"],
               lock_version: state.lock_version + 1
             }),
           do: {:ok, true}
    end)

    :ok
  end

  defp publication(op, result, caller, context) do
    case op.kind do
      "capture" ->
        with {:ok, status} <- Capture.setup_status(result, caller),
             :ok <-
               check(
                 result["id"] == op.operation_id and status["scan_complete"] == true and
                   status["index_ready"] == true and status["incomplete"] == false,
                 "acquisition_incomplete"
               ),
             do: {:ok, %{capture_id: result["id"], phase: "captured", failure_code: nil}}

      "retrieval" ->
        with {:ok, prep} <- preparation_reference(result["id"]),
             :ok <-
               check(
                 ref(prep) == result and prep.operation_id == op.operation_id and
                   prep.run_id == op.run_id and prep.config_id == op.config_id,
                 "stale_preparation"
               ),
             {:ok, _} <- RunAuthorization.prepared_view(result, caller, context),
             do:
               {:ok,
                %{
                  retrieval_id: prep.retrieval_ref["id"],
                  preparation_id: prep.id,
                  phase: "needs_input",
                  failure_code: nil
                }}

      "analysis" ->
        with {:ok, auth} <- owned(RunAuthorizationRecord, op.authorization_id),
             {:ok, _} <- RunAuthorization.current(ref(auth), ref(op), caller, context),
             :ok <- check(result["id"] == op.operation_id, "invalid_input"),
             [%{"state" => "completed", "result_digest" => digest}] <-
               Corpora.rows(
                 "SELECT state,result_digest FROM stage_operations WHERE workspace_id=? AND id=?",
                 [Store.workspace(), op.operation_id]
               ),
             :ok <- check(digest == result["digest"], "invalid_input"),
             do: {:ok, %{result_ref: result, phase: "completed", failure_code: nil}}
    end
  end

  defp proposal(session, connection, physical, descriptor) do
    selection = session.payload["selection"]

    with :ok <- catalog_current(selection),
         {:ok, goal} <- Store.get(Goal, selection["goal"]["id"]),
         note = session.payload["draft"]["outcome_note"] || "",
         query = if(String.trim(note) == "", do: goal.title, else: note),
         :ok <- check(Corpora.text?(query, 1024) and String.length(query) <= 256, "invalid_input") do
      refs =
        Map.new(
          ~w(profile project repository goal),
          &{&1 <> "_ref",
           %{"id" => selection[&1]["id"], "digest" => selection[&1]["content_hash"]}}
        )

      {:ok,
       Map.merge(refs, %{
         "version" => 1,
         "profile_version" => "setup-local-synthesis.v1",
         "outcome_hash" => outcome_hash(session),
         "connection_id" => connection,
         "root_fingerprint" => physical["root_fingerprint"],
         "history" => "current_snapshot_only",
         "query_text" => query,
         "descriptor" => descriptor,
         "capture_limits" => @capture_limits,
         "model_limits" => @model_limits
       })}
    end
  end

  defp config_current(config, session) do
    selection = session.payload["selection"]

    with :ok <- check(config.digest == Contracts.digest(config.scope_json), "unavailable"),
         :ok <- catalog_current(selection),
         :ok <- check(config.scope_json["outcome_hash"] == outcome_hash(session), "stale_scope"),
         :ok <-
           check(
             Enum.all?(~w(profile project repository goal), fn key ->
               config.scope_json[key <> "_ref"] == %{
                 "id" => selection[key]["id"],
                 "digest" => selection[key]["content_hash"]
               }
             end),
             "stale_scope"
           ),
         {:ok, connection} <- Store.get(Connection, config.scope_json["connection_id"]),
         :ok <-
           check(connection.status == "active" and connection.provider == "local", "stale_scope"),
         {:ok, descriptor} <- RunAuthorization.descriptor(),
         do: check(descriptor == config.scope_json["descriptor"], "stale_scope")
  end

  defp catalog_current(selection) do
    with true <- is_map(selection),
         true <- Enum.all?(~w(profile project repository goal), &is_map(selection[&1])),
         {:ok, profile} <- Store.get(Profile, selection["profile"]["id"]),
         {:ok, project} <- Store.get(Project, selection["project"]["id"]),
         {:ok, repository} <- Store.get(Repository, selection["repository"]["id"]),
         {:ok, goal} <- Store.get(Goal, selection["goal"]["id"]),
         true <-
           Enum.all?(
             [{profile, "profile"}, {project, "project"}, {repository, "repository"}],
             fn {record, key} ->
               record.content_hash == selection[key]["content_hash"] and
                 record.content_hash == Contracts.digest(record.payload)
             end
           ),
         true <- Goals.content_hash(goal) == selection["goal"]["content_hash"],
         true <- repository.id in project.payload["repository_ids"],
         true <- goal.id in (profile.payload["goal_ids"] ++ project.payload["goal_ids"]),
         do: :ok,
         else: (_ -> error("stale_scope"))
  end

  defp outcome_hash(session),
    do:
      Contracts.digest(%{
        "goal" => session.payload["selection"]["goal"],
        "outcome_note" => session.payload["draft"]["outcome_note"] || ""
      })

  defp run_view(nil, _, _), do: {:ok, nil}

  defp run_view({run, state, config}, caller, context) do
    with {:ok, prep} <- preparation_reference(state.preparation_id),
         {:ok, auth} <- optional(RunAuthorizationRecord, state.authorization_id),
         {:ok, predecessor} <- optional(SetupRun, run.predecessor_id),
         {:ok, usage} <- RunAuthorization.usage(ref(run), caller),
         {:ok, capture} <- capture_ref(state.capture_id) do
      prepared_result =
        if(prep, do: RunAuthorization.prepared_view(ref(prep), caller, context), else: {:ok, nil})

      prepared =
        case prepared_result do
          {:ok, value} -> value
          _ -> nil
        end

      {:ok, session} = session(run.session_id)
      current? = config_current(config, session) == :ok
      stale_preparation? = not is_nil(prep) and is_nil(prepared)

      phase =
        if((not current? or stale_preparation?) and state.phase not in ~w(cancelled expired),
          do: "blocked",
          else: effective_phase(state)
        )

      failure =
        cond do
          not current? -> "stale_scope"
          stale_preparation? -> "stale_preparation"
          true -> state.failure_code
        end

      {:ok,
       %{
         "run_ref" => ref(run),
         "predecessor_run_ref" => nullable_ref(predecessor),
         "run_version" => state.lock_version,
         "config_ref" => ref(config),
         "config" => config.scope_json,
         "phase" => phase,
         "capture_ref" => capture,
         "prepared" => prepared,
         "authorization_ref" => nullable_ref(auth),
         "result_ref" => state.result_ref,
         "usage" => usage,
         "failure_code" => failure
       }}
    end
  end

  defp capture_ref(nil), do: {:ok, nil}

  defp capture_ref(id) do
    case Corpora.rows(
           "SELECT digest FROM setup_capture_bindings WHERE workspace_id=? AND owner_id=? AND capture_id=?",
           [Store.workspace(), Workspaces.operator(), id]
         ) do
      [%{"digest" => digest}] -> {:ok, %{"id" => id, "digest" => digest}}
      _ -> error("unavailable")
    end
  end

  defp actions(nil), do: ["prepare"]

  defp actions(view) do
    case view["phase"] do
      "proposed" ->
        ~w(acquire cancel)

      phase when phase in ~w(acquiring captured) ->
        ~w(retrieve cancel)

      "needs_input" ->
        ~w(authorize cancel)

      "ready" ->
        ~w(analyze cancel)

      phase when phase in ~w(blocked completed) ->
        if(
          view["prepared"] && view["authorization_ref"] &&
            view["usage"]["uncertain_requests"] == 0 && view["usage"]["pending_requests"] == 0 &&
            view["usage"]["remaining_requests"] > 0,
          do: ~w(retry cancel),
          else: ["cancel"]
        )

      "expired" ->
        ~w(new_run cancel)

      "cancelled" ->
        ["new_run"]

      _ ->
        ["cancel"]
    end
  end

  defp history_page(session, cursor, caller) do
    binding = %{
      "kind" => "setup_run_history",
      "session_id" => session.id,
      "owner" => Workspaces.operator(),
      "workspace" => Store.workspace(),
      "caller" => caller[:session_fingerprint]
    }

    with {:ok, after_id} <- history_after(cursor, binding) do
      current_id = get_in(session.payload, ["refs", "run_ref", "id"]) || ""

      rows =
        Corpora.rows(
          "SELECT id,digest,inserted_at FROM setup_runs WHERE workspace_id=? AND owner_id=? AND session_id=? AND id!=? AND (?='' OR inserted_at||'|'||id<?) ORDER BY inserted_at DESC,id DESC LIMIT 21",
          [Store.workspace(), Workspaces.operator(), session.id, current_id, after_id, after_id]
        )

      visible = Enum.take(rows, 20)

      next =
        if length(rows) > 20 do
          last = List.last(visible)

          Phoenix.Token.sign(
            history_secret(),
            "setup-run-history-v1",
            Map.put(binding, "after", last["inserted_at"] <> "|" <> last["id"])
          )
        end

      Enum.reduce_while(visible, {:ok, []}, fn row, {:ok, acc} ->
        reference = Map.take(row, ~w(id digest))

        case RunAuthorization.usage(reference, caller) do
          {:ok, usage} -> {:cont, {:ok, acc ++ [%{"run_ref" => reference, "usage" => usage}]}}
          failure -> {:halt, failure}
        end
      end)
      |> case do
        {:ok, history} -> {:ok, %{"predecessor_usage" => history, "history_cursor" => next}}
        failure -> failure
      end
    end
  end

  defp history_after(cursor, _) when cursor in [nil, ""], do: {:ok, ""}

  defp history_after(cursor, binding) when is_binary(cursor) and byte_size(cursor) <= 8192 do
    with {:ok, payload} <-
           Phoenix.Token.verify(history_secret(), "setup-run-history-v1", cursor, max_age: 600),
         true <- Map.drop(payload, ["after"]) == binding,
         after_id when is_binary(after_id) <- payload["after"],
         do: {:ok, after_id},
         else: (_ -> error("invalid_input"))
  end

  defp history_after(_, _), do: error("invalid_input")

  defp history_secret,
    do:
      Application.fetch_env!(:harness_forge, HarnessForgeWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

  defp replay(env) do
    with {:ok, _} <- session(env["id"]) do
      case Repo.one(
             from c in SetupRunCommand,
               where:
                 c.workspace_id == ^Store.workspace() and c.owner_id == ^Workspaces.operator() and
                   c.session_id == ^env["id"] and c.command_id == ^env["command_id"]
           ) do
        nil ->
          {:ok, nil}

        row ->
          if row.request_digest == Contracts.digest(env) and row.request_json == env,
            do: {:ok, row.receipt_json},
            else: error("command_conflict")
      end
    end
  end

  defp versions(env, session, current) do
    run_version = if current, do: elem(current, 1).lock_version
    run_ref = if current, do: ref(elem(current, 0))

    if env["expected_session_version"] == session.lock_version and
         env["expected_run_version"] == run_version and env["run_ref"] == run_ref,
       do: :ok,
       else:
         {:error,
          %{
            "code" => "conflict",
            "current" => %{
              "session_version" => session.lock_version,
              "run_version" => run_version
            }
          }}
  end

  defp validate_command(env) do
    with :ok <-
           check(
             Corpora.keys(
               env,
               ~w(version id expected_session_version expected_run_version run_ref command_id action payload)
             ) == :ok,
             "invalid_input"
           ),
         :ok <-
           check(
             env["version"] == 1 and Corpora.uuid?(env["id"]) and Corpora.uuid?(env["command_id"]) and
               is_integer(env["expected_session_version"]) and env["expected_session_version"] > 0 and
               env["action"] in @actions,
             "invalid_input"
           ),
         :ok <-
           check(
             (is_nil(env["run_ref"]) and is_nil(env["expected_run_version"])) or
               (valid_ref?(env["run_ref"]) and is_integer(env["expected_run_version"]) and
                  env["expected_run_version"] > 0),
             "invalid_input"
           ) do
      case env["action"] do
        "prepare" ->
          check(
            Corpora.keys(env["payload"], ~w(profile_version connection_id)) == :ok and
              env["payload"]["profile_version"] == "setup-local-synthesis.v1" and
              Corpora.uuid?(env["payload"]["connection_id"]),
            "invalid_input"
          )

        action when action in ~w(authorize analyze retry) ->
          check(
            Corpora.keys(env["payload"], ["prepared_ref"]) == :ok and
              valid_ref?(env["payload"]["prepared_ref"]),
            "invalid_input"
          )

        "new_run" ->
          check(
            Corpora.keys(env["payload"], ["predecessor_run_ref"]) == :ok and
              valid_ref?(env["payload"]["predecessor_run_ref"]),
            "invalid_input"
          )

        "acquire" ->
          check(Corpora.keys(env["payload"], []) == :ok or
            (Corpora.keys(env["payload"], ["source_update_ref"]) == :ok and valid_ref?(env["payload"]["source_update_ref"])),
            "invalid_input")

        _ ->
          check(Corpora.keys(env["payload"], []) == :ok, "invalid_input")
      end
    end
  end

  defp advance_session(session, run_ref, upgrade \\ false) do
    payload = Map.put(session.payload, "refs", %{"run_ref" => run_ref})
    step = if upgrade and session.step not in ~w(outcome scope), do: "scope", else: session.step

    with :ok <- check(byte_size(Contracts.canonical_json(payload)) <= 16_384, "invalid_input"),
         {:ok, %{num_rows: 1}} <-
           Repo.query(
             "UPDATE setup_sessions SET schema_version=2,payload=?,step=?,lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND owner=? AND id=? AND lock_version=?",
             [
               Contracts.canonical_json(payload),
               step,
               Corpora.now(),
               Store.workspace(),
               Workspaces.operator(),
               session.id,
               session.lock_version
             ],
             log: false
           ),
         do: session(session.id),
         else: (_ -> error("conflict"))
  end

  defp update_state(state, changes) do
    query =
      from s in SetupRunState,
        where:
          s.id == ^state.id and s.workspace_id == ^Store.workspace() and
            s.owner_id == ^Workspaces.operator() and s.lock_version == ^state.lock_version

    case Repo.update_all(query, set: Map.to_list(Map.put(changes, :updated_at, Store.now()))) do
      {1, _} -> owned(SetupRunState, state.id)
      _ -> error("conflict")
    end
  end

  defp session(id) do
    case Repo.one(
           from s in SetupSession,
             where:
               s.workspace_id == ^Store.workspace() and s.owner == ^Workspaces.operator() and
                 s.id == ^id
         ) do
      nil -> error("not_found")
      record -> if record.schema_version in [1, 2], do: {:ok, record}, else: error("unavailable")
    end
  end

  defp current(session) do
    case get_in(session.payload, ["refs", "run_ref"]) do
      nil ->
        {:ok, nil}

      reference ->
        with :ok <- check(valid_ref?(reference), "unavailable"),
             {:ok, run} <- owned(SetupRun, reference["id"]),
             :ok <-
               check(
                 ref(run) == reference and run.session_id == session.id and
                   run.digest ==
                     digest_fields(
                       run,
                       ~w(id workspace_id owner_id session_id config_id predecessor_id)
                     ),
                 "not_found"
               ),
             state when not is_nil(state) <-
               Repo.one(
                 from s in SetupRunState,
                   where:
                     s.workspace_id == ^Store.workspace() and s.owner_id == ^Workspaces.operator() and
                       s.session_id == ^session.id and s.run_id == ^run.id
               ),
             {:ok, config} <- owned(SetupRunConfig, run.config_id),
             do: {:ok, {run, state, config}},
             else: (_ -> error("unavailable"))
    end
  end

  defp session_by_run(reference) do
    with :ok <- check(valid_ref?(reference), "invalid_input"),
         {:ok, run} <- owned(SetupRun, reference["id"]),
         :ok <- check(ref(run) == reference, "not_found"),
         do: session(run.session_id)
  end

  defp get_by_run(reference, caller, context),
    do:
      guarded(caller, fn ->
        with {:ok, session} <- session_by_run(reference),
             {:ok, current} <- current(session),
             do: run_view(current, caller, context)
      end)

  defp operation(id), do: owned(SetupRunOperation, id)

  defp command_row(id, session_id) do
    case Repo.one(
           from c in SetupRunCommand,
             where:
               c.workspace_id == ^Store.workspace() and c.owner_id == ^Workspaces.operator() and
                 c.session_id == ^session_id and c.command_id == ^id
         ) do
      nil -> error("not_found")
      row -> {:ok, row}
    end
  end

  defp owned(module, id) do
    with {:ok, record} <- Store.get(module, id),
         true <- record.owner_id == Workspaces.operator(),
         do: {:ok, record},
         else: (_ -> error("not_found"))
  end

  defp preparation_reference(nil), do: {:ok, nil}
  defp preparation_reference(id) do
    case Repo.one(from p in Store.scoped(SetupRunPreparation),
      where: p.id == ^id and p.owner_id == ^Workspaces.operator(),
      select: %{id: p.id, digest: p.digest, operation_id: p.operation_id, run_id: p.run_id, config_id: p.config_id, retrieval_ref: p.retrieval_ref}) do
      nil -> error("not_found")
      ref -> {:ok, ref}
    end
  end

  defp optional(_, nil), do: {:ok, nil}
  defp optional(module, id), do: owned(module, id)
  defp current_connection({_, _, config}), do: config.scope_json["connection_id"]
  defp current_connection(_), do: nil

  defp live_state(state),
    do:
      check(
        effective_phase(state) not in ~w(cancelled expired),
        if(effective_phase(state) == "expired", do: "authorization_expired", else: "cancelled")
      )

  defp effective_phase(%{phase: phase}) when phase in ~w(cancelled expired), do: phase
  defp effective_phase(%{authorization_id: nil} = state), do: state.phase

  defp effective_phase(state) do
    with {:ok, auth} <- owned(RunAuthorizationRecord, state.authorization_id),
         true <- DateTime.compare(Store.now(), auth.expires_at) != :lt,
         do: "expired",
         else: (_ -> state.phase)
  end

  defp operation_current(op, state) do
    with :ok <-
           check(
             state.lock_version in [op.expected_run_version, op.expected_run_version + 1],
             "conflict"
           ),
         :ok <- check(state.last_command_id == op.command_id, "conflict") do
      if op.kind == "capture",
        do: :ok,
        else:
          check(
            Enum.all?(op.generations_json, fn generation ->
              generation_metadata_current?(generation)
            end),
            "stale_scope"
          )
    end
  end

  # Operation binding proves reference currentness, never source-use authority.
  # This must remain metadata-only so bound source context can be validated first.
  defp generation_metadata_current?(generation) do
    with :ok <- Purge.ready(),
         {:ok, corpus} <- Corpora.get(generation["corpus_id"]),
         true <- corpus.state == "active" and
           corpus.semantic_generation == generation["semantic_generation"] and
           corpus.authorization_generation == generation["authorization_generation"],
         :ok <- HarnessForge.Evidence.RevisionUseHolds.assert_corpus_unheld(corpus.id) do
      true
    else
      _ -> false
    end
  end

  defp settled_attempts(run_id) do
    # No prior admitted analysis may still be active or ambiguous after restart.
    rows =
      Corpora.rows(
        "SELECT s.state FROM setup_run_operations o LEFT JOIN stage_operations s ON s.workspace_id=o.workspace_id AND s.id=o.operation_id WHERE o.workspace_id=? AND o.run_id=? AND o.kind='analysis'",
        [Store.workspace(), run_id]
      )

    check(
      Enum.all?(rows, &(&1["state"] in ~w(completed cancelled failed blocked))),
      "request_outcome_unknown"
    )
  end

  defp revoke_run(run_id, reason) do
    :ok = HarnessForge.Evidence.SetupCapture.cancel_bound_run(run_id)
    persisted_reason = if reason == "stale_scope", do: "scope_changed", else: "cancelled"

    Corpora.query!(
      "UPDATE model_run_authorization_states SET revoked_at=?,reason=?,lock_version=lock_version+1 WHERE workspace_id=? AND owner_id=? AND authorization_id IN(SELECT id FROM model_run_authorizations WHERE workspace_id=? AND run_id=?) AND revoked_at IS NULL",
      [
        Corpora.now(),
        persisted_reason,
        Store.workspace(),
        Workspaces.operator(),
        Store.workspace(),
        run_id
      ]
    )

    Corpora.query!(
      "UPDATE stage_operations SET state='cancelled',cancel_epoch=cancel_epoch+1,updated_at=? WHERE workspace_id=? AND id IN(SELECT operation_id FROM setup_run_operations WHERE workspace_id=? AND run_id=?) AND state='active'",
      [Corpora.now(), Store.workspace(), Store.workspace(), run_id]
    )
  end

  defp published?(state, changes),
    do: Enum.all?(changes, fn {key, value} -> Map.get(state, key) == value end)

  defp digest_fields(record, fields),
    do: Contracts.digest(Map.new(fields, &{&1, Map.fetch!(record, String.to_existing_atom(&1))}))

  defp ref(record), do: %{"id" => record.id, "digest" => record.digest}
  defp nullable_ref(nil), do: nil
  defp nullable_ref(record), do: ref(record)

  defp valid_ref?(value),
    do:
      Corpora.keys(value, ~w(id digest)) == :ok and Corpora.uuid?(value["id"]) and
        Corpora.digest?(value["digest"])

  defp source_context_matches(nil, _caller), do: :ok
  defp source_context_matches(context, caller) do
    case HarnessForge.Evidence.SourceUseContext.match_caller(context, caller) do
      :ok -> :ok
      _ -> error("unauthorized")
    end
  end

  defp authenticate(caller) do
    with :ok <- AssessmentAttempts.options(caller),
         :ok <- AssessmentAttempts.authorize(caller),
         :ok <- Workspaces.ensure_writable(),
         :ok <- Purge.ready(),
         do: :ok,
         else: (_ -> error("unauthorized"))
  end

  defp guarded(caller, fun) do
    invoke = fn ->
      with :ok <- authenticate(caller),
           {:ok, result} <- fun.(),
           :ok <- authenticate(caller),
           do: {:ok, result},
           else: (failure -> normalize(failure))
    end

    if Repo.in_transaction?() do
      if Process.get({Purge, :synchronize, Store.workspace()}) == true,
        do: invoke.(),
        else: error("unavailable")
    else
      Purge.synchronize(fn -> Store.transaction(invoke) end)
    end
  rescue
    _ -> error("unavailable")
  end

  defp check(true, _), do: :ok
  defp check(_, code), do: error(code)
  defp error(code), do: {:error, %{"code" => code, "current" => nil}}
  defp normalize(value, fallback \\ "unavailable")

  defp normalize({:error, %{"code" => _} = error}, _),
    do: {:error, Map.put_new(error, "current", nil)}

  defp normalize({:error, code}, fallback) when is_atom(code),
    do: error(if(Atom.to_string(code) in @errors, do: Atom.to_string(code), else: fallback))

  defp normalize(_, fallback), do: error(fallback)
end
