defmodule HarnessForge.Connectors.GitHubProjects do
  @moduledoc """
  Read-only GitHub Projects v2 snapshots for one explicitly selected project.

  Top-level pages are resumable; nested connections are exhausted within a bounded
  request budget before any page is returned. Partial GraphQL data never commits.
  Linked issue/PR URLs are evidence data and are never followed by this adapter.
  """
  @behaviour HarnessForge.Contracts.Connector
  alias HarnessForge.Connectors.Common, as: C

  @size 20
  # Conservative connection-node bound: 20 items × 50 fieldValues ×
  # (4 collection branches × 50 + the value itself) ≈ 201,000, below GitHub's
  # separate 500,000-node limit even if union branches are summed.
  @nested_size 50
  @requests 32
  @max_pages 100
  @page_info "pageInfo { hasNextPage endCursor }"
  @field_ref "... on ProjectV2FieldCommon { id name dataType }"
  @project_ref "project { id url }"
  @view_connections ~w(fields groupByFields verticalGroupByFields sortByFields)
  @collection_values %{
    "ProjectV2ItemFieldLabelValue" => {"labels", "id name description color"},
    "ProjectV2ItemFieldUserValue" => {"users", "id login name url"},
    "ProjectV2ItemFieldPullRequestValue" => {"pullRequests", "id number title url state"},
    "ProjectV2ItemFieldReviewerValue" =>
      {"reviewers",
       "__typename ... on Node { id } ... on Actor { login url } ... on Team { name slug url } ... on EnterpriseTeam { name slug }"}
  }
  @scalar_values %{
    "ProjectV2ItemFieldTextValue" => "text",
    "ProjectV2ItemFieldDateValue" => "date",
    "ProjectV2ItemFieldNumberValue" => "number",
    "ProjectV2ItemFieldSingleSelectValue" => "name optionId",
    "ProjectV2ItemFieldIterationValue" => "title iterationId startDate duration",
    "ProjectV2ItemFieldMultiSelectValue" => "value options { id name color description }",
    "ProjectV2ItemFieldRepositoryValue" => "repository { id nameWithOwner url }",
    "ProjectV2ItemFieldMilestoneValue" => "milestone { id title description url state dueOn }",
    "ProjectV2ItemIssueFieldValue" =>
      "issueFieldValue { __typename ... on IssueFieldTextValue { id textValue: value } ... on IssueFieldDateValue { id dateValue: value } ... on IssueFieldNumberValue { id numberValue: value } ... on IssueFieldSingleSelectValue { id name optionId color description singleSelectValue: value } ... on IssueFieldMultiSelectValue { id multiSelectValue: value options { id name color description } } }"
  }

  @impl true
  def validate_config(config) do
    with true <- C.keys(config, ~w(endpoint project_url credential_ref)),
         true <- config["endpoint"] == "https://api.github.com",
         true <- is_binary(config["credential_ref"]) and C.reference?(config["credential_ref"]),
         {:ok, _} <- selection(config["project_url"]) do
      {:ok, config}
    else
      _ -> C.error("invalid_connector_config")
    end
  end

  @impl true
  def capabilities do
    %{
      "read_only" => true,
      "selected_project" => true,
      "kinds" => ~w(project field view item),
      "pagination" => true,
      "nested_pagination" => true,
      "deletion_detection" => false,
      "live_acl" => false,
      "linked_repository_fetch" => false,
      "max_requests_per_page" => @requests,
      "page_size" => @size,
      "nested_page_size" => @nested_size,
      "classic_token_scope" => "read:project",
      "fine_grained_permission" => "Projects: read (where supported by GitHub)"
    }
  end

  @impl true
  def fetch_page(config, cursor, context) do
    with {:ok, config} <- validate_config(config),
         {:ok, selected} <- selection(config["project_url"]),
         {:ok, connection_id} <- C.context_id(context),
         {:ok, credential} <- C.credential(config["credential_ref"], true),
         {:ok, state} <- state(cursor, selected, connection_id),
         {:ok, result} <- fetch(selected, state, connection_id, headers(credential), context) do
      {:ok, result}
    end
  end

  defp selection(url) when is_binary(url) do
    case Regex.run(
           ~r/\Ahttps:\/\/github\.com\/(orgs|users)\/([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)\/projects\/([1-9][0-9]{0,7})\z/,
           url
         ) do
      [_, kind, owner, number] ->
        {:ok,
         %{
           "url" => url,
           "owner_kind" => if(kind == "orgs", do: "organization", else: "user"),
           "owner" => owner,
           "number" => String.to_integer(number)
         }}

      _ ->
        C.error("invalid_connector_config")
    end
  end

  defp selection(_), do: C.error("invalid_connector_config")

  defp state(cursor, selected, id) do
    scope = :crypto.hash(:sha256, id <> "\n" <> selected["url"]) |> Base.encode16(case: :lower)

    initial = %{
      "version" => 1,
      "scope" => scope,
      "stage" => "project",
      "project_id" => nil,
      "after" => nil,
      "seen" => [],
      "pages" => 0
    }

    with {:ok, state} <- C.cursor(cursor, initial),
         true <- C.keys(state, Map.keys(initial)) and map_size(state) == map_size(initial),
         true <- state["version"] == 1 and state["scope"] == scope,
         true <- state["stage"] in ~w(project fields views items),
         true <- cursor_value?(state["after"]),
         true <- is_integer(state["pages"]) and state["pages"] in 0..@max_pages,
         true <-
           is_list(state["seen"]) and length(state["seen"]) == state["pages"] and
             Enum.all?(state["seen"], &hash?/1) and
             length(Enum.uniq(state["seen"])) == length(state["seen"]),
         true <-
           (state["stage"] == "project" and is_nil(state["project_id"]) and
              is_nil(state["after"]) and state["pages"] == 0) or
             (state["stage"] != "project" and node_id?(state["project_id"])),
         true <-
           (is_nil(state["after"]) and state["pages"] == 0) or
             (is_binary(state["after"]) and hash(state["after"]) in state["seen"]) do
      {:ok, state}
    else
      _ -> C.error("invalid_cursor")
    end
  end

  defp fetch(selected, state, id, headers, context) do
    with {:ok, data, budget} <-
           request(
             query(selected, state["stage"]),
             variables(selected, state),
             headers,
             context,
             @requests
           ),
         {:ok, project} <- project(data, selected, state["project_id"]) do
      if state["stage"] == "project" do
        with true <- text?(project["title"]) and optional_text?(project["shortDescription"]),
             true <- optional_text?(project["readme"]) and is_boolean(project["closed"]) do
          body = %{
            "title" => project["title"],
            "description" => project["shortDescription"],
            "readme" => project["readme"],
            "closed" => project["closed"]
          }

          doc = document(id, project["id"], project["title"], body, selected, project, "project")
          page([doc], transition(state, "fields", project["id"]), false)
        else
          _ -> C.error("invalid_provider_response")
        end
      else
        fetch_collection(project, selected, state, id, headers, context, budget)
      end
    end
  end

  defp fetch_collection(project, selected, state, id, headers, context, budget) do
    stage = state["stage"]

    with {:ok, nodes, after_cursor} <-
           connection(project[stage], @size, state["after"], state["seen"]),
         {:ok, documents, _} <-
           reduce(nodes, budget, fn node, remaining ->
             normalize(stage, node, selected, project, id, headers, context, remaining)
           end),
         {:ok, next, complete} <- continuation(state, after_cursor) do
      page(documents, next, complete)
    end
  end

  defp normalize("fields", field, selected, project, id, _, _, budget) do
    with :ok <- member(field, project),
         true <- field?(field),
         true <- valid_field_definition?(field) do
      {:ok, document(id, field["id"], field["name"], field, selected, project, "field"), budget}
    else
      false -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp normalize("views", view, selected, project, id, headers, context, budget) do
    with :ok <- member(view, project),
         true <- node_id?(view["id"]) and text?(view["name"]) and C.sequence?(view["number"]),
         true <- view["layout"] in ~w(BOARD_LAYOUT TABLE_LAYOUT ROADMAP_LAYOUT),
         true <- optional_text?(view["filter"]),
         {:ok, view, budget} <-
           reduce(@view_connections, {view, budget}, fn key, {acc, remaining} ->
             with {:ok, fields, remaining} <-
                    view_connection(view[key], remaining, fn after_cursor, left ->
                      query = view_query(key)

                      with {:ok, data, left} <-
                             request(
                               query,
                               %{"id" => view["id"], "after" => after_cursor},
                               headers,
                               context,
                               left
                             ),
                           :ok <- node_member(data["node"], view["id"], project) do
                        {:ok, data["node"][key], left}
                      end
                    end),
                  true <- is_nil(fields) or Enum.all?(fields, &view_field?(key, &1)) do
               {:ok, key, {Map.put(acc, key, fields), remaining}}
             else
               false -> C.error("invalid_provider_response")
               error -> error
             end
           end)
           |> view_result() do
      {:ok, document(id, view["id"], view["name"], view, selected, project, "view"), budget}
    else
      false -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp normalize("items", item, selected, project, id, headers, context, budget) do
    with :ok <- member(item, project),
         true <-
           node_id?(item["id"]) and item["type"] in ~w(DRAFT_ISSUE ISSUE PULL_REQUEST REDACTED),
         true <- is_boolean(item["isArchived"]) and C.timestamp?(item["updatedAt"]),
         {:ok, title, content_meta} <- content(item),
         {:ok, values, budget} <-
           nested(item["fieldValues"], nil, [], [], budget, fn after_cursor, left ->
             with {:ok, data, left} <-
                    request(
                      item_values_query(),
                      %{"id" => item["id"], "after" => after_cursor},
                      headers,
                      context,
                      left
                    ),
                  :ok <- node_member(data["node"], item["id"], project) do
               {:ok, data["node"]["fieldValues"], left}
             end
           end),
         {:ok, values, budget} <-
           reduce(values, budget, &normalize_value(&1, item, project, headers, context, &2)) do
      body = Map.put(item, "fieldValues", values)
      metadata = Map.merge(content_meta, %{"item_id" => item["id"], "item_type" => item["type"]})

      doc =
        document(
          id,
          item["id"],
          title,
          body,
          selected,
          project,
          "item",
          metadata,
          item["updatedAt"]
        )

      {:ok, doc, budget}
    else
      false -> C.error("invalid_provider_response")
      error -> error
    end
  end

  defp normalize_value(value, item, project, headers, context, budget) when is_map(value) do
    type = value["__typename"]

    cond do
      not field?(value["field"]) ->
        C.error("invalid_provider_response")

      Map.has_key?(@scalar_values, type) ->
        if valid_scalar?(type, value),
          do: {:ok, value, budget},
          else: C.error("invalid_provider_response")

      Map.has_key?(@collection_values, type) ->
        {key, _} = @collection_values[type]

        with {:ok, nodes, remaining} <-
               nested(value[key], nil, [], [], budget, fn after_cursor, left ->
                 variables = %{
                   "id" => item["id"],
                   "field" => value["field"]["name"],
                   "after" => after_cursor
                 }

                 with {:ok, data, left} <-
                        request(collection_query(type), variables, headers, context, left),
                      :ok <- node_member(data["node"], item["id"], project),
                      fetched when is_map(fetched) <- data["node"]["fieldValueByName"],
                      true <-
                        fetched["__typename"] == type and field?(fetched["field"]) and
                          fetched["field"]["id"] == value["field"]["id"] do
                   {:ok, fetched[key], left}
                 else
                   false -> C.error("scope_violation")
                   {:error, _} = error -> error
                   _ -> C.error("invalid_provider_response")
                 end
               end),
             true <- Enum.all?(nodes, &collection_node?(key, &1)) do
          {:ok, Map.put(value, key, nodes), remaining}
        else
          false -> C.error("invalid_provider_response")
          error -> error
        end

      true ->
        C.error("unsupported_project_field_value")
    end
  end

  defp normalize_value(_, _, _, _, _, _), do: C.error("invalid_provider_response")

  # These view connections are nullable in the upstream schema. Preserve an
  # explicit null rather than inventing an empty configuration or fetching more.
  defp view_connection(nil, budget, _), do: {:ok, nil, budget}

  defp view_connection(connection, budget, fetch_next),
    do: nested(connection, nil, [], [], budget, fetch_next)

  # Exhaust every nested connection or reject the whole page. Cursor hashes catch
  # repeated/oscillating cursors without persisting provider text or whole values.
  defp nested(current, previous, seen, accumulated, budget, fetch_next) do
    with {:ok, nodes, next} <- connection(current, @nested_size, previous, seen),
         true <- length(accumulated) + length(nodes) <= 10_000 do
      if next do
        with {:ok, following, budget} <- fetch_next.(next, budget) do
          nested(following, next, [hash(next) | seen], accumulated ++ nodes, budget, fetch_next)
        end
      else
        all = accumulated ++ nodes
        if unique_nodes?(all), do: {:ok, all, budget}, else: C.error("invalid_provider_response")
      end
    else
      false -> C.error("nested_pagination_limit")
      error -> error
    end
  end

  defp connection(
         %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more, "endCursor" => next}},
         size,
         previous,
         seen
       )
       when is_list(nodes) and length(nodes) <= size and is_boolean(more) do
    cond do
      not Enum.all?(nodes, &is_map/1) ->
        C.error("invalid_provider_response")

      not unique_nodes?(nodes) ->
        C.error("invalid_provider_response")

      not more and cursor_value?(next) ->
        {:ok, nodes, nil}

      more and nodes != [] and is_binary(next) and cursor_value?(next) and next != previous and
          hash(next) not in seen ->
        {:ok, nodes, next}

      true ->
        C.error("invalid_cursor")
    end
  end

  defp connection(_, _, _, _), do: C.error("invalid_provider_response")

  defp continuation(state, nil) do
    case state["stage"] do
      "fields" -> {:ok, transition(state, "views", state["project_id"]), false}
      "views" -> {:ok, transition(state, "items", state["project_id"]), false}
      "items" -> {:ok, transition(state, "project", nil), true}
    end
  end

  defp continuation(state, next) do
    if state["pages"] < @max_pages do
      {:ok,
       %{
         state
         | "after" => next,
           "pages" => state["pages"] + 1,
           "seen" => [hash(next) | state["seen"]]
       }, false}
    else
      C.error("pagination_limit")
    end
  end

  defp transition(state, stage, project_id),
    do: %{
      state
      | "stage" => stage,
        "project_id" => project_id,
        "after" => nil,
        "seen" => [],
        "pages" => 0
    }

  defp project(%{"scope" => %{"projectV2" => project}}, selected, expected)
       when is_map(project) do
    owner = project["owner"]
    expected_type = if selected["owner_kind"] == "organization", do: "Organization", else: "User"

    if node_id?(project["id"]) and (is_nil(expected) or expected == project["id"]) and
         same_project_url?(project["url"], selected["url"]) and
         project["number"] == selected["number"] and
         C.timestamp?(project["updatedAt"]) and is_map(owner) and
         owner["__typename"] == expected_type and
         is_binary(owner["login"]) and
         String.downcase(owner["login"]) == String.downcase(selected["owner"]),
       do: {:ok, project},
       else: C.error("scope_violation")
  end

  defp project(%{"scope" => nil}, _, _), do: C.error("source_access_denied")
  defp project(%{"scope" => %{"projectV2" => nil}}, _, _), do: C.error("source_access_denied")
  defp project(_, _, _), do: C.error("invalid_provider_response")

  defp member(%{"project" => %{"id" => id, "url" => url}}, project) do
    if id == project["id"] and same_project_url?(url, project["url"]),
      do: :ok,
      else: C.error("scope_violation")
  end

  defp member(_, _), do: C.error("scope_violation")

  defp node_member(%{"id" => id} = node, expected, project) when id == expected,
    do: member(node, project)

  defp node_member(_, _, _), do: C.error("scope_violation")

  defp content(%{"type" => "REDACTED", "content" => nil}),
    do: {:ok, "Redacted project item", %{"redacted" => true}}

  defp content(%{"type" => type, "content" => content})
       when is_map(content) and type in ~w(DRAFT_ISSUE ISSUE PULL_REQUEST) do
    expected =
      %{"DRAFT_ISSUE" => "DraftIssue", "ISSUE" => "Issue", "PULL_REQUEST" => "PullRequest"}[type]

    if content["__typename"] == expected and node_id?(content["id"]) and text?(content["title"]) and
         optional_text?(content["body"]) and C.timestamp?(content["updatedAt"]) and
         (type == "DRAFT_ISSUE" or
            (github_content_url?(content["url"]) and C.sequence?(content["number"]))) do
      {:ok, content["title"],
       %{"content_id" => content["id"], "content_url" => content["url"], "redacted" => false}}
    else
      C.error("invalid_provider_response")
    end
  end

  defp content(_), do: C.error("invalid_provider_response")

  defp field?(field) when is_map(field),
    do: node_id?(field["id"]) and text?(field["name"]) and text?(field["dataType"])

  defp field?(_), do: false

  defp valid_field_definition?(%{"__typename" => type} = field)
       when type in ["ProjectV2SingleSelectField", "ProjectV2MultiSelectField"],
       do:
         bounded_list?(field["options"]) and
           Enum.all?(field["options"], &(is_map(&1) and text?(&1["id"]) and text?(&1["name"])))

  defp valid_field_definition?(%{
         "__typename" => "ProjectV2IterationField",
         "configuration" => config
       })
       when is_map(config),
       do:
         bounded_list?(config["iterations"]) and bounded_list?(config["completedIterations"]) and
           Enum.all?(
             config["iterations"] ++ config["completedIterations"],
             &(is_map(&1) and text?(&1["id"]) and text?(&1["title"]))
           )

  defp valid_field_definition?(%{"__typename" => "ProjectV2Field"}), do: true
  defp valid_field_definition?(_), do: false

  defp valid_scalar?("ProjectV2ItemFieldTextValue", value), do: optional_text?(value["text"])

  defp valid_scalar?("ProjectV2ItemFieldDateValue", value),
    do: is_nil(value["date"]) or date?(value["date"])

  defp valid_scalar?("ProjectV2ItemFieldNumberValue", value),
    do: is_nil(value["number"]) or is_number(value["number"])

  defp valid_scalar?("ProjectV2ItemFieldSingleSelectValue", value),
    do: text?(value["name"]) and text?(value["optionId"])

  defp valid_scalar?("ProjectV2ItemFieldIterationValue", value),
    do:
      text?(value["title"]) and text?(value["iterationId"]) and date?(value["startDate"]) and
        is_integer(value["duration"]) and value["duration"] > 0

  defp valid_scalar?("ProjectV2ItemFieldMultiSelectValue", value),
    do:
      optional_text?(value["value"]) and bounded_list?(value["options"]) and
        Enum.all?(value["options"], &(is_map(&1) and text?(&1["id"]) and text?(&1["name"])))

  defp valid_scalar?("ProjectV2ItemFieldRepositoryValue", %{"repository" => nil}), do: true

  defp valid_scalar?("ProjectV2ItemFieldRepositoryValue", %{"repository" => value})
       when is_map(value),
       do: node_id?(value["id"]) and text?(value["nameWithOwner"]) and github_url?(value["url"])

  defp valid_scalar?("ProjectV2ItemFieldMilestoneValue", %{"milestone" => nil}), do: true

  defp valid_scalar?("ProjectV2ItemFieldMilestoneValue", %{"milestone" => value})
       when is_map(value),
       do: node_id?(value["id"]) and text?(value["title"]) and github_url?(value["url"])

  defp valid_scalar?("ProjectV2ItemIssueFieldValue", %{"issueFieldValue" => nil}), do: true

  defp valid_scalar?("ProjectV2ItemIssueFieldValue", %{"issueFieldValue" => value})
       when is_map(value) do
    node_id?(value["id"]) and
      case value["__typename"] do
        "IssueFieldTextValue" ->
          optional_text?(value["textValue"])

        "IssueFieldDateValue" ->
          date?(value["dateValue"])

        "IssueFieldNumberValue" ->
          is_number(value["numberValue"])

        "IssueFieldSingleSelectValue" ->
          text?(value["name"]) and text?(value["singleSelectValue"])

        "IssueFieldMultiSelectValue" ->
          bounded_list?(value["options"]) and
            Enum.all?(value["options"], &(is_map(&1) and text?(&1["id"]) and text?(&1["name"])))

        _ ->
          false
      end
  end

  defp valid_scalar?(_, _), do: false

  defp collection_node?("labels", node), do: node_id?(node["id"]) and text?(node["name"])

  defp collection_node?("users", node),
    do: node_id?(node["id"]) and text?(node["login"]) and github_url?(node["url"])

  defp collection_node?("pullRequests", node),
    do:
      node_id?(node["id"]) and text?(node["title"]) and C.sequence?(node["number"]) and
        github_content_url?(node["url"])

  defp collection_node?("reviewers", node),
    do:
      node_id?(node["id"]) and node["__typename"] in ~w(User Team Bot Mannequin EnterpriseTeam) and
        (github_url?(node["url"]) or
           (node["__typename"] == "EnterpriseTeam" and text?(node["name"])))

  defp view_field?("sortByFields", node),
    do: field?(node["field"]) and node["direction"] in ~w(ASC DESC)

  defp view_field?(_, node), do: field?(node)

  defp request(_, _, _, _, 0), do: C.error("nested_pagination_limit")

  defp request(query, variables, headers, context, budget) do
    with {:ok, body, response} <- C.graphql(query, variables, headers, context),
         :ok <- token_scope(response),
         {:ok, data} <- graphql_data(body) do
      {:ok, data, budget - 1}
    end
  end

  defp token_scope(response) do
    case Req.Response.get_header(response, "x-oauth-scopes") do
      [] ->
        :ok

      scopes ->
        reported =
          scopes
          |> Enum.join(",")
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        # Fine-grained/App tokens may not disclose classic OAuth scopes. The
        # selected project query still has to pass GitHub's authorization check.
        if reported == [] or Enum.any?(reported, &(&1 in ["project", "read:project"])),
          do: :ok,
          else: C.error("credential_scope_missing")
    end
  end

  defp graphql_data(%{"errors" => errors}) when is_list(errors) and errors != [] do
    types =
      Enum.map(errors, fn error ->
        if is_map(error) do
          extension = error["extensions"]
          error["type"] || if(is_map(extension), do: extension["code"])
        end
      end)

    cond do
      "RATE_LIMITED" in types ->
        C.error("rate_limited", true)

      "INSUFFICIENT_SCOPES" in types ->
        C.error("credential_scope_missing")

      Enum.any?(types, &(&1 in ~w(FORBIDDEN NOT_FOUND UNAUTHORIZED))) ->
        C.error("source_access_denied")

      true ->
        C.error("provider_graphql_error")
    end
  end

  defp graphql_data(%{"data" => data} = body) when is_map(data) do
    if Map.has_key?(body, "errors") and body["errors"] != [],
      do: C.error("invalid_provider_response"),
      else: {:ok, data}
  end

  defp graphql_data(_), do: C.error("invalid_provider_response")

  defp query(selected, stage) do
    owner = selected["owner_kind"]

    fields =
      case stage do
        "project" ->
          "title shortDescription readme closed"

        "fields" ->
          "fields(first: #{@size}, after: $after) { nodes { #{field_definition()} } #{@page_info} }"

        "views" ->
          "views(first: #{@size}, after: $after) { nodes { id name number layout filter #{@project_ref} #{view_fields()} } #{@page_info} }"

        "items" ->
          "items(first: #{@size}, after: $after, archivedStates: [ARCHIVED, NOT_ARCHIVED]) { nodes { id type isArchived updatedAt #{@project_ref} #{content_fields()} fieldValues(first: #{@nested_size}) { nodes { #{value_fields()} } #{@page_info} } } #{@page_info} }"
      end

    after_definition = if stage == "project", do: "", else: ", $after: String"

    "query HarnessForgeProject($owner: String!, $number: Int!#{after_definition}) { scope: #{owner}(login: $owner) { projectV2(number: $number) { id url number updatedAt owner { __typename ... on Organization { login } ... on User { login } } #{fields} } } }"
  end

  defp variables(selected, state) do
    values = %{"owner" => selected["owner"], "number" => selected["number"]}
    if state["stage"] == "project", do: values, else: Map.put(values, "after", state["after"])
  end

  defp field_definition do
    "__typename #{@field_ref} ... on ProjectV2FieldCommon { updatedAt #{@project_ref} } " <>
      "... on ProjectV2SingleSelectField { options { id name color description } } " <>
      "... on ProjectV2MultiSelectField { options: multiSelectOptions { id name color description } } " <>
      "... on ProjectV2IterationField { configuration { duration startDay iterations { id title startDate duration } completedIterations { id title startDate duration } } }"
  end

  defp view_fields,
    do:
      Enum.map_join(
        @view_connections,
        " ",
        &"#{&1}(first: #{@nested_size}) { nodes { #{view_node_fields(&1)} } #{@page_info} }"
      )

  defp view_node_fields("sortByFields"), do: "direction field { #{@field_ref} }"
  defp view_node_fields(_), do: @field_ref

  defp view_query(key),
    do:
      "query HarnessForgeProjectViewFields($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2View { id #{@project_ref} #{key}(first: #{@nested_size}, after: $after) { nodes { #{view_node_fields(key)} } #{@page_info} } } } }"

  defp content_fields,
    do:
      "content { __typename ... on DraftIssue { id title body updatedAt } ... on Issue { id number title body url issueState: state updatedAt repository { nameWithOwner } } ... on PullRequest { id number title body url pullRequestState: state updatedAt repository { nameWithOwner } } }"

  defp value_fields do
    scalar =
      Enum.map_join(@scalar_values, " ", fn {type, fields} ->
        "... on #{type} { field { #{@field_ref} } #{fields} }"
      end)

    collections =
      Enum.map_join(@collection_values, " ", fn {type, {key, fields}} ->
        "... on #{type} { field { #{@field_ref} } #{key}(first: #{@nested_size}) { nodes { #{fields} } #{@page_info} } }"
      end)

    "__typename " <> scalar <> " " <> collections
  end

  defp item_values_query,
    do:
      "query HarnessForgeProjectItemFields($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2Item { id #{@project_ref} fieldValues(first: #{@nested_size}, after: $after) { nodes { #{value_fields()} } #{@page_info} } } } }"

  defp collection_query(type) do
    {key, fields} = @collection_values[type]

    "query HarnessForgeProjectItemCollection($id: ID!, $field: String!, $after: String) { node(id: $id) { ... on ProjectV2Item { id #{@project_ref} fieldValueByName(name: $field) { __typename ... on #{type} { field { #{@field_ref} } #{key}(first: #{@nested_size}, after: $after) { nodes { #{fields} } #{@page_info} } } } } } }"
  end

  defp document(id, key, title, body, selected, project, kind, metadata \\ %{}, updated \\ nil) do
    metadata =
      Map.merge(metadata, %{
        "project_url" => selected["url"],
        "project_id" => project["id"],
        "owner_kind" => selected["owner_kind"],
        "owner" => selected["owner"],
        "number" => selected["number"],
        "kind" => kind,
        "normalizer_version" => "github-projects-v1"
      })

    %{
      "external_id" => "github_projects:#{id}:#{key}",
      "title" => title,
      "body" => "# " <> title <> "\n\n" <> Jason.encode!(body, pretty: true),
      "source_url" => selected["url"],
      "source_updated_at" => updated || project["updatedAt"],
      "metadata" => metadata
    }
  end

  defp page(items, cursor, complete),
    do:
      {:ok, %{"items" => items, "next_cursor" => C.encode_cursor(cursor), "complete" => complete}}

  defp reduce(values, budget, fun) do
    Enum.reduce_while(values, {:ok, [], budget}, fn value, {:ok, acc, left} ->
      case fun.(value, left) do
        {:ok, normalized, left} -> {:cont, {:ok, [normalized | acc], left}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values, left} -> {:ok, Enum.reverse(values), left}
      error -> error
    end
  end

  defp view_result({:ok, _, {view, budget}}), do: {:ok, view, budget}
  defp view_result(error), do: error

  defp unique_nodes?(nodes) do
    identities =
      Enum.map(nodes, fn node ->
        field = node["field"]
        field_id = if is_map(field), do: field["id"]
        node["id"] || field_id || Jason.encode!(node)
      end)

    Enum.uniq(identities) == identities
  end

  defp node_id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and
        Regex.match?(~r/\A[A-Za-z0-9_=-]+\z/, value)

  defp cursor_value?(nil), do: true

  defp cursor_value?(value),
    do:
      is_binary(value) and byte_size(value) in 1..1024 and String.valid?(value) and
        not String.contains?(value, ["\r", "\n", <<0>>])

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp text?(value), do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)
  defp optional_text?(nil), do: true
  defp optional_text?(value), do: is_binary(value) and String.valid?(value)
  defp bounded_list?(value), do: is_list(value) and length(value) <= 1000
  defp date?(value), do: is_binary(value) and match?({:ok, _}, Date.from_iso8601(value))

  defp github_content_url?(value),
    do:
      is_binary(value) and
        Regex.match?(
          ~r{\Ahttps://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(issues|pull)/[1-9][0-9]*\z},
          value
        )

  defp github_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: "github.com",
        port: 443,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      } ->
        is_binary(path) and String.starts_with?(path, "/")

      _ ->
        false
    end
  end

  defp github_url?(_), do: false

  defp same_project_url?(left, right) when is_binary(left) and is_binary(right),
    do: String.downcase(left) == String.downcase(right)

  defp same_project_url?(_, _), do: false

  defp headers(credential),
    do: [{"authorization", "Bearer " <> credential}, {"accept", "application/vnd.github+json"}]
end
