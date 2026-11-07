defmodule HarnessForge.GitHubProjectsConnectorTest do
  use HarnessForge.DataCase, async: false
  import ExUnit.CaptureLog
  alias HarnessForge.{Evidence, Repo}
  alias HarnessForge.Evidence.{Connection, Revision, Store}
  alias HarnessForge.Connectors.GitHubProjects
  alias HarnessForge.Contracts.Error

  @ref "HARNESSFORGE_TEST_PROJECTS_TOKEN"
  @url "https://github.com/orgs/synthetic/projects/7"
  @time "2026-10-31T12:00:00Z"

  setup do
    Req.Test.verify_on_exit!()
    previous = System.get_env(@ref)
    System.put_env(@ref, "synthetic-projects-secret")

    on_exit(fn ->
      if previous, do: System.put_env(@ref, previous), else: System.delete_env(@ref)
    end)

    :ok
  end

  test "canonical org/user selection requires an environment reference and rejects URL escapes" do
    assert {:ok, _} = GitHubProjects.validate_config(config())

    assert {:ok, _} =
             GitHubProjects.validate_config(
               config("https://github.com/users/synthetic/projects/7")
             )

    for change <- [
          %{"endpoint" => "https://api.github.com/graphql"},
          %{"endpoint" => "https://evil.invalid"},
          %{"project_url" => @url <> "/"},
          %{"project_url" => @url <> "/views/1"},
          %{"project_url" => @url <> "?token=secret"},
          %{"project_url" => @url <> "#secret"},
          %{"project_url" => "https://secret@github.com/orgs/synthetic/projects/7"},
          %{"project_url" => "https://github.com/orgs/../projects/7"},
          %{"project_url" => "https://github.com/orgs/synthetic/projects/07"},
          %{"credential_ref" => nil},
          %{"credential_ref" => "ghp_raw-secret"},
          %{"token" => "raw-secret"},
          %{"query" => "mutation { deleteProjectV2 }"}
        ] do
      assert {:error, %Error{code: "invalid_connector_config"}} =
               GitHubProjects.validate_config(Map.merge(config(), change))
    end

    connection = connect()
    assert connection["config"]["credential_ref"] == @ref
    refute inspect(connection) =~ "synthetic-projects-secret"
  end

  test "org project fields/views/items and nested values resume without truncation or repo fetches" do
    connection = connect()
    start(connection)

    expect(page("fields", [status_field()], "fields-two"), fn request ->
      assert request["variables"] == %{"owner" => "synthetic", "number" => 7, "after" => nil}
      assert request["query"] =~ "fields(first: 20"
      assert request["query"] =~ "options: multiSelectOptions"
    end)

    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(connection)
    assert cursor(connection)["after"] == "fields-two"

    expect(page("fields", [iteration_field()]), fn request ->
      assert request["variables"]["after"] == "fields-two"
    end)

    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(connection)
    assert cursor(connection)["stage"] == "views"

    board =
      view()
      |> Map.put(
        "fields",
        connection([field("F_STATUS", "Status", "SINGLE_SELECT")], "view-fields-two")
      )

    expect(page("views", [board]))

    expect(
      %{
        "data" => %{
          "node" => %{
            "id" => "VIEW_1",
            "project" => project_ref(),
            "fields" => connection([field("F_ITER", "Iteration", "ITERATION")])
          }
        }
      },
      fn request ->
        assert request["query"] =~ "HarnessForgeProjectViewFields"
        assert request["variables"] == %{"id" => "VIEW_1", "after" => "view-fields-two"}
      end
    )

    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(connection)

    issue =
      item("ITEM_1", "ISSUE")
      |> Map.put("fieldValues", connection([status_value()], "values-two"))

    draft = item("ITEM_2", "DRAFT_ISSUE")

    expect(page("items", [issue, draft], "items-two"), fn request ->
      assert request["query"] =~ "archivedStates: [ARCHIVED, NOT_ARCHIVED]"
      assert request["query"] =~ "issueState: state"
      assert request["query"] =~ "pullRequestState: state"
      assert request["query"] =~ "fieldValues(first: 50)"
    end)

    labels = label_value(connection([label("LABEL_1", "approved")], "labels-two"))

    expect(
      %{
        "data" => %{
          "node" => %{
            "id" => "ITEM_1",
            "project" => project_ref(),
            "fieldValues" => connection([labels])
          }
        }
      },
      fn request ->
        assert request["query"] =~ "HarnessForgeProjectItemFields"
        assert request["variables"] == %{"id" => "ITEM_1", "after" => "values-two"}
      end
    )

    later_labels = label_value(connection([label("LABEL_2", "reviewed")]))

    expect(
      %{
        "data" => %{
          "node" => %{
            "id" => "ITEM_1",
            "project" => project_ref(),
            "fieldValueByName" => later_labels
          }
        }
      },
      fn request ->
        assert request["query"] =~ "HarnessForgeProjectItemCollection"

        assert request["variables"] == %{
                 "id" => "ITEM_1",
                 "field" => "Labels",
                 "after" => "labels-two"
               }
      end
    )

    assert {:ok, %{"imported" => 2, "complete" => false}} = sync(connection)
    assert cursor(connection)["after"] == "items-two"

    expect(
      page("items", [item("ITEM_3", "PULL_REQUEST"), item("ITEM_4", "REDACTED")]),
      fn request ->
        assert request["variables"]["after"] == "items-two"
      end
    )

    assert {:ok, %{"imported" => 2, "complete" => true}} = sync(connection)
    assert cursor(connection)["stage"] == "project"
    assert {:ok, sources} = Evidence.list_sources()
    assert length(sources) == 8

    assert Enum.all?(
             sources,
             &String.starts_with?(&1["external_id"], "github_projects:#{connection["id"]}:")
           )

    assert Enum.all?(sources, &(&1["latest_revision"]["source_url"] == @url))
    assert Enum.all?(sources, &(&1["latest_revision"]["metadata"]["project_id"] == "PROJECT_7"))
    issue_source = Enum.find(sources, &String.ends_with?(&1["external_id"], ":ITEM_1"))
    assert issue_source["latest_revision"]["body"] =~ "approved"
    assert issue_source["latest_revision"]["body"] =~ "reviewed"

    assert issue_source["latest_revision"]["metadata"]["content_url"] ==
             "https://github.com/other/member/issues/3"

    assert Enum.find(sources, &String.ends_with?(&1["external_id"], ":VIEW_1"))["latest_revision"][
             "body"
           ] =~ "Iteration"

    assert Enum.find(sources, &String.ends_with?(&1["external_id"], ":ITEM_4"))["latest_revision"][
             "metadata"
           ]["redacted"]

    refute GitHubProjects.capabilities()["linked_repository_fetch"]
  end

  test "personal projects use user projectV2 lookup with identical provenance boundaries" do
    url = "https://github.com/users/synthetic/projects/7"
    connection = connect(url)
    project = project(url, "User")

    expect(%{"data" => %{"scope" => %{"projectV2" => project}}}, fn request ->
      assert request["query"] =~ "scope: user(login: $owner)"
      refute request["query"] =~ "scope: organization"
    end)

    assert {:ok, %{"imported" => 1}} = sync(connection)
    assert {:ok, [source]} = Evidence.list_sources()
    assert source["latest_revision"]["metadata"]["owner_kind"] == "user"
    assert source["latest_revision"]["source_url"] == url
  end

  test "project cursor is bound to the connection and URL and rejects malformed state" do
    first = connect()
    second = connect()
    start(first)
    original = Repo.get!(Connection, first["id"]).cursor

    Repo.get!(Connection, second["id"])
    |> Ecto.Changeset.change(cursor: original)
    |> Repo.update!()

    assert {:error, %Error{code: "invalid_cursor"}} = sync(second)

    for malformed <- [
          Map.put(cursor(first), "after", "unseen"),
          Map.put(cursor(first), "stage", "mutation"),
          Map.put(cursor(first), "project_id", nil),
          Map.put(cursor(first), "unexpected", true)
        ] do
      Repo.get!(Connection, first["id"])
      |> Ecto.Changeset.change(cursor: Jason.encode!(malformed))
      |> Repo.update!()

      assert {:error, %Error{code: "invalid_cursor"}} = sync(first)
    end
  end

  test "a repeated top-level cursor fails without advancing or importing the second page" do
    connection = connect()
    start(connection)
    expect(page("fields", [status_field()], "same"))
    assert {:ok, _} = sync(connection)
    previous = Repo.get!(Connection, connection["id"]).cursor
    expect(page("fields", [iteration_field()], "same"))
    assert {:error, %Error{code: "invalid_cursor"}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).cursor == previous
    assert {:ok, sources} = Evidence.list_sources()
    assert length(sources) == 2
  end

  test "replayed pages deduplicate immutable revisions while connections stay independent" do
    first = connect()
    second = connect()
    start(first)
    previous = Repo.get!(Connection, first["id"]).cursor
    expect(page("fields", [status_field()]))
    assert {:ok, %{"imported" => 1}} = sync(first)

    Repo.get!(Connection, first["id"])
    |> Ecto.Changeset.change(cursor: previous)
    |> Repo.update!()

    expect(page("fields", [status_field()]))
    assert {:ok, %{"imported" => 0, "unchanged" => 1}} = sync(first)
    start(second)
    assert Repo.aggregate(Store.scoped(Revision), :count) == 3
  end

  test "foreign project metadata and item membership are rejected despite broad credentials" do
    connection = connect()

    expect(%{
      "data" => %{
        "scope" => %{
          "projectV2" => Map.put(project(), "url", "https://github.com/orgs/other/projects/7")
        }
      }
    })

    assert {:error, %Error{code: "scope_violation"}} = sync(connection)
    assert {:ok, []} = Evidence.list_sources()
    advance_to_items(connection)
    previous = Repo.get!(Connection, connection["id"]).cursor
    bad = put_in(item("ITEM_BAD", "ISSUE"), ["project", "id"], "PROJECT_OTHER")
    expect(page("items", [item("ITEM_GOOD", "ISSUE"), bad]))
    assert {:error, %Error{code: "scope_violation"}} = sync(connection)
    assert Repo.get!(Connection, connection["id"]).cursor == previous
    assert {:ok, [_]} = Evidence.list_sources()
  end

  test "GraphQL HTTP200 errors and partial data never commit and reveal no provider secrets" do
    connection = connect()
    start(connection)
    previous = Repo.get!(Connection, connection["id"]).cursor

    response =
      Map.put(page("fields", [status_field()]), "errors", [
        %{"message" => "raw-provider-secret synthetic-projects-secret", "type" => "INTERNAL"}
      ])

    expect(response)

    logs =
      capture_log(fn ->
        assert {:error, %Error{code: "provider_graphql_error"} = error} = sync(connection)
        refute inspect(error) =~ "secret"
      end)

    refute logs =~ "raw-provider-secret"
    refute logs =~ "synthetic-projects-secret"
    assert Repo.get!(Connection, connection["id"]).cursor == previous
    assert {:ok, [_]} = Evidence.list_sources()
  end

  test "GraphQL and HTTP rate limits are safe retryable errors without automatic retry" do
    connection = connect()
    expect(%{"errors" => [%{"type" => "RATE_LIMITED", "message" => "private rate context"}]})
    assert {:error, %Error{code: "rate_limited", retryable: true}} = sync(connection)

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "120")
      |> Plug.Conn.send_resp(429, "private rate context")
    end)

    assert {:error,
            %Error{code: "rate_limited", retryable: true, details: ["retry_after_seconds:120"]}} =
             sync(connection)

    assert is_nil(Repo.get!(Connection, connection["id"]).cursor)
  end

  test "forbidden/null project and authentication failures revoke the selected source" do
    for response <- [
          %{"errors" => [%{"type" => "FORBIDDEN", "message" => "hidden"}]},
          %{"data" => %{"scope" => %{"projectV2" => nil}}}
        ] do
      selected = connect()
      expect(response)
      assert {:error, %Error{code: "source_access_denied"}} = sync(selected)
      assert Repo.get!(Connection, selected["id"]).status == "revoked"
    end

    selected = connect()
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 401, "hidden"))
    assert {:error, %Error{code: "source_access_denied"}} = sync(selected)
    assert Repo.get!(Connection, selected["id"]).status == "revoked"
  end

  test "classic-token scopes are checked while fine-grained/App permissions are provider enforced" do
    selected = connect()

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-oauth-scopes", "repo, user")
      |> Req.Test.json(%{"data" => %{"scope" => %{"projectV2" => project()}}})
    end)

    assert {:error, %Error{code: "credential_scope_missing"}} = sync(selected)
    assert {:ok, []} = Evidence.list_sources()
    expect(%{"data" => %{"scope" => %{"projectV2" => project()}}})
    assert {:ok, %{"imported" => 1}} = sync(selected)
  end

  test "missing environment credentials fail locally before any API call" do
    selected = connect()
    System.delete_env(@ref)
    assert {:error, %Error{code: "credential_unavailable"}} = sync(selected)
  end

  test "undisclosed classic scopes and GitHub canonical owner casing remain usable" do
    selected = connect()

    returned =
      project("https://github.com/orgs/Synthetic/projects/7")
      |> put_in(["owner", "login"], "Synthetic")

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-oauth-scopes", "")
      |> Req.Test.json(%{"data" => %{"scope" => %{"projectV2" => returned}}})
    end)

    assert {:ok, %{"imported" => 1}} = sync(selected)
    assert {:ok, [source]} = Evidence.list_sources()
    assert source["latest_revision"]["source_url"] == @url
    expect(%{"errors" => [%{"type" => "INSUFFICIENT_SCOPES", "message" => "private"}]})
    assert {:error, %Error{code: "credential_scope_missing"}} = sync(selected)
  end

  test "invalid nested page and foreign nested membership roll back the entire item page" do
    selected = connect()
    advance_to_items(selected)
    original = Repo.get!(Connection, selected["id"]).cursor

    for next_node <- [
          %{
            "id" => "ITEM_1",
            "project" => project_ref(),
            "fieldValues" => connection([status_value()], "same")
          },
          %{
            "id" => "ITEM_1",
            "project" => %{"id" => "OTHER", "url" => @url},
            "fieldValues" => connection([])
          }
        ] do
      truncated =
        item("ITEM_1", "ISSUE") |> Map.put("fieldValues", connection([status_value()], "same"))

      expect(page("items", [truncated]))
      expect(%{"data" => %{"node" => next_node}})
      assert {:error, %Error{code: code}} = sync(selected)
      assert code in ["invalid_cursor", "scope_violation"]
      assert Repo.get!(Connection, selected["id"]).cursor == original
      assert {:ok, [_]} = Evidence.list_sources()
    end
  end

  test "nested request budget fails visibly rather than importing a truncated item" do
    selected = connect()
    advance_to_items(selected)
    original = Repo.get!(Connection, selected["id"]).cursor
    value = label_value(connection([label("L_0", "first")], "labels-1"))
    candidate = item("ITEM_1", "ISSUE") |> Map.put("fieldValues", connection([value]))
    expect(page("items", [candidate]))

    Req.Test.expect(__MODULE__, 31, fn conn ->
      {request, conn} = read_request(conn)
      "labels-" <> number = request["variables"]["after"]
      n = String.to_integer(number)
      value = label_value(connection([label("L_#{n}", "value #{n}")], "labels-#{n + 1}"))

      Req.Test.json(conn, %{
        "data" => %{
          "node" => %{"id" => "ITEM_1", "project" => project_ref(), "fieldValueByName" => value}
        }
      })
    end)

    assert {:error, %Error{code: "nested_pagination_limit"}} = sync(selected)
    assert Repo.get!(Connection, selected["id"]).cursor == original
    assert {:ok, [_]} = Evidence.list_sources()
  end

  test "supported scalar/custom field values and every nested collection are normalized" do
    selected = connect()
    advance_to_items(selected)

    scalars =
      [
        {"ProjectV2ItemFieldTextValue", %{"text" => "explicit approval"}},
        {"ProjectV2ItemFieldDateValue", %{"date" => "2026-10-31"}},
        {"ProjectV2ItemFieldNumberValue", %{"number" => 3.5}},
        {"ProjectV2ItemFieldSingleSelectValue", %{"name" => "Done", "optionId" => "done"}},
        {"ProjectV2ItemFieldIterationValue",
         %{
           "title" => "Iteration 1",
           "iterationId" => "it-1",
           "startDate" => "2026-10-31",
           "duration" => 14
         }},
        {"ProjectV2ItemFieldMultiSelectValue",
         %{"value" => "A", "options" => [%{"id" => "a", "name" => "A"}]}},
        {"ProjectV2ItemFieldRepositoryValue",
         %{
           "repository" => %{
             "id" => "R_1",
             "nameWithOwner" => "other/member",
             "url" => "https://github.com/other/member"
           }
         }},
        {"ProjectV2ItemFieldMilestoneValue",
         %{
           "milestone" => %{
             "id" => "M_1",
             "title" => "M1",
             "url" => "https://github.com/other/member/milestone/1"
           }
         }},
        {"ProjectV2ItemIssueFieldValue",
         %{
           "issueFieldValue" => %{
             "id" => "IV_1",
             "__typename" => "IssueFieldNumberValue",
             "numberValue" => 8.5
           }
         }}
      ]
      |> Enum.with_index()
      |> Enum.map(fn {{type, value}, n} ->
        Map.merge(value, %{"__typename" => type, "field" => field("F_#{n}", "Value #{n}")})
      end)

    collections =
      [
        {"ProjectV2ItemFieldUserValue", "users",
         %{"id" => "U_1", "login" => "synthetic", "url" => "https://github.com/synthetic"}},
        {"ProjectV2ItemFieldPullRequestValue", "pullRequests",
         %{
           "id" => "PR_1",
           "number" => 3,
           "title" => "PR",
           "url" => "https://github.com/other/member/pull/3"
         }},
        {"ProjectV2ItemFieldReviewerValue", "reviewers",
         %{
           "id" => "T_1",
           "__typename" => "Team",
           "name" => "Team",
           "url" => "https://github.com/orgs/synthetic/teams/team"
         }}
      ]
      |> Enum.map(fn {type, key, node} ->
        %{"__typename" => type, "field" => field("F_#{key}", key), key => connection([node])}
      end)

    candidate =
      item("ITEM_VALUES", "ISSUE") |> Map.put("fieldValues", connection(scalars ++ collections))

    expect(page("items", [candidate]))
    assert {:ok, %{"imported" => 1, "complete" => true}} = sync(selected)
    assert {:ok, [source]} = Evidence.search("explicit approval")
    assert source["latest_revision"]["body"] =~ "8.5"
  end

  test "oversized/invalid item page commits no revisions search entries or cursor" do
    selected = connect()
    advance_to_items(selected)
    original = Repo.get!(Connection, selected["id"]).cursor
    bad = put_in(item("ITEM_BIG", "ISSUE"), ["content", "body"], String.duplicate("x", 1_048_577))
    expect(page("items", [item("ITEM_GOOD", "ISSUE"), bad]))
    assert {:error, :file_too_large} = sync(selected)
    assert Repo.get!(Connection, selected["id"]).cursor == original
    assert {:ok, []} = Evidence.search("selected member body")
    assert {:ok, [_]} = Evidence.list_sources()
  end

  test "each nested user/reviewer/PR collection follows its own cursor and field identity" do
    selected = connect()
    advance_to_items(selected)

    types = [
      {"ProjectV2ItemFieldUserValue", "users",
       %{"id" => "U", "login" => "synthetic", "url" => "https://github.com/synthetic"}},
      {"ProjectV2ItemFieldReviewerValue", "reviewers",
       %{
         "id" => "T",
         "__typename" => "Team",
         "name" => "Reviewers",
         "url" => "https://github.com/orgs/synthetic/teams/reviewers"
       }},
      {"ProjectV2ItemFieldPullRequestValue", "pullRequests",
       %{
         "id" => "P",
         "title" => "PR",
         "number" => 3,
         "url" => "https://github.com/other/member/pull/3"
       }}
    ]

    values =
      Enum.map(types, fn {type, key, value} ->
        %{
          "__typename" => type,
          "field" => field("F_#{key}", key),
          key => connection([Map.update!(value, "id", &(&1 <> "1"))], "#{key}-2")
        }
      end)

    candidate = item("ITEM_COLLECTIONS", "ISSUE") |> Map.put("fieldValues", connection(values))
    expect(page("items", [candidate]))

    for {type, key, value} <- types do
      fetched = %{
        "__typename" => type,
        "field" => field("F_#{key}", key),
        key => connection([Map.update!(value, "id", &(&1 <> "2"))])
      }

      expect(
        %{
          "data" => %{
            "node" => %{
              "id" => "ITEM_COLLECTIONS",
              "project" => project_ref(),
              "fieldValueByName" => fetched
            }
          }
        },
        fn request ->
          assert request["variables"] == %{
                   "id" => "ITEM_COLLECTIONS",
                   "field" => key,
                   "after" => "#{key}-2"
                 }
        end
      )
    end

    assert {:ok, %{"imported" => 1, "complete" => true}} = sync(selected)
    assert {:ok, sources} = Evidence.list_sources()

    body =
      Enum.find(sources, &String.ends_with?(&1["external_id"], ":ITEM_COLLECTIONS"))[
        "latest_revision"
      ]["body"]

    for id <- ~w(U1 U2 T1 T2 P1 P2), do: assert(body =~ id)
  end

  test "view grouping and sorting connections paginate while explicit null metadata is preserved" do
    selected = connect()
    start(selected)
    expect(page("fields", []))
    assert {:ok, _} = sync(selected)
    keys = ~w(groupByFields verticalGroupByFields sortByFields)

    board =
      Enum.reduce(keys, view(), fn key, acc ->
        value =
          if key == "sortByFields",
            do: %{"direction" => "ASC", "field" => field("F_FIRST", "First")},
            else: field("F_FIRST", "First")

        Map.put(acc, key, connection([value], "#{key}-2"))
      end)

    nullable =
      view()
      |> Map.merge(%{
        "id" => "VIEW_NULL",
        "number" => 2,
        "name" => "No grouping",
        "groupByFields" => nil,
        "verticalGroupByFields" => nil,
        "sortByFields" => nil
      })

    expect(page("views", [board, nullable]))

    for key <- keys do
      value =
        if key == "sortByFields",
          do: %{"direction" => "DESC", "field" => field("F_NEXT", "Next")},
          else: field("F_NEXT", "Next")

      expect(
        %{
          "data" => %{
            "node" => %{"id" => "VIEW_1", "project" => project_ref(), key => connection([value])}
          }
        },
        fn request ->
          assert request["query"] =~ "#{key}(first: 50, after: $after)"
          assert request["variables"]["after"] == "#{key}-2"
        end
      )
    end

    assert {:ok, %{"imported" => 2, "complete" => false}} = sync(selected)
    assert {:ok, sources} = Evidence.list_sources()
    source = Enum.find(sources, &String.ends_with?(&1["external_id"], ":VIEW_NULL"))
    assert source["latest_revision"]["body"] =~ "\"groupByFields\": null"
  end

  test "malformed scalar/nested provider data returns a safe error instead of an exception" do
    selected = connect()
    advance_to_items(selected)
    original = Repo.get!(Connection, selected["id"]).cursor

    for malformed <- [
          %{
            "__typename" => "ProjectV2ItemFieldTextValue",
            "field" => "private malformed field",
            "text" => "secret"
          },
          %{"__typename" => "NewUnsupportedFieldValue"}
        ] do
      candidate = item("ITEM_BAD", "ISSUE") |> Map.put("fieldValues", connection([malformed]))
      expect(page("items", [candidate]))
      assert {:error, %Error{code: "invalid_provider_response"} = error} = sync(selected)
      refute inspect(error) =~ "secret"
      assert Repo.get!(Connection, selected["id"]).cursor == original
    end

    for malformed <- ["private-provider-sentinel", [], 17] do
      value = label_value(connection([label("FIRST", "first")], "labels-next"))
      candidate = item("ITEM_BAD", "ISSUE") |> Map.put("fieldValues", connection([value]))
      expect(page("items", [candidate]))

      expect(%{
        "data" => %{
          "node" => %{
            "id" => "ITEM_BAD",
            "project" => project_ref(),
            "fieldValueByName" => malformed
          }
        }
      })

      logs =
        capture_log(fn ->
          assert {:error, %Error{code: "invalid_provider_response"} = error} = sync(selected)
          refute inspect(error) =~ "private-provider-sentinel"
        end)

      refute logs =~ "private-provider-sentinel"
      assert Repo.get!(Connection, selected["id"]).cursor == original
      assert {:ok, [_]} = Evidence.list_sources()
    end

    expect(%{"errors" => [%{"extensions" => "private raw context"}], "data" => nil})
    assert {:error, %Error{code: "provider_graphql_error"}} = sync(selected)
  end

  defp connect(url \\ @url) do
    {:ok, connection} =
      Evidence.connect(%{
        "provider" => "github_projects",
        "name" => "Synthetic selected board",
        "config" => config(url)
      })

    connection
  end

  defp config(url \\ @url),
    do: %{"endpoint" => "https://api.github.com", "project_url" => url, "credential_ref" => @ref}

  defp sync(selected), do: Evidence.sync(selected["id"], plug: {Req.Test, __MODULE__})
  defp cursor(selected), do: Repo.get!(Connection, selected["id"]).cursor |> Jason.decode!()

  defp start(selected) do
    expect(%{"data" => %{"scope" => %{"projectV2" => project()}}}, fn request ->
      assert request["query"] =~ "scope: organization(login: $owner)"
      refute request["query"] =~ "mutation"
    end)

    assert {:ok, %{"imported" => 1, "complete" => false}} = sync(selected)
  end

  defp advance_to_items(selected) do
    start(selected)
    expect(page("fields", []))
    assert {:ok, _} = sync(selected)
    expect(page("views", []))
    assert {:ok, _} = sync(selected)
  end

  defp expect(response, check \\ fn _ -> :ok end) do
    Req.Test.expect(__MODULE__, fn conn ->
      {request, conn} = read_request(conn)
      check.(request)

      conn
      |> Plug.Conn.put_resp_header("x-oauth-scopes", "repo, read:project")
      |> Req.Test.json(response)
    end)
  end

  defp read_request(conn) do
    assert conn.method == "POST"
    assert conn.host == "api.github.com"
    assert conn.request_path == "/graphql"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-projects-secret"]
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    assert Map.keys(request) |> Enum.sort() == ["query", "variables"]
    assert String.starts_with?(request["query"], "query HarnessForge")
    refute request["query"] =~ "synthetic-projects-secret"

    if directory = System.get_env("HARNESSFORGE_GRAPHQL_VALIDATION_DIR") do
      File.mkdir_p!(directory)
      digest = :crypto.hash(:sha256, request["query"]) |> Base.encode16(case: :lower)
      File.write!(Path.join(directory, digest <> ".graphql"), request["query"])
    end

    {request, conn}
  end

  defp project(url \\ @url, owner_type \\ "Organization"),
    do: %{
      "id" => "PROJECT_7",
      "url" => url,
      "number" => 7,
      "title" => "Synthetic board",
      "shortDescription" => "Review workflow",
      "readme" => "Approved evidence only",
      "closed" => false,
      "updatedAt" => @time,
      "owner" => %{"__typename" => owner_type, "login" => "synthetic"}
    }

  defp project_ref, do: %{"id" => "PROJECT_7", "url" => @url}

  defp page(stage, nodes, after_cursor \\ nil),
    do: %{
      "data" => %{
        "scope" => %{"projectV2" => Map.put(project(), stage, connection(nodes, after_cursor))}
      }
    }

  defp connection(nodes, after_cursor \\ nil),
    do: %{
      "nodes" => nodes,
      "pageInfo" => %{"hasNextPage" => not is_nil(after_cursor), "endCursor" => after_cursor}
    }

  defp field(id, name, type \\ "TEXT"), do: %{"id" => id, "name" => name, "dataType" => type}

  defp status_field,
    do:
      field("F_STATUS", "Status", "SINGLE_SELECT")
      |> Map.merge(%{
        "__typename" => "ProjectV2SingleSelectField",
        "project" => project_ref(),
        "updatedAt" => @time,
        "options" => [
          %{"id" => "done", "name" => "Done", "color" => "GREEN", "description" => "Reviewed"}
        ]
      })

  defp iteration_field,
    do:
      field("F_ITER", "Iteration", "ITERATION")
      |> Map.merge(%{
        "__typename" => "ProjectV2IterationField",
        "project" => project_ref(),
        "updatedAt" => @time,
        "configuration" => %{
          "duration" => 14,
          "startDay" => 1,
          "iterations" => [%{"id" => "it-1", "title" => "Iteration 1"}],
          "completedIterations" => []
        }
      })

  defp view,
    do: %{
      "id" => "VIEW_1",
      "name" => "Delivery board",
      "number" => 1,
      "layout" => "BOARD_LAYOUT",
      "filter" => "is:open",
      "project" => project_ref(),
      "fields" => connection([field("F_STATUS", "Status", "SINGLE_SELECT")]),
      "groupByFields" => connection([field("F_STATUS", "Status", "SINGLE_SELECT")]),
      "verticalGroupByFields" => connection([]),
      "sortByFields" =>
        connection([
          %{"field" => field("F_ITER", "Iteration", "ITERATION"), "direction" => "ASC"}
        ])
    }

  defp status_value,
    do: %{
      "__typename" => "ProjectV2ItemFieldSingleSelectValue",
      "field" => field("F_STATUS", "Status", "SINGLE_SELECT"),
      "name" => "Done",
      "optionId" => "done"
    }

  defp label(id, name),
    do: %{"id" => id, "name" => name, "description" => nil, "color" => "aabbcc"}

  defp label_value(labels),
    do: %{
      "__typename" => "ProjectV2ItemFieldLabelValue",
      "field" => field("F_LABEL", "Labels", "LABELS"),
      "labels" => labels
    }

  defp item(id, type) do
    content =
      case type do
        "REDACTED" ->
          nil

        "DRAFT_ISSUE" ->
          %{
            "__typename" => "DraftIssue",
            "id" => "DRAFT_#{id}",
            "title" => "Draft #{id}",
            "body" => "Synthetic draft",
            "updatedAt" => @time
          }

        _ ->
          %{
            "__typename" => if(type == "ISSUE", do: "Issue", else: "PullRequest"),
            "id" => "CONTENT_#{id}",
            "title" => "Member #{id}",
            "body" => "selected member body",
            "number" => 3,
            "url" =>
              "https://github.com/other/member/#{if(type == "ISSUE", do: "issues", else: "pull")}/3",
            "state" => "OPEN",
            "updatedAt" => @time,
            "repository" => %{"nameWithOwner" => "other/member"}
          }
      end

    %{
      "id" => id,
      "type" => type,
      "isArchived" => false,
      "updatedAt" => @time,
      "project" => project_ref(),
      "content" => content,
      "fieldValues" => connection([])
    }
  end
end
