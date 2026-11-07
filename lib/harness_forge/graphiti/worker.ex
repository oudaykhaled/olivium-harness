defmodule HarnessForge.Graphiti.Worker do
  @moduledoc "Private raw-port dispatcher. Root supplies/launches the isolated worker Port."
  use GenServer
  alias HarnessForge.Contracts
  alias HarnessForge.Graphiti.{CompletionCommitment, Protocol}
  alias HarnessForge.Models.{AttemptGateway, StageAuthority, Stages}

  @identity_keys ~w(session_id boot_digest source_lock_digest backend_pin_digest stage_set_digest)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def submit(server, job, authority), do: GenServer.call(server, {:submit, job, authority})

  def submit_and_await(server, job, authority, timeout),
    do: GenServer.call(server, {:submit_and_await, job, authority}, timeout)

  def await(server, job_id, timeout \\ 60_000),
    do: GenServer.call(server, {:await, job_id}, timeout)

  def status(server, job_id), do: GenServer.call(server, {:status, job_id})
  def cancel(server, job_id, epoch), do: GenServer.call(server, {:cancel, job_id, epoch})

  def prepare_runtime(server, request, timeout_ms) do
    GenServer.call(server, {:prepare_runtime, request, timeout_ms}, timeout_ms + 1_000)
  catch
    :exit, _ -> {:error, :stage_unavailable}
  end

  @doc "Return only the expected boot identity after the exact boot acknowledgement."
  def prepare_retirement(server, job_id, publisher, digest) do
    GenServer.call(server, {:prepare_retirement, job_id, publisher, digest})
  catch
    :exit, _ -> {:error, :closure_incomplete}
  end

  def identity(server) do
    GenServer.call(server, :identity)
  catch
    :exit, _ -> {:error, :stage_unavailable}
  end

  @doc false
  def validate_boot_result(expected_meta, request, result) do
    with true <- valid_boot_metadata?(expected_meta),
         true <- Stages.identifier?(request),
         :ok <- Protocol.validate_payload("result", result) do
      expected = %{
        "job_id" => request,
        "state" => "completed",
        "generation" => 0,
        "closure_digest" => expected_meta["stage_set_digest"],
        "receipt_count" => 0,
        "receipt_digest" => Contracts.digest([]),
        "result" => %{
          "version" => "0.31.2",
          "source_lock_digest" => expected_meta["source_lock_digest"],
          "backend_pin_digest" => expected_meta["backend_pin_digest"],
          "readiness" => "configured"
        }
      }

      if result === expected, do: :ok, else: {:error, :stage_unavailable}
    else
      _ -> {:error, :stage_unavailable}
    end
  rescue
    _ -> {:error, :stage_unavailable}
  end

  defp valid_boot_metadata?(meta) when is_map(meta) do
    Enum.sort(Map.keys(meta)) == Enum.sort(@identity_keys) and
      Stages.identifier?(meta["session_id"]) and
      Enum.all?(
        ~w(boot_digest source_lock_digest backend_pin_digest stage_set_digest),
        &Stages.digest?(meta[&1])
      )
  end

  defp valid_boot_metadata?(_), do: false

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    port = Keyword.fetch!(opts, :port)
    session = Keyword.fetch!(opts, :session_id)
    boot = Keyword.fetch!(opts, :boot)

    with true <- is_port(port),
         :ok <- Protocol.validate_payload("boot", boot),
         true <- HarnessForge.Models.Stages.identifier?(session),
         true <- Port.connect(port, self()) do
      state = %{
        port: port,
        session: session,
        input_seq: 0,
        output_seq: 0,
        buffer: <<>>,
        boot_request: Ecto.UUID.generate(),
        boot_identity: %{
          "session_id" => session,
          "boot_digest" => Contracts.digest(boot),
          "source_lock_digest" => boot["source_lock_digest"],
          "backend_pin_digest" => boot["backend_pin_digest"],
          "stage_set_digest" => boot["stage_set_digest"]
        },
        ready: false,
        preparation: nil,
        prepared: nil,
        preparation_used: false,
        retirement: nil,
        jobs: %{},
        requests: %{},
        attempts: %{},
        contexts: %{},
        context_grants: %{},
        tasks: %{},
        task_pids: %{},
        order: []
      }

      case send_frame(state, "boot", state.boot_request, boot) do
        {:ok, updated} -> {:ok, updated}
        error -> {:stop, error}
      end
    else
      _ -> {:stop, :invalid_worker_configuration}
    end
  end

  @impl true
  def handle_call(:identity, _from, %{ready: true, boot_identity: meta} = state) do
    if valid_boot_metadata?(meta),
      do: {:reply, {:ok, meta}, state},
      else: {:reply, {:error, :stage_unavailable}, state}
  end

  def handle_call(:identity, _from, state),
    do: {:reply, {:error, :stage_unavailable}, state}

  def handle_call({:prepare_runtime, request, timeout}, {caller, _} = from, state) do
    with true <- caller == Process.whereis(HarnessForge.Graphiti.Runtime),
         true <- state.ready and not state.preparation_used and is_nil(state.retirement),
         true <-
           Enum.all?(
             [state.jobs, state.requests, state.attempts, state.contexts, state.tasks],
             &(map_size(&1) == 0)
           ),
         true <- Stages.integer_in?(timeout, 1, 60_000),
         :ok <- Protocol.validate_payload("prepare_runtime", request),
         true <- request["stage_set_digest"] == state.boot_identity["stage_set_digest"],
         id = Ecto.UUID.generate(),
         {:ok, next} <- send_frame(state, "prepare_runtime", id, request) do
      timer = Process.send_after(self(), {:preparation_timeout, id}, timeout)

      {:noreply,
       %{
         next
         | preparation_used: true,
           preparation: %{id: id, request: request, from: from, timer: timer}
       }}
    else
      _ -> {:reply, {:error, :stage_unavailable}, state}
    end
  end

  # Install the waiter before this process can consume a native result frame.
  def handle_call({:submit_and_await, job, authority}, from, state) do
    case handle_call({:submit, job, authority}, from, state) do
      {:reply, {:ok, id}, next} ->
        {:noreply, put_in(next.jobs[id].waiters, [from])}

      other ->
        other
    end
  end

  def handle_call({:submit, job, authority}, _from, state) do
    with true <- state.ready and is_nil(state.retirement),
         true <- is_nil(state.preparation) and prepared_job?(state.prepared, job),
         :ok <- Protocol.validate_payload("job", job),
         true <- job["worker_session_id"] == state.session,
         true <- map_size(state.requests) < 3,
         false <- Map.has_key?(state.jobs, job["job_id"]),
         :ok <-
           StageAuthority.revalidate_job(%{
             "job" => job,
             "authority" => authority,
             "result" => nil
           }),
         request_id = Ecto.UUID.generate(),
         {:ok, state} <- send_frame(state, "job", request_id, job) do
      record = %{
        job: job,
        authority: authority,
        request_id: request_id,
        state: "running",
        result: nil,
        waiters: [],
        delivered_receipts: [],
        completion_digest: nil
      }

      state = %{
        state
        | jobs: Map.put(state.jobs, job["job_id"], record),
          requests: Map.put(state.requests, request_id, job["job_id"])
      }

      {:reply, {:ok, job["job_id"]}, state}
    else
      false -> {:reply, {:error, :reconcile_required}, state}
      true -> {:reply, {:error, :budget_exhausted}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:prepare_retirement, id, publisher, digest}, {caller, _}, state) do
    with true <- caller == Process.whereis(HarnessForge.Graphiti.Runtime),
         true <- is_nil(state.retirement) and is_pid(publisher) and Process.alive?(publisher),
         %{state: "publishing", completion_digest: ^digest} = record <- state.jobs[id],
         true <- record.job["op"] in ~w(ingest search) and Stages.digest?(digest),
         [{ref, {:publication, ^id}}] <- Map.to_list(state.tasks),
         true <- state.task_pids[ref] == publisher,
         true <-
           map_size(state.contexts) == 0 and map_size(state.attempts) == 0 and
             map_size(state.context_grants) == 0 and map_size(state.requests) == 0,
         true <-
           Enum.all?(state.jobs, fn {job_id, r} -> job_id == id or r.state == "completed" end),
         ids = record.delivered_receipts,
         true <- length(ids) in 1..256 and length(ids) == length(Enum.uniq(ids)) do
      {:reply, {:ok, ids},
       %{state | ready: false, retirement: %{job_id: id, publisher: publisher, digest: digest}}}
    else
      _ -> {:reply, {:error, :closure_incomplete}, state}
    end
  end

  def handle_call({:await, id}, from, state) do
    case Map.get(state.jobs, id) do
      nil ->
        {:reply, {:error, :worker_lost}, state}

      %{result: nil} = record ->
        state = put_in(state.jobs[id], %{record | waiters: [from | record.waiters]})
        {:noreply, state}

      %{result: result} ->
        {:reply, result, state}
    end
  end

  def handle_call({:status, id}, _from, state) do
    result =
      case Map.get(state.jobs, id) do
        nil -> {:error, :worker_lost}
        record -> {:ok, %{"job_id" => id, "state" => record.state}}
      end

    {:reply, result, state}
  end

  def handle_call({:cancel, id, epoch}, _from, state) do
    # Root must persist/increment the epoch before invoking this operation.
    case Map.get(state.jobs, id) do
      nil ->
        {:reply, {:error, :worker_lost}, state}

      %{job: job} when is_map(job) ->
        cancel = %{
          job
          | "op" => "cancel",
            "job_id" => Ecto.UUID.generate(),
            "idempotency_key" => Ecto.UUID.generate(),
            "cancel_epoch" => epoch,
            "args" => %{"target_job_id" => id, "new_cancel_epoch" => epoch}
        }

        with true <-
               is_integer(epoch) and epoch > job["cancel_epoch"] and
                 is_binary(job["partition_id"]) and is_binary(job["lease_id"]) and
                 job["worker_session_id"] == state.session,
             {:ok, state} <- send_frame(state, "job", cancel["job_id"], cancel) do
          {:reply, :ok, put_in(state.jobs[id].state, "cancelled")}
        else
          false -> {:reply, {:error, :stale_generation}, state}
          error -> {:reply, error, state}
        end

      _ ->
        {:reply, {:error, :scope_denied}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    case Protocol.consume(state.buffer <> bytes) do
      {:ok, frames, remaining} ->
        Enum.reduce_while(frames, {:ok, %{state | buffer: remaining}}, fn frame, {:ok, acc} ->
          case receive_frame(frame, acc) do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, next} -> {:noreply, next}
          _ -> {:stop, :invalid_frame, fail_waiters(state)}
        end

      _ ->
        {:stop, :invalid_frame, fail_waiters(state)}
    end
  end

  def handle_info({:preparation_timeout, id}, %{preparation: %{id: id}} = state) do
    {:stop, :deadline_exceeded, fail_waiters(state)}
  end

  def handle_info({:graphiti_grant, attempt_id, grant}, state) do
    case Map.get(state.attempts, attempt_id) do
      %{grant_sent: false} = attempt ->
        case send_frame(state, "attempt_grant", attempt_id, grant) do
          {:ok, next} ->
            {:noreply, put_in(next.attempts[attempt_id], %{attempt | grant_sent: true})}

          _ ->
            {:stop, :worker_lost, fail_waiters(state)}
        end

      _ ->
        {:stop, :reconcile_required, fail_waiters(state)}
    end
  end

  def handle_info({ref, {:attempt_finished, attempt_id, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state = %{
      state
      | tasks: Map.delete(state.tasks, ref),
        task_pids: Map.delete(state.task_pids, ref)
    }

    receipt =
      case result do
        {:ok, value} -> value
        {:error, reason} -> denied_receipt(attempt_id, reason)
      end

    case send_frame(state, "attempt_result", attempt_id, receipt) do
      {:ok, next} ->
        job_id = state.attempts[attempt_id].job_id
        record = next.jobs[job_id]
        ids = record.delivered_receipts ++ [receipt["receipt_id"]]

        if length(ids) <= 256 and length(ids) == length(Enum.uniq(ids)) do
          next = put_in(next.jobs[job_id].delivered_receipts, ids)
          {:noreply, %{next | attempts: Map.delete(next.attempts, attempt_id)}}
        else
          {:stop, :response_limit, fail_waiters(state)}
        end

      _ ->
        {:stop, :worker_lost, fail_waiters(state)}
    end
  end

  def handle_info({ref, {:context_finished, request, outcome}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state = %{
      state
      | tasks: Map.delete(state.tasks, ref),
        task_pids: Map.delete(state.task_pids, ref)
    }

    case Map.pop(state.contexts, request) do
      {nil, _} ->
        {:stop, :reconcile_required, fail_waiters(state)}

      {page, contexts} ->
        active = match?(%{state: "running"}, Map.get(state.jobs, page["job_id"]))

        ack =
          case {active, outcome} do
            {false, _} ->
              denied_context(page, :cancelled)

            {true, {:ok, value}} ->
              if valid_context_ack?(value, page),
                do: value,
                else: denied_context(page, :reconcile_required)

            {true, {:error, code}} ->
              denied_context(page, code)

            _ ->
              denied_context(page, :closure_incomplete)
          end

        grants =
          if page["phase"] == "attempt_bind" and ack["state"] == "sealed" do
            Map.put(
              state.context_grants,
              ack["context_manifest_ref"],
              {page["job_id"], ack["context_manifest_digest"], ack["allowed_body_sha256"]}
            )
          else
            state.context_grants
          end

        case send_frame(
               %{state | contexts: contexts, context_grants: grants},
               "context_ack",
               request,
               ack
             ) do
          {:ok, next} -> {:noreply, next}
          _ -> {:stop, :worker_lost, fail_waiters(state)}
        end
    end
  end

  def handle_info({ref, {:publication_finished, id, outcome}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state = %{
      state
      | tasks: Map.delete(state.tasks, ref),
        task_pids: Map.delete(state.task_pids, ref)
    }

    case Map.get(state.jobs, id) do
      nil ->
        {:stop, :reconcile_required, fail_waiters(state)}

      record ->
        Enum.each(record.waiters, &GenServer.reply(&1, outcome))
        retiring_ingest = record.job["op"] in ~w(ingest search)

        record = %{
          record
          | state: if(match?({:ok, _}, outcome), do: "completed", else: "reconcile_required"),
            result: outcome,
            waiters: [],
            job: nil,
            authority: nil,
            delivered_receipts: []
        }

        grants = Map.reject(state.context_grants, fn {_, {job_id, _, _}} -> job_id == id end)

        state = %{
          state
          | jobs: Map.put(state.jobs, id, record),
            order: state.order ++ [id],
            context_grants: grants
        }

        if retiring_ingest, do: {:stop, :normal, state}, else: {:noreply, trim_results(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = %{state | task_pids: Map.delete(state.task_pids, ref)}

    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{:context, request}, tasks} ->
        case Map.pop(state.contexts, request) do
          {nil, _} ->
            {:stop, :reconcile_required, fail_waiters(state)}

          {page, contexts} ->
            case send_frame(
                   %{state | contexts: contexts, tasks: tasks},
                   "context_ack",
                   request,
                   denied_context(page, :closure_incomplete)
                 ) do
              {:ok, next} -> {:noreply, next}
              _ -> {:stop, :worker_lost, fail_waiters(state)}
            end
        end

      {{:publication, id}, tasks} ->
        record = state.jobs[id]
        outcome = {:error, :reconcile_required}
        Enum.each(record.waiters, &GenServer.reply(&1, outcome))
        ingest = record.job["op"] in ~w(ingest search)

        record = %{
          record
          | state: "reconcile_required",
            result: outcome,
            waiters: [],
            job: nil,
            authority: nil,
            delivered_receipts: []
        }

        state = %{state | tasks: tasks, jobs: Map.put(state.jobs, id, record)}
        if ingest, do: {:stop, :normal, state}, else: {:noreply, state}

      {attempt_id, tasks} ->
        receipt = denied_receipt(attempt_id, :reconcile_required)

        case send_frame(%{state | tasks: tasks}, "attempt_result", attempt_id, receipt) do
          {:ok, next} -> {:noreply, %{next | attempts: Map.delete(next.attempts, attempt_id)}}
          _ -> {:stop, :worker_lost, fail_waiters(state)}
        end
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port, retirement: retirement} = state)
      when not is_nil(retirement), do: {:noreply, state}

  def handle_info({:EXIT, port, _}, %{port: port, retirement: retirement} = state)
      when not is_nil(retirement), do: {:noreply, state}

  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:stop, :worker_lost, fail_waiters(state)}

  def handle_info({:EXIT, port, _}, %{port: port} = state),
    do: {:stop, :worker_lost, fail_waiters(state)}

  def handle_info(_, state), do: {:noreply, state}

  defp receive_frame(frame, state) do
    if frame["session_id"] == state.session and frame["seq"] == state.input_seq + 1 do
      route(frame, %{state | input_seq: frame["seq"]})
    else
      {:error, :invalid_frame}
    end
  end

  defp route(
         %{"kind" => "result", "request_id" => request, "payload" => result},
         %{boot_request: request, ready: false} = state
       ) do
    if validate_boot_result(state.boot_identity, request, result) == :ok,
      do: {:ok, %{state | ready: true}},
      else: {:error, :stage_unavailable}
  end

  defp route(
         %{"kind" => "prepare_runtime_ack", "request_id" => id, "payload" => ack},
         %{preparation: %{id: id} = pending} = state
       ) do
    with :ok <- Protocol.validate_payload("prepare_runtime_ack", ack),
         true <- Map.take(ack, Map.keys(pending.request)) == pending.request,
         true <-
           ack["source_lock_digest"] == state.boot_identity["source_lock_digest"] and
             ack["backend_pin_digest"] == state.boot_identity["backend_pin_digest"],
         true <- ack["initialized"] == true and is_nil(ack["error_code"]) do
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, {:ok, ack})
      {:ok, %{state | preparation: nil, prepared: pending.request}}
    else
      _ -> {:error, :stage_unavailable}
    end
  end

  defp route(%{"kind" => "attempt", "request_id" => request, "payload" => attempt}, state) do
    with true <- request == attempt["attempt_id"],
         false <- Map.has_key?(state.attempts, request),
         true <- map_size(state.attempts) < 1,
         %{job: job, authority: authority, state: "running"} <-
           Map.get(state.jobs, attempt["job_id"]),
         true <-
           Map.get(state.context_grants, attempt["context_manifest_ref"]) ==
             {attempt["job_id"], attempt["context_manifest_digest"], attempt["payload_sha256"]},
         true <-
           attempt["closure_ref"] == job["closure_ref"] and
             attempt["closure_digest"] == job["closure_digest"] and
             attempt["cancel_epoch"] == job["cancel_epoch"] do
      parent = self()

      task =
        Task.async(fn ->
          result =
            AttemptGateway.dispatch(attempt, authority, job, fn grant ->
              send(parent, {:graphiti_grant, request, grant})
              :ok
            end)

          {:attempt_finished, request, result}
        end)

      # Task failures are monitored, not linked to the reader.
      Process.unlink(task.pid)

      {:ok,
       %{
         state
         | attempts:
             Map.put(state.attempts, request, %{grant_sent: false, job_id: attempt["job_id"]}),
           context_grants: Map.delete(state.context_grants, attempt["context_manifest_ref"]),
           tasks: Map.put(state.tasks, task.ref, request),
           task_pids: Map.put(state.task_pids, task.ref, task.pid)
       }}
    else
      _ -> {:error, :scope_denied}
    end
  end

  defp route(%{"kind" => "context_page", "request_id" => request, "payload" => page}, state) do
    with true <- map_size(state.contexts) < 1 and not Map.has_key?(state.contexts, request),
         %{job: job, authority: authority, state: "running"} <-
           Map.get(state.jobs, page["job_id"]),
         true <- job["op"] in ~w(ingest search) and job["worker_session_id"] == state.session,
         true <-
           Enum.all?(
             ~w(partition_id lease_id cancel_epoch semantic_generation authorization_generation),
             &(page[&1] == job[&1])
           ),
         true <-
           page["operation_manifest_ref"] == job["closure_ref"] and
             page["operation_manifest_digest"] == job["closure_digest"] do
      task =
        Task.async(fn ->
          result =
            StageAuthority.observe_context(
              %{"job" => job, "authority" => authority, "result" => nil},
              page
            )

          {:context_finished, request, result}
        end)

      Process.unlink(task.pid)

      {:ok,
       %{
         state
         | contexts: Map.put(state.contexts, request, page),
           tasks: Map.put(state.tasks, task.ref, {:context, request}),
           task_pids: Map.put(state.task_pids, task.ref, task.pid)
       }}
    else
      _ -> {:error, :scope_denied}
    end
  end

  defp route(%{"kind" => "result", "request_id" => request, "payload" => result}, state) do
    case Map.get(state.requests, request) do
      nil ->
        # Cancel acknowledgements have no approval/publication authority.
        if Map.has_key?(result["result"], "cancelled_job_id"),
          do: {:ok, state},
          else: {:error, :reconcile_required}

      id ->
        record = state.jobs[id]

        if result["job_id"] != id do
          {:error, :reconcile_required}
        else
          # Root publication is outside the reader: it can perform bounded DB
          # validation without blocking further attempt/grant input processing.
          task =
            Task.async(fn ->
              outcome =
                StageAuthority.publish_result(%{
                  "job" => record.job,
                  "authority" => record.authority,
                  "result" => result
                })

              {:publication_finished, id, outcome}
            end)

          Process.unlink(task.pid)

          {:ok,
           %{
             state
             | requests: Map.delete(state.requests, request),
               jobs:
                 Map.put(state.jobs, id, %{
                   record
                   | state: "publishing",
                     completion_digest: completion_digest(result)
                 }),
               tasks: Map.put(state.tasks, task.ref, {:publication, id}),
               task_pids: Map.put(state.task_pids, task.ref, task.pid)
           }}
        end
    end
  end

  defp route(_, _), do: {:error, :invalid_frame}

  defp completion_digest(result) do
    case CompletionCommitment.digest(result) do
      {:ok, digest} -> digest
      _ -> nil
    end
  end

  defp send_frame(state, kind, request_id, payload) do
    frame = %{
      "v" => 1,
      "kind" => kind,
      "session_id" => state.session,
      "seq" => state.output_seq + 1,
      "request_id" => request_id,
      "payload" => payload
    }

    with {:ok, bytes} <- Protocol.encode(frame), true <- Port.command(state.port, bytes) do
      {:ok, %{state | output_seq: state.output_seq + 1}}
    else
      _ -> {:error, :worker_lost}
    end
  rescue
    _ -> {:error, :worker_lost}
  end

  defp denied_receipt(id, reason),
    do: %{
      "attempt_id" => id,
      "receipt_id" => Ecto.UUID.generate(),
      "state" => "denied",
      "http_status" => nil,
      "body" => nil,
      "body_sha256" => nil,
      "usage_status" => "unknown",
      "billing_status" => "unknown",
      "input_tokens" => nil,
      "output_tokens" => nil,
      "error_code" => Protocol.safe_code(reason)
    }

  defp denied_context(page, code),
    do: %{
      "job_id" => page["job_id"],
      "context_id" => page["context_id"],
      "page_index" => page["page_index"],
      "page_digest" => Protocol.context_page_digest(page),
      "state" => "denied",
      "version_refs" => [],
      "context_manifest_ref" => nil,
      "context_manifest_digest" => nil,
      "allowed_body_sha256" => nil,
      "error_code" => Protocol.safe_code(code)
    }

  defp valid_context_ack?(ack, page) do
    Protocol.validate_payload("context_ack", ack) == :ok and
      ack["job_id"] == page["job_id"] and ack["context_id"] == page["context_id"] and
      ack["page_index"] == page["page_index"] and
      ack["page_digest"] == Protocol.context_page_digest(page) and
      (ack["state"] != "sealed" or
         (page["final"] and ack["context_manifest_ref"] != page["operation_manifest_ref"] and
            ack["allowed_body_sha256"] == page["raw_body_sha256"] and
            Enum.sort(Enum.map(ack["version_refs"], & &1["entry_id"])) ==
              Enum.sort(Enum.map(page["entries"], & &1["entry_id"]))))
  end

  defp fail_waiters(state) do
    if pending = state.preparation do
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, {:error, :worker_lost})
    end

    Enum.each(state.jobs, fn {_, record} ->
      Enum.each(record.waiters, &GenServer.reply(&1, {:error, :worker_lost}))
    end)

    state
  end

  defp prepared_job?(nil, job) when is_map(job), do: job["op"] != "search"
  defp prepared_job?(_prepared, %{"op" => "health"}), do: true

  defp prepared_job?(prepared, job) when is_map(job) do
    job["op"] == "search" and
      Enum.all?(~w(partition_id lease_id scope_ref stage_set_digest), &(job[&1] == prepared[&1])) and
      job["job_id"] == prepared["operation_id"]
  end

  defp prepared_job?(_, _), do: false

  defp trim_results(%{order: [_ | _] = order} = state) when length(order) > 100 do
    [oldest | rest] = order
    %{state | order: rest, jobs: Map.delete(state.jobs, oldest)}
  end

  defp trim_results(state), do: state

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted, log: []})

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.task_pids, fn {_, pid} -> Process.exit(pid, :kill) end)
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  rescue
    _ -> :ok
  end
end
