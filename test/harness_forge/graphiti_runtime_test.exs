defmodule HarnessForge.Graphiti.RuntimeTest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{Contracts, Repo, Workspaces}
  alias HarnessForge.Evidence.{Corpora, GraphSources}
  alias HarnessForge.Graphiti.{Backend, Inventory, Pipe, Private, Runtime}

  test "cleanup authority stays within recorded partition resources after owner loss" do
    partition = Ecto.UUID.generate()
    suffix = String.replace(partition, "-", "")

    labels = %{
      "dev.harnessforge.workspace" => Workspaces.current_id(),
      "dev.harnessforge.partition" => partition
    }

    volume = %{
      "Name" => "hf-graph-data-" <> suffix,
      "CreatedAt" => "2026-01-01T00:00:00Z",
      "Driver" => "local",
      "Labels" => labels,
      "Options" => nil
    }

    resources = %{
      "partition_id" => partition,
      "workspace_id" => Workspaces.current_id(),
      "network_id" => String.duplicate("a", 64),
      "network_name" => "hf-graph-net-" <> suffix,
      "backend_id" => String.duplicate("b", 64),
      "volumes" => [volume]
    }

    assert :ok = Backend.cleanup_scope(resources)

    assert {:error, _} =
             Backend.cleanup_scope(Map.put(resources, "workspace_id", Ecto.UUID.generate()))

    assert {:error, _} =
             Backend.cleanup_scope(Map.put(resources, "network_name", "other-network"))

    assert {:error, _} =
             Backend.cleanup_scope(
               put_in(resources, ["volumes", Access.at(0), "Name"], "existing-company-data")
             )

    assert {:error, _} =
             Backend.cleanup_scope(put_in(resources, ["volumes", Access.at(0), "Labels"], %{}))

    assert {:error, _} = Backend.cleanup_scope(Map.put(resources, "volumes", [volume, volume]))
    assert {:error, _} = Backend.cleanup_scope(Map.put(resources, "extra", "ignored-ownership"))
    assert {:error, _} = Backend.cleanup_scope(%{})
  end

  defp caller,
    do: [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("graph-runtime-control"),
      view_generation: String.duplicate("a", 32),
      reset_token: 0
    ]

  test "reserved scope and configuration confer no live runtime authority" do
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic unqualified scope"}, caller())
    {:ok, scope} = GraphSources.reserve(corpus["id"], caller())
    id = scope["partition_id"]
    assert scope["state"] == "awaiting_runtime"

    assert [[nil, nil]] =
             Repo.query!(
               "SELECT backend_pin_digest,authority_json FROM graph_partition_controls WHERE id=?",
               [id]
             ).rows

    assert {:error, _} = GraphSources.advance(id, caller())
    assert {:error, :graph_unavailable} = Runtime.binding(id)
    assert {:error, :graph_unavailable} = GraphSources.bind_runtime(id, caller())
    before = Repo.query!("SELECT count(*) FROM graph_runtime_backends", []).rows
    assert {:error, :graph_unavailable} = Runtime.provision(id, caller())

    assert {:ok, {:error, :transaction_boundary_required}} =
             Repo.transaction(fn -> Runtime.provision(id, caller()) end)

    assert before == Repo.query!("SELECT count(*) FROM graph_runtime_backends", []).rows

    # Durable IDs and a constructed authority cannot mint a private job,
    # observation slot, measured projection or response proof.
    auth =
      struct(HarnessForge.Models.StageAuthority,
        workspace_id: Workspaces.current_id(),
        operation_id: Ecto.UUID.generate(),
        partition_id: id,
        worker_session_id: Ecto.UUID.generate(),
        caller: caller(),
        operation_type: "ingest",
        stage_pins: [],
        launch_token: String.duplicate("0", 64)
      )

    assert {:error, _} = Runtime.submit(auth, %{})
    assert {:error, _} = Runtime.observation_current(auth, %{})
    assert {:error, _} = Runtime.begin_observation(auth, %{}, %{})
    assert {:error, _} = Runtime.take_projection(auth, %{})
    assert {:error, _} = Runtime.observe_inventory(auth, %{}, %{})
    assert {:error, :closure_incomplete} = Runtime.observe_values(auth, %{}, %{})
    assert before == Repo.query!("SELECT count(*) FROM graph_runtime_backends", []).rows

    assert [["staging"]] =
             Repo.query!("SELECT state FROM graph_partition_controls WHERE id=?", [id]).rows
  end

  test "unauthorized and duplicate provisioning cannot fence an existing backend" do
    {:ok, corpus} = Corpora.create(%{"name" => "Synthetic existing backend"}, caller())
    {:ok, scope} = GraphSources.reserve(corpus["id"], caller())
    id = scope["partition_id"]

    Repo.query!(
      "INSERT INTO graph_runtime_backends(workspace_id,partition_id,instance_id,state,inserted_at,updated_at) VALUES(?,?,?,'verified',?,?)",
      [
        Workspaces.current_id(),
        id,
        Ecto.UUID.generate(),
        "2026-01-01T00:00:00Z",
        "2026-01-01T00:00:00Z"
      ]
    )

    state = %{backends: %{id => %{private_synthetic_marker: true}}, sessions: %{}}
    denied = Keyword.put(caller(), :authorize, fn -> false end)

    assert {:reply, {:error, _}, ^state} =
             Runtime.handle_call({:provision, id, denied}, nil, state)

    assert {:reply, {:error, _}, ^state} =
             Runtime.handle_call({:launch, id, [], denied}, nil, state)

    assert {:reply, {:error, _}, ^state} =
             Runtime.handle_call({:provision, id, caller()}, nil, state)

    assert [["verified"]] =
             Repo.query!("SELECT state FROM graph_runtime_backends WHERE partition_id=?", [id]).rows

    assert [["staging"]] =
             Repo.query!("SELECT state FROM graph_partition_controls WHERE id=?", [id]).rows
  end

  test "credential ciphertext authenticates workspace partition storage and every byte" do
    partition = Ecto.UUID.generate()
    instance = Ecto.UUID.generate()

    value = %{
      "uri" => "bolt://neo4j:7687",
      "database" => "neo4j",
      "user" => "synthetic",
      "password" => "synthetic-private-password"
    }

    cipher = Private.seal(value, partition, instance)
    refute cipher =~ value["password"]
    assert {:ok, ^value} = Private.open(cipher, partition, instance)
    assert {:error, :reconcile_required} = Private.open(cipher, Ecto.UUID.generate(), instance)
    assert {:error, :reconcile_required} = Private.open(cipher, partition, Ecto.UUID.generate())
    assert {:error, :reconcile_required} = Private.open(cipher <> "x", partition, instance)
    original = Workspaces.current_id()

    try do
      Application.put_env(:harness_forge, :workspace_id, Ecto.UUID.generate())
      assert {:error, :reconcile_required} = Private.open(cipher, partition, instance)
    after
      Application.put_env(:harness_forge, :workspace_id, original)
    end
  end

  test "reader requires one canonical response and refuses duplicate keys extra frames and truncation" do
    value = %{"v" => 1, "state" => "ok"}
    body = Contracts.canonical_json(value)
    frame = <<byte_size(body)::unsigned-big-32, body::binary>>
    assert {:ok, ^value} = Pipe.decode_response(frame)
    assert {:error, :invalid_frame} = Pipe.decode_response(frame <> frame)

    assert {:error, :invalid_frame} =
             Pipe.decode_response(binary_part(frame, 0, byte_size(frame) - 1))

    duplicate = ~s({"v":1,"v":1,"state":"ok"})

    assert {:error, :invalid_frame} =
             Pipe.decode_response(<<byte_size(duplicate)::unsigned-big-32, duplicate::binary>>)

    assert {:error, :invalid_frame} = Pipe.decode_response(<<98_305::unsigned-big-32>>)
  end

  test "inventory cannot bless foreign records substituted sessions or narrowed object sets" do
    session = Ecto.UUID.generate()

    request = %{
      "v" => 1,
      "session_id" => session,
      "action" => "identity",
      "backend" => %{"database" => "neo4j"}
    }

    identity = %{
      "edition" => "community",
      "version" => "5.26.32",
      "database" => "neo4j",
      "foreign_nodes" => 0,
      "foreign_edges" => 0,
      "unknown_nodes" => 0,
      "unknown_edges" => 0
    }

    result = %{
      "v" => 1,
      "session_id" => session,
      "action" => "identity",
      "state" => "ok",
      "records" => [identity],
      "next_cursor" => nil,
      "exhausted" => true,
      "error_code" => nil
    }

    assert :ok = Inventory.validate_response(result, request)

    assert {:error, :reconcile_required} =
             Inventory.validate_response(
               put_in(result, ["records", Access.at(0), "foreign_nodes"], 1),
               request
             )

    assert {:error, :invalid_frame} =
             Inventory.validate_response(
               Map.put(result, "session_id", Ecto.UUID.generate()),
               request
             )

    object_request =
      %{request | "action" => "objects"}
      |> Map.merge(%{
        "kind" => "entity",
        "group_id" => "synthetic",
        "limit" => 1,
        "cursor" => nil,
        "object_ids" => [Ecto.UUID.generate()]
      })

    assert {:error, :closure_incomplete} =
             Inventory.validate_response(
               %{result | "action" => "objects", "records" => []},
               object_request
             )
  end
end
