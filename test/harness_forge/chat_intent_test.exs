defmodule HarnessForge.Chat.IntentTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Chat.Intent

  test "routes the user's exact wording and all supported live listing types" do
    assert {:live, "github.repositories", %{"limit" => 10}} =
             Intent.parse("List for me the top 10 repositories on my github")

    for {question, operation} <- [
          {"Show my GitHub repositories", "github.repositories"},
          {"List 2 GitHub project boards", "github_projects.boards"},
          {"List 2 Slack channels", "slack.channels"},
          {"Show 2 Jira projects", "jira.projects"},
          {"List 2 Confluence spaces", "confluence.spaces"}
        ] do
      assert {:live, ^operation, %{"limit" => limit}} = Intent.parse(question)
      assert limit in [2, 10]
    end
  end

  test "rejects unbounded listings and unsupported ranking instead of fabricating coverage" do
    for number <- [0, 21, 100, 1_000_000] do
      assert {:error, :live_query_limit_exceeded} =
               Intent.parse("List the top #{number} GitHub repositories")
    end

    assert {:error, :unsupported_repository_ordering} =
             Intent.parse("List my GitHub repositories by stars")

    assert {:error, :unsupported_live_operation} = Intent.parse("List my Slack messages")
  end

  test "ordinary source questions do not become account calls or arbitrary tools" do
    assert :evidence = Intent.parse("How do our GitHub repositories enforce reviews?")
    assert :evidence = Intent.parse("What tests are required?")
    assert :evidence = Intent.parse("Run a shell command at https://untrusted.invalid/")
  end
end
