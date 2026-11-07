defmodule HarnessForge.Graphiti.Runtime do
  @moduledoc "Root-owned live launch registry. Stored identities alone confer no execution authority."
  use GenServer
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Company.AssessmentAttempts
  alias HarnessForge.Evidence.{Corpora, GraphSources, Store}

  alias HarnessForge.Graphiti.{
    Backend,
    Image,
    IngestIntent,
    Inventory,
    LaunchProfile,
    Pipe,
    Private,
    Protocol,
    ReplayTranscript,
    ResponseProof,
    SearchIntent,
    Worker
  }

  alias HarnessForge.Models.{StageAuthority, StageControl, Stages}
  @live __MODULE__.Live

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def provision(partition, caller), do: outside_call({:provision, partition, caller}, 90_000)

  def launch(partition, stage_ids, caller),
    do: outside_call({:launch, partition, stage_ids, caller}, 30_000)

  def bind_operation(auth), do: outside_call({:bind_operation, auth}, 10_000)

  # Jobs and measured request projections live only in this owner. SQL rows
  # and a previous ACK cannot reconstruct either execution capability.
  def submit(auth, job) do
    with {:ok, worker} <- outside_call({:register_job, auth, job}, 10_000) do
      case Worker.submit(worker, job, auth) do
        {:ok, _} = accepted ->
          accepted

        error ->
          outside_call({:abort_job, auth}, 10_000)
          error
      end
    end
  end

  @doc "Register, submit and atomically install the awaiter on the exact private worker."
  def await(auth, job, timeout) do
    with {:ok, worker} <- outside_call({:register_job, auth, job}, 10_000) do
      case Worker.submit_and_await(worker, job, auth, timeout) do
        {:ok, _} = result ->
          result

        error ->
          outside_call({:abort_job, auth}, 10_000)
          error
      end
    end
  catch
    :exit, _ ->
      outside_call({:abort_job, auth}, 10_000)
      {:error, :worker_lost}
  end

  def prepare_search(auth), do: outside_call({:prepare_search, auth}, 65_000)

  @doc "Prepared base checked only through protected ETS and caller-side SQL; no job or owner RPC."
  def search_prepared(%StageAuthority{operation_type: "search"} = auth) do
    with true <- live_owner?(),
         [{{:search_prepared, operation}, prepared}] <-
           :ets.lookup(@live, {:search_prepared, auth.operation_id}),
         true <-
           operation == auth.operation_id and prepared.authority == completion_authority(auth),
         :ok <- current(auth),
         :ok <- base_pointer_current(auth, prepared.base, "bound"),
         {:ok, _} <-
           HarnessForge.Evidence.GraphManifests.inventory_stage_pins(prepared.base, auth),
         do: {:ok, prepared.base},
         else: (_ -> {:error, :closure_incomplete})
  rescue
    _ -> {:error, :closure_incomplete}
  end

  def search_prepared(_), do: {:error, :closure_incomplete}

  # No caller-side transaction may RPC to this owner. This capability is valid
  # only in the actual publisher process after irreversible writer retirement.
  def begin_completion(auth, job, result),
    do: outside_call({:begin_completion, auth, job, result}, 50_000)

  def completion_current(auth, job, result, ref) do
    with {:ok, digest} <- HarnessForge.Graphiti.CompletionCommitment.digest(result),
         true <- ref["job_digest"] == Contracts.digest(job) and ref["completion_digest"] == digest,
         :ok <- completion_local_current(auth, ref, self()),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  rescue
    _ -> {:error, :closure_incomplete}
  end

  def completion_inventory(auth, ref, query),
    do: outside_call({:completion_inventory, auth, ref, query}, 40_000)

  def end_completion(auth, ref, outcome),
    do: outside_call({:end_completion, auth, ref, outcome}, 10_000)

  @doc "Immutable private job base; local ETS/caller SQL only, never owner RPC."
  def base_inventory(%StageAuthority{} = auth, job) do
    digest = Contracts.digest(job)

    with true <- live_owner?(),
         {:ok, base, phase} <- private_job_base(auth, digest),
         :ok <- base_pointer_current(auth, base, phase),
         do: {:ok, base},
         else: (_ -> {:error, :closure_incomplete})
  rescue
    _ -> {:error, :closure_incomplete}
  end

  def base_inventory(_, _), do: {:error, :closure_incomplete}

  def observation_current(%StageAuthority{} = auth, job) do
    with :ok <- current(auth),
         [{{:job, operation}, digest}] <- :ets.lookup(@live, {:job, auth.operation_id}),
         true <- operation == auth.operation_id and digest == Contracts.digest(job),
         do: :ok,
         else: (_ -> {:error, :scope_denied})
  rescue
    _ -> {:error, :scope_denied}
  end

  def observation_current(_, _), do: {:error, :scope_denied}

  def observation_page_current(auth, job, page) do
    with :ok <- observation_current(auth, job), do: active_observation(auth, page)
  rescue
    _ -> {:error, :scope_denied}
  end

  def begin_observation(auth, job, page),
    do: outside_call({:begin_observation, auth, job, page}, 10_000)

  def end_observation(auth, job, page, outcome),
    do: outside_call({:end_observation, auth, job, page, outcome}, 10_000)

  def take_projection(auth, attempt),
    do: outside_call({:take_projection, auth, attempt}, 10_000)

  def retain_receipt(auth, attempt, receipt),
    do: outside_call({:retain_receipt, auth, attempt, receipt}, 10_000)

  # Erasure notices never wait while a caller owns a SQL/privacy lock.
  # Durable currentness already denies serving stale slots immediately.
  def forget_partition(partition) do
    if owner = Process.whereis(__MODULE__), do: send(owner, {:clear_partition_memory, partition})
    :ok
  end

  def forget_corpus(corpus) do
    if owner = Process.whereis(__MODULE__), do: send(owner, {:clear_corpus_memory, corpus})
    :ok
  end

  def observe_values(auth, page, job) do
    with false <- Repo.in_transaction?(),
         :ok <- observation_page_current(auth, job, page),
         {:ok, _} <- outside_call({:replay_values, auth, job, page}, 20_000),
         :ok <- observation_page_current(auth, job, page),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  rescue
    _ -> {:error, :closure_incomplete}
  end

  def observe_inventory(auth, page, job) do
    with false <- Repo.in_transaction?(),
         :ok <- observation_current(auth, job),
         :ok <- active_observation(auth, page),
         true <- page["seam_id"] == "graphiti.save.v1" and page["phase"] == "derived",
         {:ok, objects} <- saved_objects(page),
         :ok <- match_saved_objects(auth, objects),
         :ok <- observation_current(auth, job),
         :ok <- active_observation(auth, page),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  rescue
    _ -> {:error, :closure_incomplete}
  end

  def current(%StageAuthority{} = auth) do
    with :ok <- live_current(auth),
         {:ok, %{rows: [["verified", backend, "bound", operation, lease, token]]}} <-
           Repo.query(
             "SELECT b.state,b.bundle_digest,s.state,s.operation_id,s.lease_id,s.launch_token_hash FROM graph_runtime_backends b JOIN graph_worker_sessions s ON s.workspace_id=b.workspace_id AND s.partition_id=b.partition_id WHERE b.workspace_id=? AND b.partition_id=? AND s.id=?",
             [Store.workspace(), auth.partition_id, auth.worker_session_id]
           ),
         true <-
           backend == auth.backend_pin_digest and operation == auth.operation_id and
             lease == auth.lease_id and token == Store.hash(auth.launch_token),
         {:ok, _} <- StageControl.graph_current(auth),
         do: :ok,
         else: (_ -> {:error, :worker_lost})
  end

  def current(_), do: {:error, :scope_denied}

  def binding(partition) do
    with true <- live_owner?(),
         [{{:backend, ^partition}, workspace, bundle, watcher}] <-
           :ets.lookup(@live, {:backend, partition}),
         true <- workspace == Store.workspace() and not is_nil(Port.info(watcher)),
         do: {:ok, bundle},
         else: (_ -> {:error, :graph_unavailable})
  rescue
    _ -> {:error, :graph_unavailable}
  end

  def inventory(%StageAuthority{} = auth, query) do
    with false <- Repo.in_transaction?(),
         :ok <- current(auth),
         {:ok, result} <- outside_call({:inventory, auth.partition_id, query}, 40_000),
         :ok <- current(auth) do
      {:ok, result}
    else
      true -> {:error, :transaction_boundary_required}
      {:error, _} = error -> error
    end
  end

  def inventory(_, _), do: {:error, :scope_denied}
  def stop(partition, caller), do: outside_call({:stop, partition, caller}, 60_000)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    :ets.new(@live, [:named_table, :protected, :set, read_concurrency: true])
    Process.send_after(self(), :expire_execution_memory, 1000)
    # Also fence on a restart of just this child, without assuming the whole
    # application/StartupGate restarted. Old containers are never adopted.
    if Application.get_env(:harness_forge, :startup_recovery, true), do: reconcile_owner_loss()
    {:ok, %{backends: %{}, sessions: %{}, observations: %{}, completions: %{}}}
  end

  @impl true
  def handle_call({:provision, partition, caller}, _from, state) do
    result =
      with :ok <- authorize(caller),
           false <- Map.has_key?(state.backends, partition),
           %{"worker_image" => worker_image, "backend_image" => backend_image} <-
             Application.get_env(:harness_forge, :graph_runtime_images),
           {:ok, endpoint} <- HarnessForge.Execution.Command.local_endpoint(),
           {:ok, image} <- Image.verify(endpoint, worker_image),
           {:ok, scope} <- reserve_backend(partition, caller) do
        progress = fn resources ->
          case Repo.query(
                 "UPDATE graph_runtime_backends SET resource_json=?,updated_at=? WHERE workspace_id=? AND partition_id=? AND state='provisioning'",
                 [Contracts.canonical_json(resources), now(), Store.workspace(), partition]
               ) do
            {:ok, %{num_rows: 1}} -> :ok
            _ -> {:error, :reconcile_required}
          end
        end

        case Backend.create(scope, image, backend_image, progress) do
          {:ok, backend} ->
            with :ok <- authorize(caller),
                 :ok <-
                   Corpora.assert_current(
                     scope["corpus_id"],
                     scope["semantic_generation"],
                     scope["authorization_generation"]
                   ),
                 identity = %{
                   "worker_image" => worker_image,
                   "backend_image" => backend_image,
                   "backend_instance" => scope["instance_id"],
                   "database" => "neo4j",
                   "index_identity" => scope["instance_id"]
                 },
                 {:ok, bundle} <- GraphSources.runtime_bundle(identity),
                 true <-
                   Enum.all?(bundle["files"], fn {name, hash} ->
                     backend.image["source_pins"][name] == hash
                   end),
                 qualification = Ecto.UUID.generate(),
                 cipher = Private.seal(backend.credentials, partition, scope["instance_id"]),
                 {:ok, watcher} <- Pipe.watch(backend.endpoint, backend.backend_id),
                 :ok <- Backend.inspect_current(backend),
                 {:ok, %{num_rows: 1}} <-
                   Repo.query(
                     "UPDATE graph_runtime_backends SET state='verified',bundle_json=?,bundle_digest=?,credentials_cipher=?,qualification_ref=?,updated_at=? WHERE workspace_id=? AND partition_id=? AND state='provisioning'",
                     [
                       Contracts.canonical_json(bundle),
                       Contracts.digest(bundle),
                       cipher,
                       qualification,
                       now(),
                       Store.workspace(),
                       partition
                     ]
                   ) do
              {:ok,
               Map.merge(backend, %{
                 scope: scope,
                 bundle: bundle,
                 watcher: watcher,
                 qualification_ref: qualification
               })}
            else
              _ ->
                fence_backend(partition)
                {:error, :reconcile_required}
            end

          error ->
            fence_backend(partition)
            error
        end
      else
        _ -> {:error, :graph_unavailable}
      end

    case result do
      {:ok, backend} ->
        :ets.insert(
          @live,
          {{:backend, partition}, Store.workspace(), backend.bundle, backend.watcher}
        )

        {:reply, {:ok, public_backend(backend)}, put_in(state.backends[partition], backend)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:binding, partition}, _from, state),
    do: {:reply, __MODULE__.binding(partition), state}

  def handle_call({:launch, partition, stage_ids, caller}, _from, state) do
    result =
      with :ok <- authorize(caller),
           backend when not is_nil(backend) <- state.backends[partition],
           :ok <- backend_current(backend),
           true <- Enum.all?(state.sessions, fn {_, s} -> s.partition != partition end),
           true <- is_list(stage_ids) and length(stage_ids) in 1..7,
           pins = Enum.map(stage_ids, &StageAuthority.load_pin/1),
           true <- Enum.all?(pins, &match?({:ok, _}, &1)),
           pins = Enum.map(pins, &elem(&1, 1)),
           true <- Enum.all?(pins, &(HarnessForge.Graphiti.SchemaPolicy.validate_pin(&1) == :ok)),
           {:ok, stage_set} <- Stages.set_digest(pins) do
        outcome =
          with :ok <- Backend.inspect_current(backend),
               do: launch_worker(backend, pins, stage_set)

        if match?({:error, _}, outcome), do: fence_backend(partition)
        outcome
      else
        _ -> {:error, :graph_unavailable}
      end

    case result do
      {:ok, session} ->
        backend = %{state.backends[partition] | writer_ids: [session.container_id]}

        {:reply, {:ok, session.id},
         %{
           state
           | backends: Map.put(state.backends, partition, backend),
             sessions: Map.put(state.sessions, session.id, session)
         }}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:bind_operation, %StageAuthority{} = auth}, _from, state) do
    session = state.sessions[auth.worker_session_id]

    result =
      with %{operation: nil} <- session,
           true <-
             session.partition == auth.partition_id and
               session.stage_set_digest == StageAuthority.stage_set_digest(auth),
           true <- Process.alive?(session.pid) and not is_nil(Port.info(session.port)),
           {:ok, _} <- StageControl.graph_current(auth),
           token = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
           {:ok, %{num_rows: 1}} <-
             Repo.query(
               "UPDATE graph_worker_sessions SET state='bound',operation_id=?,lease_id=?,launch_token_hash=?,updated_at=? WHERE workspace_id=? AND id=? AND state='ready' AND operation_id IS NULL",
               [
                 auth.operation_id,
                 auth.lease_id,
                 Store.hash(token),
                 now(),
                 Store.workspace(),
                 session.id
               ]
             ) do
        {:ok, token}
      else
        _ -> {:error, :scope_denied}
      end

    case result do
      {:ok, token} ->
        session =
          Map.merge(session, %{
            operation: auth.operation_id,
            lease: auth.lease_id,
            token_hash: Store.hash(token)
          })

        backend = state.backends[session.partition]

        :ets.insert(
          @live,
          {{:session, session.id},
           %{
             workspace: Store.workspace(),
             partition: session.partition,
             operation: session.operation,
             lease: session.lease,
             token_hash: session.token_hash,
             pid: session.pid,
             port: session.port,
             stages: session.stage_set_digest,
             backend: Contracts.digest(backend.bundle),
             watcher: backend.watcher
           }}
        )

        {:reply, {:ok, %{auth | launch_token: token}},
         put_in(state.sessions[session.id], session)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:current, %StageAuthority{} = auth}, _from, state),
    do: {:reply, live_current(auth), state}

  def handle_call({:inventory, partition, query}, _from, state) do
    result =
      with backend when not is_nil(backend) <- state.backends[partition],
           :ok <- backend_current(backend),
           :ok <- Backend.inspect_current(backend),
           {:ok, measured} <- Inventory.measure(backend, query),
           :ok <- Workspaces.ensure_writable(),
           :ok <- HarnessForge.Privacy.Purge.ready(),
           :ok <- backend_current(backend),
           :ok <- Backend.inspect_current(backend),
           do: {:ok, measured},
           else: (_ -> {:error, :graph_unavailable})

    {:reply, result, state}
  end

  def handle_call(
        {:prepare_search, %StageAuthority{operation_type: "search"} = auth},
        _from,
        state
      ) do
    outcome =
      with :ok <- current(auth),
           %{operation: operation} = session <- state.sessions[auth.worker_session_id],
           true <-
             operation == auth.operation_id and is_nil(Map.get(session, :job_digest)) and
               not Map.get(session, :preparation_used, false),
           {:ok, base} <- capture_search_pointer(auth),
           {:ok, _} <- HarnessForge.Evidence.GraphManifests.inventory_stage_pins(base, auth),
           backend = state.backends[auth.partition_id],
           :ok <- backend_current(backend),
           :ok <- Backend.inspect_current(backend),
           remaining = min(60_000, DateTime.diff(auth.deadline_at, Store.now(), :millisecond)),
           true <- remaining > 0,
           request = %{
             "operation_id" => auth.operation_id,
             "partition_id" => auth.partition_id,
             "lease_id" => auth.lease_id,
             "scope_ref" => auth.scope_ref,
             "stage_set_digest" => StageAuthority.stage_set_digest(auth)
           },
           {:ok, ack} <- Worker.prepare_runtime(session.pid, request, remaining),
           true <-
             Map.take(ack, Map.keys(request)) == request and ack["initialized"] == true and
               ack["source_lock_digest"] == backend.bundle["files"]["source.lock.json"] and
               ack["backend_pin_digest"] == auth.backend_pin_digest and is_nil(ack["error_code"]),
           :ok <- current(auth),
           {:ok, ^base} <- capture_search_pointer(auth),
           {:ok, _} <- HarnessForge.Evidence.GraphManifests.inventory_stage_pins(base, auth),
           :ok <- Backend.inspect_current(backend),
           do: {:ok, base},
           else: (_ -> {:error, :closure_incomplete})

    case outcome do
      {:ok, base} ->
        :ets.insert(
          @live,
          {{:search_prepared, auth.operation_id},
           %{authority: completion_authority(auth), base: base}}
        )

        session =
          state.sessions[auth.worker_session_id]
          |> Map.put(:preparation_used, true)
          |> Map.put(:read_only, true)
          |> Map.put(:search_epoch, auth.cancel_epoch)
          |> Map.put(:base_inventory, base)
          |> Map.put(:deadline_at, auth.deadline_at)

        {:reply, {:ok, base}, put_in(state.sessions[auth.worker_session_id], session)}

      _ ->
        if live_current(auth) == :ok, do: fence_backend(auth.partition_id)
        {:reply, {:error, :closure_incomplete}, state}
    end
  end

  def handle_call({:register_job, %StageAuthority{} = auth, job}, _from, state) do
    with :ok <- current(auth),
         :ok <- StageAuthority.revalidate_job(%{"authority" => auth, "job" => job}),
         :ok <- validate_job_intent(auth, job, :prepared),
         {:ok, base} <- capture_job_base(auth, job),
         %{operation: operation, pid: worker} = session <- state.sessions[auth.worker_session_id],
         true <- operation == auth.operation_id and is_nil(Map.get(session, :job_digest)) do
      digest = Contracts.digest(job)
      :ets.insert(@live, {{:job, auth.operation_id}, digest})

      :ets.insert(
        @live,
        {{:job_base, auth.operation_id},
         %{
           authority: completion_authority(auth),
           digest: digest,
           base: base
         }}
      )

      session =
        Map.merge(session, %{
          job_digest: digest,
          base_inventory: base,
          search_query: if(auth.operation_type == "search", do: job["args"]["query"], else: nil),
          projections: %{},
          seen_contexts: MapSet.new(),
          transcript: ReplayTranscript.new(),
          deadline_at: auth.deadline_at
        })

      {:reply, {:ok, worker}, put_in(state.sessions[auth.worker_session_id], session)}
    else
      _ -> {:reply, {:error, :scope_denied}, state}
    end
  end

  def handle_call({:abort_job, %StageAuthority{} = auth}, _from, state) do
    case state.sessions[auth.worker_session_id] do
      %{read_only: true} = session ->
        if cancelled_search?(session) do
          {:reply, {:error, :cancelled}, retire_cancelled_search(state, session)}
        else
          if live_current(auth) == :ok, do: fence_backend(auth.partition_id)
          {:reply, {:error, :reconcile_required}, state}
        end

      _ ->
        if live_current(auth) == :ok, do: fence_backend(auth.partition_id)
        {:reply, {:error, :reconcile_required}, state}
    end
  end

  def handle_call({:begin_observation, %StageAuthority{} = auth, job, page}, {pid, _}, state) do
    with :ok <- observation_current(auth, job),
         :ok <- Protocol.validate_payload("context_page", page),
         true <- page["job_id"] == auth.operation_id,
         false <- Map.has_key?(state.observations, auth.operation_id) do
      observation = %{
        pid: pid,
        monitor: Process.monitor(pid),
        digest: Protocol.context_page_digest(page),
        partition: auth.partition_id,
        session: auth.worker_session_id
      }

      :ets.insert(@live, {{:observation, auth.operation_id}, Map.drop(observation, [:monitor])})
      {:reply, :ok, put_in(state.observations[auth.operation_id], observation)}
    else
      _ -> {:reply, {:error, :scope_denied}, state}
    end
  end

  def handle_call(
        {:end_observation, %StageAuthority{} = auth, job, page, outcome},
        {pid, _},
        state
      ) do
    case state.observations[auth.operation_id] do
      %{pid: ^pid, digest: digest} = observation ->
        if digest == Protocol.context_page_digest(page) do
          Process.demonitor(observation.monitor, [:flush])
          :ets.delete(@live, {:observation, auth.operation_id})
          state = %{state | observations: Map.delete(state.observations, auth.operation_id)}

          case retain_projection(state, auth, job, page, outcome) do
            {:ok, next} ->
              {:reply, :ok, next}

            _ ->
              state =
                retire_cancelled_or_fence(state, auth.partition_id, auth.worker_session_id)

              {:reply, {:error, :reconcile_required}, state}
          end
        else
          {:reply, {:error, :scope_denied}, state}
        end

      _ ->
        {:reply, {:error, :scope_denied}, state}
    end
  end

  def handle_call({:take_projection, %StageAuthority{} = auth, attempt}, _from, state) do
    with :ok <- current(auth),
         :ok <- Protocol.validate_payload("attempt", attempt),
         session when not is_nil(session) <- state.sessions[auth.worker_session_id],
         {projection, remaining} when not is_nil(projection) <-
           Map.pop(Map.get(session, :projections, %{}), attempt["context_manifest_ref"]),
         true <-
           projection["body_hash"] == attempt["payload_sha256"] and
             projection["manifest_digest"] == attempt["context_manifest_digest"] and
             projection["stage_id"] == attempt["stage_id"] and
             projection["logical_call_id"] == attempt["logical_call_id"] and
             projection["operation_id"] == attempt["job_id"] do
      projection =
        if auth.operation_type == "search",
          do: Map.put(projection, "search_query", session.search_query),
          else: projection

      session = Map.put(session, :projections, remaining)
      {:reply, {:ok, projection}, put_in(state.sessions[auth.worker_session_id], session)}
    else
      _ -> {:reply, {:error, :scope_denied}, state}
    end
  end

  def handle_call({:retain_receipt, %StageAuthority{} = auth, attempt, receipt}, _from, state) do
    with :ok <- current(auth),
         session when not is_nil(session) <- state.sessions[auth.worker_session_id],
         true <- not is_nil(Map.get(session, :job_digest)),
         {:ok, transcript} <-
           ReplayTranscript.retain_receipt(session.transcript, auth, attempt, receipt) do
      {:reply, :ok, put_in(state.sessions[auth.worker_session_id].transcript, transcript)}
    else
      _ -> {:reply, {:error, :closure_incomplete}, state}
    end
  end

  def handle_call({:replay_values, %StageAuthority{} = auth, job, page}, {pid, _}, state) do
    result =
      with :ok <- observation_current(auth, job),
           %{pid: ^pid, digest: digest} <- state.observations[auth.operation_id],
           true <- digest == Protocol.context_page_digest(page),
           true <- page["seam_id"] == "llm.response.v1" and page["phase"] == "derived",
           [%{"receipt_ref" => nil, "value" => claimed}] <- page["entries"],
           session = state.sessions[auth.worker_session_id],
           {:ok, request} <- ReplayTranscript.request(session.transcript, auth, page),
           timeout = min(15_000, DateTime.diff(auth.deadline_at, Store.now(), :millisecond)),
           {:ok, proof} <-
             ResponseProof.verify(state.backends[auth.partition_id], request, timeout),
           true <- proof["value"] == claimed,
           :ok <- observation_current(auth, job),
           do: {:ok, proof["receipt"]},
           else: (_ -> {:error, :closure_incomplete})

    {:reply, result, state}
  end

  def handle_call({:stop, partition, caller}, _from, state) do
    with :ok <- authorize(caller),
         true <- Corpora.uuid?(partition),
         {:ok, %{rows: [[_]]}} <-
           Repo.query("SELECT id FROM graph_partition_controls WHERE workspace_id=? AND id=?", [
             Store.workspace(),
             partition
           ]) do
      # Deny all concurrent use before terminating either process or resources.
      # This also works after owner loss: persisted IDs grant deletion only.
      fence_backend(partition)

      result =
        with :ok <- stop_processes(state, partition),
             {:ok, endpoint} <- HarnessForge.Execution.Command.local_endpoint(),
             :ok <- cleanup_sessions(endpoint, partition),
             :ok <- close_watcher(state.backends[partition]),
             :ok <- cleanup_backend(endpoint, partition),
             {:ok, _} <-
               Repo.query(
                 "UPDATE graph_episode_bindings SET state='removed',updated_at=? WHERE workspace_id=? AND partition_id=? AND state!='removed'",
                 [now(), Store.workspace(), partition]
               ),
             {:ok, _} <-
               Repo.query(
                 "UPDATE graph_observation_events SET binding_state='denied' WHERE workspace_id=? AND binding_state='unused' AND operation_id IN(SELECT id FROM stage_operations WHERE workspace_id=? AND partition_id=?)",
                 [Store.workspace(), Store.workspace(), partition]
               ),
             {:ok, _} <-
               Repo.query(
                 "UPDATE graph_observation_calls SET state='denied',call_version=call_version+1,updated_at=? WHERE workspace_id=? AND state='active' AND operation_id IN(SELECT id FROM stage_operations WHERE workspace_id=? AND partition_id=?)",
                 [now(), Store.workspace(), Store.workspace(), partition]
               ),
             {:ok, _} <-
               Repo.query(
                 "UPDATE graph_runtime_backends SET state='stopped',credentials_cipher=NULL,updated_at=? WHERE workspace_id=? AND partition_id=?",
                 [now(), Store.workspace(), partition]
               ) do
          :ok
        else
          _ -> {:error, :reconcile_required}
        end

      if result == :ok do
        sessions = Map.reject(state.sessions, fn {_, s} -> s.partition == partition end)

        {:reply, :ok,
         %{state | backends: Map.delete(state.backends, partition), sessions: sessions}}
      else
        # Retain recorded cleanup ownership until a verified retry succeeds.
        {:reply, result, state}
      end
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :scope_denied}, state}
    end
  end

  def handle_call(
        {:begin_completion, %StageAuthority{} = auth, job, result},
        {publisher, _},
        state
      ) do
    with :ok <- observation_current(auth, job),
         :ok <- StageAuthority.revalidate_job(%{"authority" => auth, "job" => job}),
         :ok <- validate_job_intent(auth, job, :current),
         :ok <- completion_initial(auth, job, result),
         {:ok, base} <- base_inventory(auth, job),
         false <- Map.has_key?(state.completions, auth.partition_id),
         false <- Map.has_key?(state.observations, auth.operation_id),
         session when not is_nil(session) <- state.sessions[auth.worker_session_id],
         {:ok, digest} <- HarnessForge.Graphiti.CompletionCommitment.digest(result),
         {:ok, ids} <-
           Worker.prepare_retirement(session.pid, auth.operation_id, publisher, digest) do
      # Once prepare_retirement succeeds, any subsequent failure is terminal.
      ref = %{
        "id" => Ecto.UUID.generate(),
        "inventory_revision" => base["inventory_revision"],
        "base_inventory" => base,
        "writer_id" => session.container_id,
        "worker_image_id" => state.backends[auth.partition_id].spec["worker_image"],
        "receipt_ids" => ids,
        "job_digest" => Contracts.digest(job),
        "completion_digest" => digest
      }

      cap = %{
        ref: ref,
        pid: publisher,
        monitor: Process.monitor(publisher),
        partition: auth.partition_id,
        operation: auth.operation_id,
        session: auth.worker_session_id,
        worker: session.pid,
        authority: completion_authority(auth),
        binding: job["args"]["binding_id"],
        watcher: state.backends[auth.partition_id].watcher,
        phase: :retiring
      }

      :ets.delete(@live, {:session, auth.worker_session_id})
      :ets.delete(@live, {:job, auth.operation_id})
      :ets.delete(@live, {:job_base, auth.operation_id})
      :ets.delete(@live, {:search_prepared, auth.operation_id})
      :ets.delete(@live, {:observation, auth.operation_id})
      :ets.insert(@live, {{:completion, ref["id"]}, cap})

      session =
        session
        |> Map.put(:retiring, true)
        |> Map.put(:search_query, nil)
        |> Map.put(:projections, %{})
        |> Map.put(:transcript, ReplayTranscript.new())
        |> Map.put(:seen_contexts, MapSet.new())

      state = %{
        state
        | completions: Map.put(state.completions, auth.partition_id, cap),
          sessions: Map.put(state.sessions, auth.worker_session_id, session)
      }

      backend = state.backends[auth.partition_id]

      outcome =
        with :ok <- completion_receipts(auth, result, ids),
             :ok <-
               Backend.remove_worker(
                 backend.endpoint,
                 session.container_id,
                 auth.partition_id,
                 session.id
               ),
             :ok <- Pipe.close(session.port),
             {:ok, %{num_rows: 1}} <-
               Repo.query(
                 "UPDATE graph_worker_sessions SET state='stopped',updated_at=? WHERE workspace_id=? AND id=? AND state='bound'",
                 [now(), Store.workspace(), session.id]
               ),
             backend = %{backend | writer_ids: []},
             :ok <- backend_current(backend),
             :ok <- Backend.inspect_current(backend),
             {:ok, _} <- StageControl.graph_current(auth),
             do: {:ok, backend},
             else: (_ -> {:error, :closure_incomplete})

      case outcome do
        {:ok, backend} ->
          cap = %{cap | phase: :measuring}
          :ets.insert(@live, {{:completion, ref["id"]}, cap})

          state = %{
            state
            | backends: Map.put(state.backends, auth.partition_id, backend),
              completions: Map.put(state.completions, auth.partition_id, cap)
          }

          {:reply, {:ok, ref}, state}

        _ ->
          state = retire_cancelled_or_fence(state, auth.partition_id, auth.worker_session_id)
          {:reply, {:error, :closure_incomplete}, discard_completion(state, auth.partition_id)}
      end
    else
      _ -> {:reply, {:error, :closure_incomplete}, state}
    end
  end

  def handle_call({:completion_inventory, %StageAuthority{} = auth, ref, query}, {pid, _}, state) do
    result =
      with :ok <- completion_local_current(auth, ref, pid),
           backend when not is_nil(backend) <- state.backends[auth.partition_id],
           :ok <- Backend.inspect_current(backend),
           {:ok, measured} <- Inventory.measure(backend, query),
           :ok <- completion_local_current(auth, ref, pid),
           :ok <- Backend.inspect_current(backend),
           do: {:ok, measured},
           else: (_ -> {:error, :closure_incomplete})

    {:reply, result, state}
  end

  def handle_call({:end_completion, %StageAuthority{} = auth, ref, outcome}, {pid, _}, state) do
    case completion_cap(auth, ref, pid) do
      {:ok, cap} ->
        result =
          with {:ok, envelope} <- outcome,
               {:ok, digest} <- HarnessForge.Graphiti.CompletionCommitment.digest(envelope),
               true <- digest == ref["completion_digest"],
               :ok <- completion_committed(auth, cap),
               do: :ok,
               else: (_ -> {:error, :closure_incomplete})

        state =
          if result == :ok,
            do: state,
            else: retire_cancelled_or_fence(state, auth.partition_id, auth.worker_session_id)

        state = discard_completion(state, auth.partition_id)

        case Map.pop(state.sessions, auth.worker_session_id) do
          {nil, _} ->
            {:reply, result, state}

          {session, sessions} ->
            Process.demonitor(session.monitor, [:flush])
            {:reply, result, %{state | sessions: sessions}}
        end

      _ ->
        {:reply, {:error, :closure_incomplete}, state}
    end
  end

  def handle_call(_, _from, state), do: {:reply, {:error, :scope_denied}, state}

  @impl true
  def handle_info({port, event}, state) when is_port(port) do
    case Enum.find(state.backends, fn {_, b} -> b.watcher == port end) do
      {partition, _} when event == :eof or elem(event, 0) in [:data, :exit_status] ->
        fence_backend(partition)
        Pipe.close(port)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, state) do
    case Enum.find(state.observations, fn {_, observation} -> observation.monitor == ref end) do
      {operation, observation} ->
        :ets.delete(@live, {:observation, operation})
        state = %{state | observations: Map.delete(state.observations, operation)}

        {:noreply, retire_cancelled_or_fence(state, observation.partition, observation.session)}

      nil ->
        case Enum.find(state.completions, fn {_, cap} -> cap.monitor == ref end) do
          {partition, cap} ->
            state = retire_cancelled_or_fence(state, partition, cap.session)
            {:noreply, discard_completion(state, partition)}

          nil ->
            session_down(ref, state)
        end
    end
  end

  def handle_info({:clear_partition_memory, partition}, state) do
    state =
      Enum.reduce(state.sessions, state, fn {_, session}, acc ->
        if session.partition == partition and cancelled_search?(session),
          do: retire_cancelled_search(acc, session),
          else: acc
      end)

    sessions =
      Map.new(state.sessions, fn {id, session} ->
        if session.partition == partition do
          if operation = Map.get(session, :operation) do
            :ets.delete(@live, {:job_base, operation})
            :ets.delete(@live, {:search_prepared, operation})
          end

          {id,
           session
           |> Map.put(:search_query, nil)
           |> Map.put(:projections, %{})
           |> Map.put(:transcript, ReplayTranscript.new())}
        else
          {id, session}
        end
      end)

    state = %{state | sessions: sessions}
    {:noreply, discard_completion(state, partition)}
  end

  def handle_info({:clear_corpus_memory, corpus}, state) do
    for {partition, backend} <- state.backends,
        backend.scope["corpus_id"] == corpus,
        do: forget_partition(partition)

    {:noreply, state}
  end

  def handle_info(:expire_execution_memory, state) do
    now = Store.now()

    for {_, session} <- state.sessions,
        deadline = Map.get(session, :deadline_at),
        not is_nil(deadline),
        not Map.get(session, :retiring, false),
        DateTime.compare(deadline, now) != :gt,
        do: forget_partition(session.partition)

    Process.send_after(self(), :expire_execution_memory, 1000)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp cancelled_search?(%{retirement_failed: true}), do: false

  defp cancelled_search?(%{read_only: true} = session) do
    with {:ok, %{rows: [["cancelled", epoch]]}} <-
           Repo.query(
             "SELECT state,cancel_epoch FROM stage_operations WHERE workspace_id=? AND id=? AND partition_id=? AND worker_session_id=? AND lease_id=? AND operation_type='search'",
             [Store.workspace(), session.operation, session.partition, session.id, session.lease]
           ),
         true <- epoch == session.search_epoch + 1,
         do: true,
         else: (_ -> false)
  end

  defp cancelled_search?(_), do: false

  # A callback/DOWN can beat the asynchronous cancellation erasure notice.
  # Classify only its exact private session; retirement still independently
  # checks the source closure, pinned base and backend before preserving it.
  defp retire_cancelled_or_fence(state, partition, session_id) do
    session = state.sessions[session_id]

    if not is_nil(session) and session.partition == partition and cancelled_search?(session) do
      retire_cancelled_search(state, session)
    else
      fence_backend(partition)
      state
    end
  end

  # Only a prepared, pinned read-only session with an exact durable cancellation
  # reaches this path. Unknown writes, source changes and backend loss still fence.
  defp retire_cancelled_search(state, session) do
    :ets.delete(@live, {:session, session.id})

    for key <- [:job, :job_base, :search_prepared, :observation],
        do: :ets.delete(@live, {key, session.operation})

    state = discard_completion(state, session.partition)

    if observation = state.observations[session.operation],
      do: Process.demonitor(observation.monitor, [:flush])

    state = %{state | observations: Map.delete(state.observations, session.operation)}

    # Accounting belongs to the captured session even when source/backend
    # checks refuse graph preservation. Its revoked ETS identity is no longer
    # discoverable by fallback fencing, so settle it before those checks.
    settlement =
      Store.transaction(fn ->
        with :ok <-
               settle_owned_attempts(%{
                 operation: session.operation,
                 partition: session.partition,
                 session: session.id
               }),
             do: {:ok, :settled}
      end)

    backend = state.backends[session.partition]

    outcome =
      with true <- cancelled_search?(session),
           {:ok, :settled} <- settlement,
           :ok <- backend_current(backend),
           :ok <- Backend.inspect_current(backend),
           {:ok, configuration} <-
             HarnessForge.Evidence.GraphManifests.inventory_configuration_current(
               session.partition
             ),
           true <-
             configuration["base_inventory"] == session.base_inventory and
               configuration["stage_set_digest"] == session.stage_set_digest,
           :ok <-
             Backend.remove_worker(
               backend.endpoint,
               session.container_id,
               session.partition,
               session.id
             ),
           :ok <- Pipe.close(session.port),
           backend = %{backend | writer_ids: []},
           :ok <- Backend.inspect_current(backend),
           :ok <- backend_current(backend),
           {:ok, final} <-
             HarnessForge.Evidence.GraphManifests.inventory_configuration_current(
               session.partition
             ),
           true <- final == configuration,
           {:ok, _} <-
             Repo.query(
               "UPDATE graph_worker_sessions SET state='stopped',updated_at=? WHERE workspace_id=? AND id=? AND operation_id=? AND state IN('bound','stopped')",
               [now(), Store.workspace(), session.id, session.operation]
             ),
           do: {:ok, backend},
           else: (_ -> {:error, :reconcile_required})

    case outcome do
      {:ok, backend} ->
        Process.demonitor(session.monitor, [:flush])
        if Process.alive?(session.pid), do: Process.exit(session.pid, :shutdown)

        %{
          state
          | sessions: Map.delete(state.sessions, session.id),
            backends: Map.put(state.backends, session.partition, backend)
        }

      _ ->
        fence_backend(session.partition)
        Pipe.close(session.port)

        # Keep the unknown resource identity for explicit reconciliation, but
        # never re-enter this failed retirement from its own erasure notice.
        failed =
          session
          |> Map.put(:retirement_failed, true)
          |> Map.put(:search_query, nil)
          |> Map.put(:projections, %{})
          |> Map.put(:transcript, ReplayTranscript.new())

        put_in(state.sessions[session.id], failed)
    end
  end

  defp session_down(ref, state) do
    case Enum.find(state.sessions, fn {_, s} -> s.monitor == ref end) do
      nil ->
        {:noreply, state}

      {id, session} ->
        if cancelled_search?(session) do
          {:noreply, retire_cancelled_search(state, session)}
        else
          fence_backend(session.partition)

          Repo.query(
            "UPDATE graph_worker_sessions SET state='uncertain',updated_at=? WHERE workspace_id=? AND id=?",
            [now(), Store.workspace(), id]
          )

          # Do not grant a replacement lease: the old container may still exist.
          {:noreply, state}
        end
    end
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  defp reserve_backend(partition, caller) do
    HarnessForge.Privacy.Purge.synchronize(fn ->
      Store.transaction(fn ->
        with :ok <- authorize(caller),
             {:ok, %{rows: [[corpus, group, sem, access]]}} <-
               Repo.query(
                 "SELECT corpus_id,group_id,semantic_generation,authorization_generation FROM graph_partition_controls WHERE workspace_id=? AND id=? AND state='staging' AND backend_pin_digest IS NULL AND authority_json IS NULL",
                 [Store.workspace(), partition]
               ),
             :ok <- Corpora.assert_current(corpus, sem, access),
             instance = Ecto.UUID.generate(),
             {:ok, _} <-
               Repo.query(
                 "INSERT INTO graph_runtime_backends(workspace_id,partition_id,instance_id,state,inserted_at,updated_at) VALUES(?,?,?,'provisioning',?,?)",
                 [Store.workspace(), partition, instance, now(), now()]
               ) do
          {:ok,
           %{
             "partition_id" => partition,
             "corpus_id" => corpus,
             "group_id" => group,
             "semantic_generation" => sem,
             "authorization_generation" => access,
             "instance_id" => instance
           }}
        else
          _ -> {:error, :scope_denied}
        end
      end)
    end)
  end

  defp launch_worker(backend, pins, stage_set) do
    id = Ecto.UUID.generate()
    spec = Map.put(backend.spec, "session_id", id)
    root = Application.app_dir(:harness_forge, "priv/graphiti_worker")

    boot = %{
      "source_lock_digest" => Store.hash(File.read!(Path.join(root, "source.lock.json"))),
      "backend_pin_digest" => Contracts.digest(backend.bundle),
      "backend_uri" => backend.credentials["uri"],
      "backend_user" => backend.credentials["user"],
      "backend_password" => backend.credentials["password"],
      "database" => backend.credentials["database"],
      "stage_pins" => pins,
      "stage_set_digest" => stage_set
    }

    with {:ok, args} <- LaunchProfile.worker_args(spec),
         {:ok, output} <- Backend.command(backend.endpoint, args),
         container = String.trim(output),
         true <- Stages.digest?(container),
         {:ok, _} <-
           Repo.query(
             "INSERT INTO graph_worker_sessions(id,workspace_id,partition_id,container_id,image_id,source_digest,boot_digest,stage_set_digest,profile_digest,network_id,state,inserted_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,'launching',?,?)",
             [
               id,
               Store.workspace(),
               spec["partition_id"],
               container,
               spec["worker_image"],
               backend.image["source_digest"],
               Contracts.digest(boot),
               stage_set,
               Contracts.digest(elem(LaunchProfile.worker_profile(spec), 1)),
               spec["network_id"],
               now(),
               now()
             ]
           ),
         {:ok, port} <- Pipe.attach(backend.endpoint, container) do
      with {:ok, actual} <- running(backend.endpoint, container, 40),
           {:ok, receipt} <- LaunchProfile.verify_worker(spec, actual),
           {:ok, pid} <- Worker.start_link(port: port, session_id: id, boot: boot),
           {:ok, identity} <- worker_ready(pid, System.monotonic_time(:millisecond) + 10_000),
           true <-
             identity == %{
               "session_id" => id,
               "boot_digest" => Contracts.digest(boot),
               "source_lock_digest" => boot["source_lock_digest"],
               "backend_pin_digest" => boot["backend_pin_digest"],
               "stage_set_digest" => stage_set
             },
           {:ok, _guardian} <- guard_worker(self(), pid, backend.endpoint, container),
           {:ok, %{num_rows: 1}} <-
             Repo.query(
               "UPDATE graph_worker_sessions SET state='ready',updated_at=? WHERE workspace_id=? AND id=? AND state='launching'",
               [now(), Store.workspace(), id]
             ) do
        {:ok,
         %{
           id: id,
           partition: spec["partition_id"],
           pid: pid,
           port: port,
           monitor: Process.monitor(pid),
           container_id: container,
           receipt: receipt,
           stage_set_digest: stage_set,
           operation: nil,
           lease: nil,
           token_hash: nil
         }}
      else
        _ ->
          Pipe.close(port)
          Backend.command(backend.endpoint, ["rm", "-f", container])

          Repo.query(
            "UPDATE graph_worker_sessions SET state='uncertain',updated_at=? WHERE workspace_id=? AND id=?",
            [now(), Store.workspace(), id]
          )

          {:error, :worker_lost}
      end
    else
      _ -> {:error, :worker_lost}
    end
  end

  defp backend_current(backend) do
    with {:ok, %{rows: [["verified", digest, reference]]}} <-
           Repo.query(
             "SELECT state,bundle_digest,qualification_ref FROM graph_runtime_backends WHERE workspace_id=? AND partition_id=?",
             [Store.workspace(), backend.scope["partition_id"]]
           ),
         true <-
           digest == Contracts.digest(backend.bundle) and reference == backend.qualification_ref,
         :ok <-
           Corpora.assert_current(
             backend.scope["corpus_id"],
             backend.scope["semantic_generation"],
             backend.scope["authorization_generation"]
           ),
         do: :ok,
         else: (_ -> {:error, :reconcile_required})
  end

  defp guard_worker(owner, worker, endpoint, container) do
    Task.Supervisor.start_child(HarnessForge.Tasks, fn ->
      owner_ref = Process.monitor(owner)
      worker_ref = Process.monitor(worker)

      receive do
        {:DOWN, ^owner_ref, :process, _, _} ->
          Process.exit(worker, :kill)
          Backend.command(endpoint, ["rm", "-f", container], 35_000)

        {:DOWN, ^worker_ref, :process, _, _} ->
          :ok
      end
    end)
  end

  defp reconcile_owner_loss do
    case Repo.query(
           "SELECT name FROM sqlite_master WHERE type='table' AND name='graph_runtime_backends'",
           []
         ) do
      {:ok, %{rows: [[_]]}} ->
        Repo.query!(
          "UPDATE graph_worker_sessions SET state='uncertain',updated_at=? WHERE workspace_id=? AND state IN('launching','ready','bound')",
          [now(), Store.workspace()]
        )

        Repo.query!(
          "UPDATE graph_runtime_backends SET state='reconcile_required',updated_at=? WHERE workspace_id=? AND state!='stopped'",
          [now(), Store.workspace()]
        )

        Repo.query!(
          "UPDATE graph_partition_controls SET state='reconcile_required',lock_version=lock_version+1,cancel_epoch=cancel_epoch+1,updated_at=? WHERE workspace_id=? AND id IN(SELECT partition_id FROM graph_runtime_backends WHERE workspace_id=? AND state='reconcile_required')",
          [now(), Store.workspace(), Store.workspace()]
        )

      _ ->
        :ok
    end
  end

  defp stop_processes(state, partition) do
    Enum.each(state.sessions, fn {_, session} ->
      if session.partition == partition do
        Process.demonitor(session.monitor, [:flush])
        if Process.alive?(session.pid), do: GenServer.stop(session.pid, :normal, 5_000)
        Pipe.close(session.port)
      end
    end)

    :ok
  catch
    :exit, _ -> {:error, :reconcile_required}
  end

  defp close_watcher(nil), do: :ok
  defp close_watcher(backend), do: Pipe.close(backend.watcher)

  defp cleanup_sessions(endpoint, partition) do
    with {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT id,container_id FROM graph_worker_sessions WHERE workspace_id=? AND partition_id=? AND state!='stopped' ORDER BY id LIMIT 100",
             [Store.workspace(), partition]
           ),
         :ok <-
           Enum.reduce_while(rows, :ok, fn [session, container], :ok ->
             with :ok <- Backend.remove_worker(endpoint, container, partition, session),
                  {:ok, %{num_rows: 1}} <-
                    Repo.query(
                      "UPDATE graph_worker_sessions SET state='stopped',updated_at=? WHERE workspace_id=? AND id=?",
                      [now(), Store.workspace(), session]
                    ) do
               {:cont, :ok}
             else
               _ -> {:halt, {:error, :reconcile_required}}
             end
           end) do
      if length(rows) == 100, do: cleanup_sessions(endpoint, partition), else: :ok
    end
  end

  defp cleanup_backend(endpoint, partition) do
    case Repo.query(
           "SELECT resource_json FROM graph_runtime_backends WHERE workspace_id=? AND partition_id=?",
           [Store.workspace(), partition]
         ) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: [[nil]]}} ->
        :ok

      {:ok, %{rows: [[json]]}} ->
        with {:ok, resources} <- Jason.decode(json),
             true <- resources["partition_id"] == partition,
             :ok <- Backend.cleanup(endpoint, resources),
             do: :ok,
             else: (_ -> {:error, :reconcile_required})

      _ ->
        {:error, :reconcile_required}
    end
  end

  defp running(_, _, 0), do: {:error, :worker_lost}

  defp running(endpoint, id, n) do
    case Backend.inspection(endpoint, ["inspect", id]) do
      {:ok, %{"State" => %{"Running" => true}} = actual} ->
        {:ok, actual}

      _ ->
        Process.sleep(25)
        running(endpoint, id, n - 1)
    end
  end

  defp worker_ready(pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline or not Process.alive?(pid) do
      {:error, :worker_lost}
    else
      case Worker.identity(pid) do
        {:ok, _} = result ->
          result

        _ ->
          Process.sleep(25)
          worker_ready(pid, deadline)
      end
    end
  catch
    :exit, _ -> {:error, :worker_lost}
  end

  defp fence_backend(partition) do
    # Admission can already own the sole SQLite connection. Its live check
    # must never wait on this owner's Docker/DB work or privacy lock. These
    # protected owner-lifetime records contain only hashes/handles, no secrets;
    # durable checks still run in the caller's own transaction.
    if live_owner?() do
      :ets.delete(@live, {:backend, partition})

      for {{:completion, id}, %{partition: ^partition} = cap} <- :ets.tab2list(@live) do
        # Revoke before SQL: its publisher may currently hold the only connection.
        :ets.delete(@live, {:completion, id})
        terminalize_owned_operation_failure(cap)
      end

      for {{:session, id}, %{partition: ^partition} = session} <- :ets.tab2list(@live) do
        :ets.delete(@live, {:session, id})
        :ets.delete(@live, {:job, session.operation})
        :ets.delete(@live, {:job_base, session.operation})
        :ets.delete(@live, {:search_prepared, session.operation})
        :ets.delete(@live, {:observation, session.operation})

        terminalize_owned_operation_failure(%{
          operation: session.operation,
          partition: partition,
          session: id
        })
      end
    end

    Repo.query(
      "UPDATE graph_runtime_backends SET state='reconcile_required',updated_at=? WHERE workspace_id=? AND partition_id=? AND state!='stopped'",
      [now(), Store.workspace(), partition]
    )

    Repo.query(
      "UPDATE graph_partition_controls SET state='reconcile_required',lock_version=lock_version+1,updated_at=? WHERE workspace_id=? AND id=? AND state!='denied'",
      [now(), Store.workspace(), partition]
    )

    forget_partition(partition)
    :ok
  end

  # Only the live owner's protected session or completion record reaches here.
  # It names one authenticated operation/session, not a caller-supplied target.
  # Preserve committed/cancelled states and all settled request usage. Unknown
  # graph writes require reconciliation, not an indefinitely active operation.
  defp terminalize_owned_operation_failure(cap) do
    Store.transaction(fn ->
      with :ok <- settle_owned_attempts(cap),
           {:ok, _} <-
             Repo.query(
               "UPDATE stage_operations SET state='uncertain',cancel_epoch=cancel_epoch+1,updated_at=? WHERE workspace_id=? AND id=? AND partition_id=? AND worker_session_id=? AND state='active'",
               [now(), Store.workspace(), cap.operation, cap.partition, cap.session]
             ),
           do: {:ok, :terminalized}
    end)
  end

  # Caller owns the transaction and has already revoked live execution. A
  # disappearing task cannot report whether its sent request completed. Keep
  # reservations and every recorded usage/billing fact; revoke only unfinished
  # grants belonging to this exact protected operation/partition/session.
  defp settle_owned_attempts(cap) do
    scope = [Store.workspace(), cap.operation, cap.partition, cap.session]

    with {:ok, _} <-
           Repo.query(
             "UPDATE model_requests SET state='uncertain',updated_at=? WHERE workspace_id=? AND state IN('reserved','dispatched') AND id IN(SELECT a.model_request_id FROM stage_attempts a JOIN stage_operations o ON o.workspace_id=a.workspace_id AND o.id=a.operation_id WHERE o.workspace_id=? AND o.id=? AND o.partition_id=? AND o.worker_session_id=? AND a.state IN('reserved','dispatched'))",
             [now(), Store.workspace()] ++ scope
           ),
         {:ok, _} <-
           Repo.query(
             "UPDATE stage_attempts SET state='uncertain',grant_hash=NULL,updated_at=? WHERE workspace_id=? AND operation_id=? AND state IN('reserved','dispatched') AND EXISTS(SELECT 1 FROM stage_operations o WHERE o.workspace_id=? AND o.id=? AND o.partition_id=? AND o.worker_session_id=?)",
             [now(), Store.workspace(), cap.operation] ++ scope
           ),
         do: :ok
  end

  defp public_backend(backend),
    do: %{
      "partition_id" => backend.scope["partition_id"],
      "backend_pin_digest" => Contracts.digest(backend.bundle),
      "qualification_ref" => backend.qualification_ref,
      "state" => "verified",
      "profile" => "empty_custom_attributes_only"
    }

  defp active_observation(auth, page) do
    with [{{:observation, _}, observation}] <-
           :ets.lookup(@live, {:observation, auth.operation_id}),
         true <-
           observation.pid == self() and observation.partition == auth.partition_id and
             observation.session == auth.worker_session_id and
             observation.digest == Protocol.context_page_digest(page),
         do: :ok,
         else: (_ -> {:error, :scope_denied})
  end

  defp retain_projection(state, auth, job, page, {:ok, ack}) do
    with :ok <- observation_current(auth, job),
         {:ok, ^ack} <- HarnessForge.Graphiti.ObservationLedger.lookup(auth, page),
         true <- ack["state"] == "sealed" do
      session = state.sessions[auth.worker_session_id]
      context = ack["context_manifest_ref"]

      cond do
        MapSet.member?(session.seen_contexts, context) ->
          {:ok, state}

        MapSet.size(session.seen_contexts) >= 4096 ->
          {:error, :response_limit}

        true ->
          with {:ok, transcript} <- ReplayTranscript.retain_page(session.transcript, page),
               true <- page["phase"] != "attempt_bind" or map_size(session.projections) < 3 do
            projections =
              if page["phase"] == "attempt_bind" do
                projection = %{
                  "operation_id" => auth.operation_id,
                  "stage_id" => page["stage_id"],
                  "logical_call_id" => page["logical_call_id"],
                  "prompt_name" => page["prompt_name"],
                  "body_hash" => page["raw_body_sha256"],
                  "manifest_digest" => ack["context_manifest_digest"],
                  "values" => Enum.map(page["entries"], & &1["value"])
                }

                Map.put(session.projections, context, projection)
              else
                session.projections
              end

            session = %{
              session
              | projections: projections,
                transcript: transcript,
                seen_contexts: MapSet.put(session.seen_contexts, context)
            }

            {:ok, put_in(state.sessions[auth.worker_session_id], session)}
          else
            _ -> {:error, :closure_incomplete}
          end
      end
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp retain_projection(_, _, _, _, _), do: {:error, :closure_incomplete}

  defp saved_objects(page) do
    types = ~w(EpisodicNode EntityNode EntityEdge EpisodicEdge)

    objects =
      for entry <- page["entries"],
          value = entry["value"],
          is_map(value),
          value["object_type"] in types,
          do: value

    identities = Enum.map(objects, &{&1["object_type"], get_in(&1, ["fields", "uuid"])})

    if objects != [] and length(objects) <= 100 and
         length(identities) == length(Enum.uniq(identities)),
       do: {:ok, objects},
       else: {:error, :closure_incomplete}
  end

  defp match_saved_objects(auth, objects) do
    types = %{
      "EpisodicNode" => "episode",
      "EntityNode" => "entity",
      "EntityEdge" => "edge",
      "EpisodicEdge" => "mention"
    }

    with {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM stage_attempts WHERE workspace_id=? AND operation_id=? AND state IN('reserved','dispatched')",
             [Store.workspace(), auth.operation_id]
           ) do
      objects
      |> Enum.group_by(& &1["object_type"])
      |> Enum.reduce_while(:ok, fn {type, values}, :ok ->
        outcome =
          values
          |> Enum.chunk_every(10)
          |> Enum.reduce_while(:ok, fn chunk, :ok ->
            ids = Enum.map(chunk, &get_in(&1, ["fields", "uuid"]))

            query = %{
              "action" => "objects",
              "kind" => types[type],
              "cursor" => nil,
              "limit" => length(ids),
              "object_ids" => ids
            }

            with true <- Enum.all?(ids, &Corpora.uuid?/1),
                 {:ok, measured} <- inventory(auth, query),
                 records = measured["result"]["records"],
                 true <-
                   Map.new(records, &{&1["fields"]["uuid"], &1}) ==
                     Map.new(chunk, &{&1["fields"]["uuid"], &1}),
                 do: {:cont, :ok},
                 else: (_ -> {:halt, {:error, :closure_incomplete}})
          end)

        if outcome == :ok, do: {:cont, :ok}, else: {:halt, outcome}
      end)
    else
      _ -> {:error, :closure_incomplete}
    end
  end

  defp completion_authority(auth),
    do:
      Contracts.digest(%{
        "workspace" => auth.workspace_id,
        "operation" => auth.operation_id,
        "partition" => auth.partition_id,
        "session" => auth.worker_session_id,
        "lease" => auth.lease_id,
        "control" => Store.hash(auth.control_token),
        "launch" => Store.hash(auth.launch_token),
        "source" => auth.manifest_id,
        "source_digest" => auth.manifest_digest,
        "source_lock" => auth.source_lock_digest,
        "corpus" => auth.corpus_id,
        "scope" => auth.scope_ref,
        "deadline" => DateTime.to_iso8601(auth.deadline_at),
        "caller" =>
          Contracts.digest(
            Map.new(
              Keyword.take(auth.caller, [:session_fingerprint, :view_generation, :reset_token]),
              fn {key, value} -> {Atom.to_string(key), value} end
            )
          ),
        "stages" => StageAuthority.stage_set_digest(auth),
        "backend" => auth.backend_pin_digest,
        "semantic" => auth.semantic_generation,
        "access" => auth.authorization_generation,
        "epoch" => auth.cancel_epoch,
        "lock" => auth.partition_lock_version
      })

  defp completion_cap(auth, ref, pid) do
    with true <- live_owner?(),
         [{{:completion, _}, cap}] <- :ets.lookup(@live, {:completion, ref["id"]}),
         true <-
           cap.ref == ref and cap.pid == pid and cap.partition == auth.partition_id and
             cap.authority == completion_authority(auth) and cap.phase == :measuring and
             Process.alive?(pid) and Process.alive?(cap.worker) and
             not is_nil(Port.info(cap.watcher)),
         do: {:ok, cap},
         else: (_ -> {:error, :closure_incomplete})
  rescue
    _ -> {:error, :closure_incomplete}
  end

  defp private_job_base(auth, digest) do
    case :ets.lookup(@live, {:job_base, auth.operation_id}) do
      [{{:job_base, _}, cached}] ->
        with true <- cached.authority == completion_authority(auth) and cached.digest == digest,
             :ok <- current(auth),
             do: {:ok, cached.base, "bound"},
             else: (_ -> {:error, :closure_incomplete})

      [] ->
        # Execution slots were erased at writer retirement. Only this exact
        # publisher's live completion cap can expose the same captured base.
        case Enum.filter(:ets.match_object(@live, {{:completion, :_}, :_}), fn {_, cap} ->
               cap.operation == auth.operation_id and cap.ref["job_digest"] == digest
             end) do
          [{_, cap}] ->
            with {:ok, _} <- completion_cap(auth, cap.ref, self()),
                 do: {:ok, cap.ref["base_inventory"], "stopped"},
                 else: (_ -> {:error, :closure_incomplete})

          _ ->
            {:error, :closure_incomplete}
        end

      _ ->
        {:error, :closure_incomplete}
    end
  end

  defp base_shape?(base) do
    is_map(base) and
      Enum.sort(Map.keys(base)) ==
        ~w(inventory_manifest_digest inventory_manifest_id inventory_revision) and
      is_integer(base["inventory_revision"]) and base["inventory_revision"] >= 0 and
      base["inventory_revision"] < 9_007_199_254_740_991 and
      if(base["inventory_revision"] == 0,
        do: is_nil(base["inventory_manifest_id"]) and is_nil(base["inventory_manifest_digest"]),
        else:
          Corpora.uuid?(base["inventory_manifest_id"]) and
            Stages.digest?(base["inventory_manifest_digest"])
      )
  end

  defp base_pointer_current(auth, base, session_state) do
    with true <- base_shape?(base),
         :ok <- authorize(auth.caller),
         {:ok, _} <- StageControl.graph_current(auth),
         expected_state = if(auth.operation_type == "search", do: "ready", else: "staging"),
         {:ok,
          %{
            rows: [
              [revision, manifest, digest, ^expected_state, "verified", backend, ^session_state]
            ]
          }} <-
           Repo.query(
             "SELECT p.inventory_revision,p.inventory_manifest_id,p.inventory_manifest_digest,p.state,b.state,b.bundle_digest,s.state FROM graph_partition_controls p JOIN graph_runtime_backends b ON b.workspace_id=p.workspace_id AND b.partition_id=p.id JOIN graph_worker_sessions s ON s.workspace_id=p.workspace_id AND s.partition_id=p.id WHERE p.workspace_id=? AND p.id=? AND s.id=?",
             [Store.workspace(), auth.partition_id, auth.worker_session_id]
           ),
         true <-
           backend == auth.backend_pin_digest and
             base == %{
               "inventory_revision" => revision,
               "inventory_manifest_id" => manifest,
               "inventory_manifest_digest" => digest
             },
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp completion_local_current(auth, ref, pid) do
    with {:ok, _cap} <- completion_cap(auth, ref, pid),
         true <-
           base_shape?(ref["base_inventory"]) and
             ref["inventory_revision"] == ref["base_inventory"]["inventory_revision"],
         :ok <- base_pointer_current(auth, ref["base_inventory"], "stopped"),
         {:ok, _} <-
           HarnessForge.Evidence.GraphManifests.validate_scope_certificate(
             auth.manifest_id,
             auth.manifest_digest,
             auth
           ),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp validate_job_intent(%StageAuthority{operation_type: "ingest"} = auth, job, _),
    do: IngestIntent.validate(auth, job)

  defp validate_job_intent(%StageAuthority{operation_type: "search"} = auth, job, :prepared),
    do: SearchIntent.validate_prepared(auth, job)

  defp validate_job_intent(%StageAuthority{operation_type: "search"} = auth, job, :current),
    do: SearchIntent.validate_current(auth, job)

  defp validate_job_intent(_, _, _), do: {:error, :closure_incomplete}

  defp capture_job_base(%StageAuthority{operation_type: "ingest"} = auth, job),
    do: capture_ingest_base(auth, job)

  defp capture_job_base(%StageAuthority{operation_type: "search"} = auth, _job),
    do: search_prepared(auth)

  defp capture_job_base(_, _), do: {:error, :closure_incomplete}

  defp capture_search_pointer(auth) do
    with {:ok, %{rows: [[n, id, digest]]}} <-
           Repo.query(
             "SELECT inventory_revision,inventory_manifest_id,inventory_manifest_digest FROM graph_partition_controls WHERE workspace_id=? AND id=? AND state='ready' AND inventory_revision>0 AND NOT EXISTS(SELECT 1 FROM graph_episode_bindings e WHERE e.workspace_id=graph_partition_controls.workspace_id AND e.partition_id=graph_partition_controls.id AND e.state!='ready')",
             [Store.workspace(), auth.partition_id]
           ),
         base = %{
           "inventory_revision" => n,
           "inventory_manifest_id" => id,
           "inventory_manifest_digest" => digest
         },
         :ok <- base_pointer_current(auth, base, "bound"),
         do: {:ok, base},
         else: (_ -> {:error, :closure_incomplete})
  end

  defp capture_ingest_base(auth, job) do
    with true <- auth.operation_type == "ingest",
         {:ok, %{rows: [[n, manifest, digest]]}} <-
           Repo.query(
             "SELECT inventory_revision,inventory_manifest_id,inventory_manifest_digest FROM graph_partition_controls WHERE workspace_id=? AND id=?",
             [Store.workspace(), auth.partition_id]
           ),
         base = %{
           "inventory_revision" => n,
           "inventory_manifest_id" => manifest,
           "inventory_manifest_digest" => digest
         },
         :ok <- base_pointer_current(auth, base, "bound"),
         {:ok, _} <- HarnessForge.Evidence.GraphManifests.inventory_parent(base, auth),
         :ok <- append_members_current(auth, job, base),
         do: {:ok, base},
         else: (_ -> {:error, :closure_incomplete})
  end

  defp append_members_current(auth, job, base) do
    n = base["inventory_revision"]

    with {:ok, %{rows: [[total, 1, ^n, generations]]}} <-
           Repo.query(
             "SELECT count(*),sum(CASE WHEN id=? AND state IN('staging','indexing') AND publication_generation IS NULL THEN 1 ELSE 0 END),sum(CASE WHEN state='ready' AND publication_generation BETWEEN 1 AND ? THEN 1 ELSE 0 END),count(DISTINCT CASE WHEN state='ready' THEN publication_generation END) FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=?",
             [job["args"]["binding_id"], n, Store.workspace(), auth.partition_id]
           ),
         true <- total == n + 1 and generations == n,
         {:ok, %{rows: previous}} <-
           Repo.query(
             "SELECT episode_uuid FROM graph_episode_bindings WHERE workspace_id=? AND partition_id=? AND state='ready' ORDER BY inserted_at DESC,id DESC LIMIT 24",
             [Store.workspace(), auth.partition_id]
           ),
         true <- job["args"]["prior_episode_ids"] == previous |> Enum.reverse() |> Enum.map(&hd/1),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp fresh_ingest_intent(auth, job) do
    with {:ok, base} <- base_inventory(auth, job),
         :ok <- append_members_current(auth, job, base),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp completion_initial(%StageAuthority{operation_type: "search"} = auth, job, result) do
    with :ok <- SearchIntent.validate_current(auth, job),
         :ok <- HarnessForge.Graphiti.SearchCompletion.validate_request(auth, job, result),
         true <- result["receipt_count"] == 1,
         :ok <- completion_finished(auth),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp completion_initial(auth, job, result) do
    with :ok <- fresh_ingest_intent(auth, job),
         :ok <- Protocol.validate_payload("result", result),
         true <-
           result["state"] == "completed" and result["job_id"] == auth.operation_id and
             result["generation"] == auth.semantic_generation and
             result["closure_digest"] == auth.manifest_digest and
             result["result"] == Map.take(job["args"], ~w(binding_id episode_uuid)),
         :ok <- completion_finished(auth),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp completion_finished(auth) do
    with {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_calls WHERE workspace_id=? AND operation_id=? AND state!='finished'",
             [Store.workspace(), auth.operation_id]
           ),
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_observation_events WHERE workspace_id=? AND operation_id=? AND binding_state='unused'",
             [Store.workspace(), auth.operation_id]
           ),
         {:ok, %{rows: [[0]]}} <-
           Repo.query(
             "SELECT count(*) FROM graph_manifest_builds WHERE workspace_id=? AND json_extract(header_json,'$.execution_identity.operation_id')=? AND phase!='sealed'",
             [Store.workspace(), auth.operation_id]
           ),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp completion_receipts(auth, result, ids) do
    with true <- is_list(ids) and length(ids) in 1..256 and length(ids) == length(Enum.uniq(ids)),
         true <-
           result["receipt_count"] == length(ids) and
             result["receipt_digest"] == Contracts.digest(ids),
         {:ok, %{rows: rows}} <-
           Repo.query(
             "SELECT a.id,a.state,r.state,r.usage_status FROM stage_attempts a JOIN model_requests r ON r.workspace_id=a.workspace_id AND r.id=a.model_request_id WHERE a.workspace_id=? AND a.operation_id=? ORDER BY a.id LIMIT 257",
             [Store.workspace(), auth.operation_id]
           ),
         true <- length(rows) == length(ids) and Enum.sort(ids) == Enum.map(rows, &hd/1),
         true <-
           Enum.all?(rows, fn [_, a, r, usage] ->
             a == "completed" and r == "completed" and usage == "reported"
           end),
         true <-
           Enum.all?(ids, fn id ->
             match?(
               {:ok, %{rows: [[1]]}},
               Repo.query(
                 "SELECT count(*) FROM graph_observation_events e JOIN dependency_manifests m ON m.workspace_id=e.workspace_id AND m.id=e.manifest_id JOIN stage_attempts a ON a.workspace_id=e.workspace_id AND a.id=? JOIN model_requests r ON r.workspace_id=a.workspace_id AND r.id=a.model_request_id JOIN stage_configs p ON p.workspace_id=a.workspace_id AND p.id=a.stage_config_id WHERE e.workspace_id=? AND e.operation_id=? AND e.phase='derived' AND m.state='sealed' AND json_extract(m.context_json,'$.seam_id')='llm.response.v1' AND json_extract(m.context_json,'$.receipt_ref')=a.id AND json_extract(m.context_json,'$.receipt_digest')=a.result_hash AND json_extract(m.context_json,'$.operation_manifest_ref')=? AND r.request_id=a.id AND r.run_id=a.operation_id AND r.provider=json_extract(p.payload_json,'$.provider') AND r.model=json_extract(p.payload_json,'$.model') AND a.response_status BETWEEN 100 AND 599 AND a.response_bytes>=0",
                 [id, Store.workspace(), auth.operation_id, auth.manifest_id]
               )
             )
           end),
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp completion_committed(%StageAuthority{operation_type: "search"} = auth, cap) do
    base = cap.ref["base_inventory"]

    with :ok <- authorize(auth.caller),
         :ok <-
           Corpora.assert_current(
             auth.corpus_id,
             auth.semantic_generation,
             auth.authorization_generation
           ),
         {:ok,
          %{
            rows: [
              [
                "completed",
                digest,
                "ready",
                n,
                id,
                sha,
                "verified",
                backend,
                "stopped",
                job_hash,
                completion_hash
              ]
            ]
          }} <-
           Repo.query(
             "SELECT o.state,o.result_digest,p.state,p.inventory_revision,p.inventory_manifest_id,p.inventory_manifest_digest,b.state,b.bundle_digest,s.state,json_extract(v.value_json,'$.job_digest'),json_extract(v.value_json,'$.completion_digest') FROM stage_operations o JOIN graph_partition_controls p ON p.workspace_id=o.workspace_id AND p.id=o.partition_id JOIN graph_runtime_backends b ON b.workspace_id=p.workspace_id AND b.partition_id=p.id JOIN graph_worker_sessions s ON s.workspace_id=p.workspace_id AND s.id=o.worker_session_id JOIN graph_derivative_versions v ON v.workspace_id=o.workspace_id AND v.partition_id=p.id AND v.object_id=? AND v.state='published' AND v.version=1 AND v.predecessor_id IS NULL JOIN dependency_manifests m ON m.workspace_id=v.workspace_id AND m.id=v.manifest_id AND m.state='sealed' WHERE o.workspace_id=? AND o.id=? AND o.operation_type='search' AND o.control_token=? AND p.manifest_id=? AND p.semantic_generation=? AND p.authorization_generation=? AND p.cancel_epoch=? AND p.lock_version=? AND json_extract(v.value_json,'$.base_inventory.inventory_revision')=? AND json_extract(v.value_json,'$.base_inventory.inventory_manifest_id')=? AND json_extract(v.value_json,'$.base_inventory.inventory_manifest_digest')=?",
             [
               "root_search:" <> auth.operation_id,
               Store.workspace(),
               auth.operation_id,
               auth.control_token,
               auth.manifest_id,
               auth.semantic_generation,
               auth.authorization_generation,
               auth.cancel_epoch,
               auth.partition_lock_version,
               base["inventory_revision"],
               base["inventory_manifest_id"],
               base["inventory_manifest_digest"]
             ]
           ),
         true <-
           digest == cap.ref["completion_digest"] and job_hash == cap.ref["job_digest"] and
             completion_hash == digest and backend == auth.backend_pin_digest,
         true <-
           base == %{
             "inventory_revision" => n,
             "inventory_manifest_id" => id,
             "inventory_manifest_digest" => sha
           },
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp completion_committed(auth, cap) do
    ref = cap.ref
    expected_revision = ref["inventory_revision"] + 1

    with :ok <- authorize(auth.caller),
         :ok <-
           Corpora.assert_current(
             auth.corpus_id,
             auth.semantic_generation,
             auth.authorization_generation
           ),
         {:ok,
          %{
            rows: [
              [
                "completed",
                digest,
                "ready",
                ^expected_revision,
                "ready",
                ^expected_revision,
                "verified",
                backend,
                "stopped",
                "sealed",
                job_hash,
                completion_hash
              ]
            ]
          }} <-
           Repo.query(
             "SELECT o.state,o.result_digest,p.state,p.inventory_revision,e.state,e.publication_generation,b.state,b.bundle_digest,s.state,m.state,json_extract(v.value_json,'$.job_digest'),json_extract(v.value_json,'$.completion_digest') FROM stage_operations o JOIN graph_partition_controls p ON p.workspace_id=o.workspace_id AND p.id=o.partition_id JOIN graph_runtime_backends b ON b.workspace_id=p.workspace_id AND b.partition_id=p.id JOIN graph_worker_sessions s ON s.workspace_id=p.workspace_id AND s.id=o.worker_session_id JOIN graph_episode_bindings e ON e.workspace_id=p.workspace_id AND e.partition_id=p.id AND e.id=? JOIN dependency_manifests m ON m.workspace_id=p.workspace_id AND m.id=p.inventory_manifest_id AND m.digest=p.inventory_manifest_digest JOIN origin_dependencies d ON d.workspace_id=m.workspace_id AND d.manifest_id=m.id AND d.kind='deterministic_output' JOIN graph_derivative_versions v ON v.workspace_id=d.workspace_id AND v.id=d.derivative_version_id AND v.state='published' AND v.partition_id=p.id AND v.object_id=? WHERE o.workspace_id=? AND o.id=? AND o.control_token=? AND p.manifest_id=? AND p.semantic_generation=? AND p.authorization_generation=? AND p.cancel_epoch=? AND p.lock_version=? AND json_extract(m.context_json,'$.operation_manifest_ref')=?",
             [
               cap.binding,
               "root_completion:" <> auth.operation_id,
               Store.workspace(),
               auth.operation_id,
               auth.control_token,
               auth.manifest_id,
               auth.semantic_generation,
               auth.authorization_generation,
               auth.cancel_epoch,
               auth.partition_lock_version,
               auth.manifest_id
             ]
           ),
         true <-
           digest == ref["completion_digest"] and job_hash == ref["job_digest"] and
             completion_hash == digest and backend == auth.backend_pin_digest,
         do: :ok,
         else: (_ -> {:error, :closure_incomplete})
  end

  defp discard_completion(state, partition) do
    case Map.pop(state.completions, partition) do
      {nil, _} ->
        state

      {cap, completions} ->
        # Source-generation forgets also invalidate this owned completion.
        # Revoke before waiting for SQL; active-only CAS preserves a committed
        # completion, a cancellation, or an already terminalized failure.
        :ets.delete(@live, {:completion, cap.ref["id"]})
        terminalize_owned_operation_failure(cap)
        Process.demonitor(cap.monitor, [:flush])
        %{state | completions: completions}
    end
  end

  defp live_current(auth) do
    with true <- live_owner?(),
         [{{:session, _}, live}] <- :ets.lookup(@live, {:session, auth.worker_session_id}),
         true <-
           live.workspace == Store.workspace() and auth.workspace_id == live.workspace and
             live.partition == auth.partition_id and live.operation == auth.operation_id and
             live.lease == auth.lease_id,
         true <- is_binary(auth.launch_token) and live.token_hash == Store.hash(auth.launch_token),
         true <-
           Process.alive?(live.pid) and not is_nil(Port.info(live.port)) and
             not is_nil(Port.info(live.watcher)),
         true <-
           live.stages == StageAuthority.stage_set_digest(auth) and
             live.backend == auth.backend_pin_digest,
         do: :ok,
         else: (_ -> {:error, :worker_lost})
  rescue
    _ -> {:error, :worker_lost}
  end

  defp live_owner? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> :ets.info(@live, :owner) == pid and Process.alive?(pid)
    end
  end

  defp authorize(caller) do
    with :ok <- AssessmentAttempts.options(caller),
         :ok <- AssessmentAttempts.authorize(caller),
         :ok <- Workspaces.ensure_writable(),
         :ok <- HarnessForge.Privacy.Purge.ready(),
         do: :ok
  end

  defp call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _ -> {:error, :graph_unavailable}
  end

  # Long Docker/pipe operations must never run while the caller owns the only
  # SQLite connection. Scalar private checks do no DB I/O in this GenServer;
  # their durable checks run in the caller's transaction instead.
  defp outside_call(message, timeout) do
    if Repo.in_transaction?(),
      do: {:error, :transaction_boundary_required},
      else: call(message, timeout)
  end

  defp now, do: DateTime.to_iso8601(Store.now())
end
