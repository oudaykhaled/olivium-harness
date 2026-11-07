defmodule HarnessForge.Chat.Intent do
  @moduledoc "Finite read-only account intents; questions never become URLs, shell commands or model tools."

  def parse(question) when is_binary(question) do
    question = String.downcase(question)

    operation =
      cond do
        not inventory?(question) ->
          nil

        github?(question) and Regex.match?(~r/\b(repositories|repository|repos)\b/, question) ->
          "github.repositories"

        github?(question) and Regex.match?(~r/\b(projects?|boards?)\b/, question) ->
          "github_projects.boards"

        String.contains?(question, "slack") and String.contains?(question, "channel") ->
          "slack.channels"

        String.contains?(question, "jira") and String.contains?(question, "project") ->
          "jira.projects"

        String.contains?(question, "confluence") and String.contains?(question, "space") ->
          "confluence.spaces"

        true ->
          nil
      end

    cond do
      is_nil(operation) ->
        if inventory?(question) and Regex.match?(~r/\b(github|slack|jira|confluence)\b/, question),
          do: {:error, :unsupported_live_operation},
          else: :evidence

      operation == "github.repositories" and
          Regex.match?(~r/\b(stars?|starred|popular|forks?|created|oldest)\b/, question) ->
        {:error, :unsupported_repository_ordering}

      true ->
        limit =
          case Regex.run(~r/\b(?:top|first|last|list|show|me)\s+(\d+)\b/, question) do
            [_, number] when byte_size(number) <= 3 -> String.to_integer(number)
            [_, _] -> 21
            nil -> 10
          end

        if limit in 1..20,
          do: {:live, operation, %{"limit" => limit}},
          else: {:error, :live_query_limit_exceeded}
    end
  end

  defp github?(question), do: Regex.match?(~r/\bgit\s*hub\b/, question)

  defp inventory?(question),
    do: Regex.match?(~r/\b(list|show|display|enumerate|top|first|last|which|what)\b/, question)
end
