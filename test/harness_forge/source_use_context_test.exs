defmodule HarnessForge.SourceUseContextTest do
  use ExUnit.Case, async: false

  alias HarnessForge.{Contracts, Workspaces}
  alias HarnessForge.Company.AssessmentAttempts
  alias HarnessForge.Evidence.SourceUseContext
  alias HarnessForgeWeb.Plugs.OperatorSession

  test "domain authentication retains the existing workspace, epoch and twelve-hour limits" do
    auth = OperatorSession.new_auth()

    assert {:ok, %{workspace_id: id, owner_id: "local-operator"}} =
             Workspaces.authenticate_operator(auth)

    assert id == Workspaces.current_id()
    assert OperatorSession.valid?(auth)

    invalid = [
      nil,
      %{},
      Map.put(auth, "workspace_id", Ecto.UUID.generate()),
      Map.put(auth, "epoch", "another-process"),
      Map.put(auth, "issued_at", System.system_time(:second) + 60),
      Map.put(auth, "issued_at", System.system_time(:second) - 43_200),
      Map.put(auth, "issued_at", "now")
    ]

    for candidate <- invalid do
      assert {:error, :operator_session_revoked} = Workspaces.authenticate_operator(candidate)
      refute OperatorSession.valid?(candidate)
    end
  end

  test "trusted session caller keeps the exact callback ABI and detects revocation" do
    auth = OperatorSession.new_auth()
    assert {:ok, caller} = OperatorSession.source_caller(auth, String.duplicate("a", 32), 0)
    assert Enum.sort(Keyword.keys(caller)) ==
             Enum.sort([:authorize, :session_fingerprint, :view_generation, :reset_token])

    assert caller[:session_fingerprint] == Contracts.digest(auth)
    assert :ok = AssessmentAttempts.options(caller)
    assert :ok = AssessmentAttempts.authorize(caller)

    assert :ok = Workspaces.rotate_session_epoch()
    assert {:error, :operator_session_revoked} = Workspaces.authenticate_operator(auth)
    refute caller[:authorize].()
    assert {:error, :operator_session_revoked} =
             OperatorSession.source_caller(auth, String.duplicate("a", 32), 0)
  end

  test "caller factory rejects browser-shaped, malformed and foreign inputs" do
    auth = OperatorSession.new_auth()

    for {candidate, generation, reset} <- [
          {%{"owner_id" => "local-operator"}, String.duplicate("a", 32), 0},
          {auth, "short", 0},
          {auth, String.duplicate("z", 32), 0},
          {auth, String.duplicate("a", 32), -1},
          {auth, String.duplicate("a", 32), "0"}
        ] do
      assert {:error, :operator_session_revoked} =
               OperatorSession.source_caller(candidate, generation, reset)
    end
  end

  test "source context requires live genuine auth and keeps its exact caller separate" do
    auth = OperatorSession.new_auth()
    assert {:ok, caller} = OperatorSession.source_caller(auth, String.duplicate("b", 32), 1)
    assert {:ok, context} = SourceUseContext.interactive(auth, caller)
    assert :ok = SourceUseContext.match_caller(context, caller)

    for purpose <- ~w(inspection retrieval analysis compile) do
      assert {:ok, %{workspace_id: id, owner_id: "local-operator"}} =
               SourceUseContext.validate(context, purpose)

      assert id == Workspaces.current_id()
    end

    assert {:error, _} =
             SourceUseContext.match_caller(context, Keyword.put(caller, :reset_token, 2))

    assert {:error, _} = SourceUseContext.validate(context, "unrestricted")
    assert {:error, _} = SourceUseContext.validate(Map.from_struct(context), "inspection")
    assert :ok = Workspaces.rotate_session_epoch()
    assert {:error, _} = SourceUseContext.validate(context, "inspection")
  end

  test "callback or persisted references alone cannot mint source or worker authority" do
    fake_caller = [
      authorize: fn -> true end,
      session_fingerprint: Contracts.sha256("synthetic-no-session"),
      view_generation: String.duplicate("c", 32),
      reset_token: 0
    ]

    assert {:error, _} = SourceUseContext.interactive(%{}, fake_caller)
    assert {:error, _} = SourceUseContext.validate(nil, "inspection")
    auth = OperatorSession.new_auth()
    assert {:error, _} = SourceUseContext.interactive(auth, fake_caller)
    assert {:ok, caller} = OperatorSession.source_caller(auth, String.duplicate("d", 32), 0)
    assert {:ok, context} = SourceUseContext.interactive(auth, caller)
    ref = %{"id" => Ecto.UUID.generate(), "digest" => Contracts.sha256("not-an-operation")}
    assert {:error, _} = SourceUseContext.setup_analysis(context, ref, ref)
  end
end
