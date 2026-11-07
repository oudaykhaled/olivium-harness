defmodule HarnessForge.GitHubAccountTest do
  use HarnessForge.DataCase, async: false
  import ExUnit.CaptureLog
  alias HarnessForge.Connectors.GitHubAccount
  alias HarnessForge.Contracts.Error
  alias HarnessForge.Evidence.{Revision, Source}

  @ref "HARNESSFORGE_TEST_ACCOUNT_TOKEN"
  @secret "synthetic-account-secret"

  setup do
    Req.Test.verify_on_exit!()
    previous = System.get_env(@ref)
    System.put_env(@ref, @secret)

    on_exit(fn ->
      if previous, do: System.put_env(@ref, previous), else: System.delete_env(@ref)
    end)

    :ok
  end

  test "account config stores only a required environment reference" do
    assert {:ok, %{"credential_ref" => @ref}} = GitHubAccount.validate_config(config())

    for invalid <- [
          nil,
          %{},
          %{"credential_ref" => nil},
          %{"credential_ref" => "ghp_raw-secret"},
          %{"credential_ref" => "a"},
          %{"credential_ref" => @ref, "token" => @secret},
          %{"credential_ref" => @ref, "endpoint" => "https://evil.invalid"},
          %{"credential_ref" => @ref, "request_options" => []}
        ] do
      assert {:error, %Error{code: "invalid_connector_config"}} =
               GitHubAccount.validate_config(invalid)
    end
  end

  test "verify uses the authenticated account and discards private profile fields" do
    expect_user(Map.merge(user(), %{"email" => "private@example.invalid", "plan" => "private"}))

    assert {:ok, result} = GitHubAccount.verify(config(), context())

    assert result == %{
             "provider" => "github",
             "verified" => true,
             "identity" => %{"id" => 10, "login" => "synthetic"}
           }

    refute inspect(result) =~ @secret
    refute inspect(result) =~ "private"
  end

  test "live repository metadata uses fixed owner scope and returns ten in API updated order" do
    original_sources = Repo.aggregate(Source, :count)
    original_revisions = Repo.aggregate(Revision, :count)
    expect_user()

    entries = for n <- 1..10, do: repository(n, "2026-10-#{31 - n}T12:00:00Z")
    expect_repositories(entries, 10, next_link(10))

    assert {:ok, result} = GitHubAccount.repositories(config(), %{}, context())
    assert result["identity"] == %{"id" => 10, "login" => "synthetic"}
    assert result["ordering"] == "updated_desc"
    assert result["scope"] == "owner"
    assert result["visibility"] == "token_visible"
    assert result["requested"] == 10
    assert result["returned"] == 10
    assert result["has_more"]
    refute result["complete"]
    assert Enum.map(result["repositories"], & &1["id"]) == Enum.to_list(1..10)

    assert Enum.all?(result["repositories"], fn entry ->
             Enum.sort(Map.keys(entry)) ==
               ~w(full_name html_url id name private stargazers_count updated_at)
           end)

    refute inspect(result) =~ "do not import this source body"
    assert Repo.aggregate(Source, :count) == original_sources
    assert Repo.aggregate(Revision, :count) == original_revisions
  end

  test "equal updated timestamps retain provider order without inventing a star ranking" do
    expect_user()
    first = repository(2) |> Map.put("stargazers_count", 0)
    second = repository(1) |> Map.put("stargazers_count", 100)
    expect_repositories([first, second], 2)
    assert {:ok, result} = GitHubAccount.repositories(config(), %{"limit" => 2}, context())
    assert Enum.map(result["repositories"], & &1["id"]) == [2, 1]
    assert result["complete"]
    refute result["has_more"]
  end

  test "one and twenty are accepted bounds while invalid limits make no transport call" do
    for count <- [1, 20] do
      expect_user()
      expect_repositories([], count)

      assert {:ok, %{"requested" => ^count, "returned" => 0, "complete" => true}} =
               GitHubAccount.repositories(config(), %{"limit" => count}, context())
    end

    for opts <- [
          nil,
          [],
          %{"limit" => 0},
          %{"limit" => 21},
          %{"limit" => "10"},
          %{"limit" => 1.0},
          %{"sort" => "stars"},
          %{"limit" => 10, "url" => "https://evil.invalid"}
        ] do
      assert {:error, %Error{code: "invalid_account_query"}} =
               GitHubAccount.repositories(config(), opts, context())
    end
  end

  test "missing empty multiline or oversized credentials never reach transport" do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :unexpected_transport)
      Req.Test.json(conn, user())
    end)

    for credential <- [nil, "", "line\nsecret", "line\rsecret", String.duplicate("x", 16_385)] do
      if credential, do: System.put_env(@ref, credential), else: System.delete_env(@ref)

      assert {:error, %Error{code: "credential_unavailable"}} =
               GitHubAccount.verify(config(), context())

      assert {:error, %Error{code: "credential_unavailable"}} =
               GitHubAccount.repositories(config(), %{}, context())
    end

    refute_receive :unexpected_transport
  end

  test "account verification rejects malformed identities and URLs before repository requests" do
    for invalid <- [
          nil,
          [],
          Map.put(user(), "id", "10"),
          Map.put(user(), "id", 0),
          Map.put(user(), "login", "../../other"),
          Map.put(user(), "html_url", "https://evil.invalid/synthetic"),
          Map.put(user(), "html_url", "https://secret@github.com/synthetic"),
          Map.put(user(), "html_url", "https://github.com/synthetic?token=private")
        ] do
      expect_user(invalid)

      assert {:error, %Error{code: "invalid_provider_response"}} =
               GitHubAccount.repositories(config(), %{}, context())
    end
  end

  test "owned repository validation rejects foreign identities and untrusted metadata" do
    bad_repositories = [
      Map.put(repository(1), "id", "1"),
      Map.put(repository(1), "id", -1),
      put_in(repository(1), ["owner", "login"], "other"),
      put_in(repository(1), ["owner", "id"], 11),
      put_in(repository(1), ["owner", "id"], 10.0),
      Map.put(repository(1), "owner", nil),
      Map.put(repository(1), "name", ".."),
      Map.put(repository(1), "name", "repo/escape"),
      Map.put(repository(1), "full_name", "other/repo-1"),
      Map.put(repository(1), "html_url", "https://evil.invalid/synthetic/repo-1"),
      Map.put(repository(1), "html_url", "https://github.com/synthetic/repo-1?secret=hidden"),
      Map.put(repository(1), "html_url", "https://github.com/synthetic/repo-1#fragment"),
      Map.put(repository(1), "private", "false"),
      Map.put(repository(1), "stargazers_count", -1),
      Map.put(repository(1), "stargazers_count", "2"),
      Map.put(repository(1), "updated_at", nil),
      Map.put(repository(1), "updated_at", "not a timestamp"),
      Map.put(repository(1), "updated_at", "2026-10-30T12:00:00-2500")
    ]

    for invalid <- bad_repositories do
      expect_user()
      expect_repositories([invalid], 10)

      assert {:error, %Error{code: "scope_violation"}} =
               GitHubAccount.repositories(config(), %{}, context())
    end
  end

  test "duplicate IDs and ascending timestamps are rejected rather than mislabeled as a top page" do
    for entries <- [
          [repository(1), repository(1)],
          [repository(1, "2026-10-29T12:00:00Z"), repository(2, "2026-10-30T12:00:00Z")]
        ] do
      expect_user()
      expect_repositories(entries, 10)

      assert {:error, %Error{code: "invalid_provider_response"}} =
               GitHubAccount.repositories(config(), %{}, context())
    end
  end

  test "malformed or oversized repository collections are rejected without truncation" do
    for entries <- [nil, %{"items" => []}, [nil], Enum.map(1..11, &repository/1)] do
      expect_user()
      expect_repositories(entries, 10)

      assert {:error, %Error{code: "invalid_provider_response"}} =
               GitHubAccount.repositories(config(), %{}, context())
    end
  end

  test "pagination is reported only for a validated fixed account endpoint" do
    for link <- [
          ~s(<https://evil.invalid/user/repos?page=2>; rel="next"),
          String.replace(next_link(10), "affiliation=owner", "affiliation=collaborator"),
          String.replace(next_link(10), "page=2", "page=3"),
          String.replace(next_link(10), "per_page=10", "per_page=20"),
          String.replace(next_link(10), "https://api.github.com", "https://secret@api.github.com")
        ] do
      expect_user()
      expect_repositories([repository(1)], 10, link)

      assert {:error, %Error{code: "scope_violation"}} =
               GitHubAccount.repositories(config(), %{}, context())
    end
  end

  test "provider denial redirects rate limits and bodies expose safe errors only" do
    cases = [
      {401, [], "source_access_denied", false},
      {403, [], "source_access_denied", false},
      {404, [], "source_access_denied", false},
      {302, [{"location", "https://evil.invalid"}], "redirect_rejected", false},
      {403, [{"x-ratelimit-remaining", "0"}], "rate_limited", true},
      {429, [{"retry-after", "120"}], "rate_limited", true},
      {500, [], "provider_unavailable", true}
    ]

    log =
      capture_log(fn ->
        for {status, headers, code, retryable} <- cases do
          Req.Test.expect(__MODULE__, fn conn ->
            conn =
              Enum.reduce(headers, conn, fn {key, value}, acc ->
                Plug.Conn.put_resp_header(acc, key, value)
              end)

            Plug.Conn.send_resp(conn, status, @secret <> " private provider detail")
          end)

          assert {:error, %Error{code: ^code, retryable: ^retryable} = error} =
                   GitHubAccount.verify(config(), context())

          refute inspect(error) =~ @secret
          refute inspect(error) =~ "private provider detail"
          if status == 429, do: assert(error.details == ["retry_after_seconds:120"])
        end
      end)

    refute log =~ @secret
    refute log =~ "private provider detail"
  end

  test "oversized and invalid JSON responses fail safely" do
    for {body, code} <- [
          {String.duplicate("x", 4_194_305), "provider_response_too_large"},
          {"private invalid JSON " <> @secret, "invalid_provider_response"}
        ] do
      Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))

      assert {:error, %Error{code: ^code} = error} =
               GitHubAccount.verify(config(), context())

      refute inspect(error) =~ @secret
    end
  end

  defp config, do: %{"credential_ref" => @ref}
  defp context, do: %{"request_options" => [plug: {Req.Test, __MODULE__}]}

  defp user,
    do: %{"id" => 10, "login" => "synthetic", "html_url" => "https://github.com/synthetic"}

  defp expect_user(body \\ user()) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert_request(conn, "/user")
      assert Plug.Conn.fetch_query_params(conn).query_params == %{}
      Req.Test.json(conn, body)
    end)
  end

  defp expect_repositories(body, limit, link \\ nil) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert_request(conn, "/user/repos")

      assert Plug.Conn.fetch_query_params(conn).query_params == %{
               "affiliation" => "owner",
               "visibility" => "all",
               "sort" => "updated",
               "direction" => "desc",
               "page" => "1",
               "per_page" => to_string(limit)
             }

      conn = if link, do: Plug.Conn.put_resp_header(conn, "link", link), else: conn
      Req.Test.json(conn, body)
    end)
  end

  defp assert_request(conn, path) do
    assert conn.method == "GET"
    assert conn.scheme == :https
    assert conn.host == "api.github.com"
    assert conn.request_path == path
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @secret]
    assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github+json"]
    assert Plug.Conn.get_req_header(conn, "x-github-api-version") == ["2026-03-10"]
  end

  defp repository(number, updated_at \\ "2026-10-30T12:00:00Z") do
    %{
      "id" => number,
      "name" => "repo-#{number}",
      "full_name" => "synthetic/repo-#{number}",
      "owner" => %{"id" => 10, "login" => "synthetic"},
      "html_url" => "https://github.com/synthetic/repo-#{number}",
      "private" => rem(number, 2) == 0,
      "stargazers_count" => number,
      "updated_at" => updated_at,
      "description" => "do not import this source body",
      "temp_clone_token" => "must-not-return"
    }
  end

  defp next_link(limit) do
    ~s(<https://api.github.com/user/repos?affiliation=owner&visibility=all&sort=updated&direction=desc&page=2&per_page=#{limit}>; rel="next")
  end
end
