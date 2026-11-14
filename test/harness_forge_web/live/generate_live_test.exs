defmodule HarnessForgeWeb.GenerateLiveTest do
  use HarnessForgeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias HarnessForge.SyntheticRepositories, as: Repositories
  alias HarnessForgeWeb.Plugs.OperatorSession

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "hf-generate-live-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    conn =
      conn
      |> Map.merge(%{host: "localhost", port: 4002})
      |> init_test_session(%{"operator_auth" => OperatorSession.new_auth()})

    {:ok, conn: conn, root: root}
  end

  defp generate(view, path) do
    view |> form("#generate-form", generate: %{path: path}) |> render_submit()
    render_async(view, 30_000)
  end

  defp digest(html) do
    [_, value] = Regex.run(~r/id="generate-digest"[^>]*>([0-9a-f]{64})</, html)
    value
  end

  test "the idle page is one field and one button", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/generate")
    assert has_element?(view, "#generate-path")
    assert has_element?(view, "#generate-submit")
    assert has_element?(view, "#generate-node-export[data-status=idle]")
    refute has_element?(view, "#generate-package")
  end

  test "a repository produces commands, tiles, meters and a stable digest", %{
    conn: conn,
    root: root
  } do
    repository = Repositories.python_project(Path.join(root, "widgets"))
    {:ok, view, _html} = live(conn, "/generate")

    html = generate(view, repository)

    assert has_element?(view, "#generate-page[data-state=ready]")
    assert has_element?(view, "#generate-command-test code", "uv run pytest")
    assert has_element?(view, "#generate-node-generate[data-status=done]")
    assert has_element?(view, "#generate-meter-commands[data-total='8']")
    assert has_element?(view, "#generate-files [data-path='CLAUDE.md']")
    assert has_element?(view, "#generate-export-target")
    assert render(element(view, "#generate-tile-cochange-value")) =~ ~r/>\d+</

    repeated = generate(view, repository)
    assert digest(repeated) == digest(html)
    assert has_element?(view, "#generate-page[data-run='2']")
  end

  test "the result shows the CLAUDE.md price, the withheld count and the context profile", %{
    conn: conn,
    root: root
  } do
    repository = Repositories.python_project(Path.join(root, "widgets"))
    {:ok, view, _html} = live(conn, "/generate")
    assert has_element?(view, "#generate-context option[value=lean][selected]")
    assert has_element?(view, "#generate-context option[value=standard]")

    generate(view, repository)
    assert has_element?(view, "#generate-price[data-bytes][data-tokens][data-withheld]")
    price = render(element(view, "#generate-price"))
    assert price =~ ~r/\d+ bytes the model reads, about \d+ tokens on every request/
    assert price =~ ~r/\d+ lines? withheld/

    profile = render(element(view, "#generate-context-profile"))
    assert profile =~ "Context profile: lean"
    assert profile =~ "tools no recorded benchmark run used"
    # The history-derived test runner (the fixture pairs tests with sources) keeps Task.
    assert profile =~
             "14 tools no recorded benchmark run used, including skills (Skill, Workflow)"

    refute profile =~ "subagents (Task)"
    refute profile =~ "unused tools"
    assert profile =~ "about 9,865 fewer tokens on every model request"
    assert profile =~ "Claude Code 2.1.311"
    assert has_element?(view, "#generate-context-profile[data-profile=lean][data-saved='9865']")

    view
    |> form("#generate-form", generate: %{path: repository, context: "standard"})
    |> render_submit()

    render_async(view, 30_000)
    assert has_element?(view, "#generate-context-profile[data-profile=standard][data-saved='0']")
    assert has_element?(view, "#generate-context option[value=standard][selected]")
  end

  test "the result lists the generated subagents with their bytes and cost; none empties the list",
       %{conn: conn, root: root} do
    repository = Repositories.python_project(Path.join(root, "widgets"))
    {:ok, view, _html} = live(conn, "/generate")
    assert has_element?(view, "#generate-native option[value=all][selected]")

    for value <- ~w(skills agents none),
        do: assert(has_element?(view, "#generate-native option[value=#{value}]"))

    generate(view, repository)

    assert has_element?(
             view,
             "#generate-native-olivium-test-runner[data-kind=agent][data-template=test_runner]" <>
               "[data-origin=history][data-tools='Bash,Read'][data-body-bytes][data-description-bytes]"
           )

    assert has_element?(view, "#generate-native-list > li", "olivium-test-runner")
    cost = render(element(view, "#generate-native-cost"))
    assert cost =~ ~r/About [\d,]+ tokens on every model request for these/
    assert cost =~ "measured on Claude Code 2.1.311"

    subagent_cost = render(element(view, "#generate-native-subagent-cost"))

    assert subagent_cost =~
             ~r/Each subagent call costs about [\d,]+-[\d,]+ tokens per turn of its own/

    assert subagent_cost =~
             "built-in subagents (Explore, general-purpose, statusline-setup) are denied by name, which takes about 395 tokens off every request"

    assert has_element?(
             view,
             "#generate-native-subagent-cost[data-builtin-denied='Explore,general-purpose,statusline-setup'][data-builtin-denied-tokens='395']"
           )

    refute has_element?(view, "#generate-native-none")
    profile = render(element(view, "#generate-context-profile"))
    assert profile =~ "keeps Task for the generated subagents"

    assert has_element?(
             view,
             "#generate-files [data-path='.claude/agents/olivium-test-runner.md']"
           )

    view
    |> form("#generate-form", generate: %{path: repository, native: "none"})
    |> render_submit()

    render_async(view, 30_000)
    refute has_element?(view, "#generate-native-list > li")
    refute has_element?(view, "#generate-native-cost")
    assert has_element?(view, "#generate-native-none[data-reasons~=not_selected]")
    assert has_element?(view, "#generate-context-profile[data-profile=lean][data-saved='11700']")
    assert has_element?(view, "#generate-native option[value=none][selected]")
  end

  test "export writes a fresh directory and refuses an existing one", %{conn: conn, root: root} do
    repository = Repositories.python_project(Path.join(root, "widgets"))
    target = Path.join(root, "export")
    {:ok, view, _html} = live(conn, "/generate")
    generate(view, repository)

    view |> form("#generate-export-form", export: %{target: target}) |> render_submit()
    render_async(view, 30_000)

    assert has_element?(view, "#generate-export-result[data-path='#{target}']")
    assert has_element?(view, "#generate-node-export[data-status=done]")
    assert File.regular?(Path.join(target, "CLAUDE.md"))

    view |> form("#generate-export-form", export: %{target: target}) |> render_submit()
    render_async(view, 30_000)

    assert has_element?(view, "#generate-error[data-code=export_conflict]")
    assert has_element?(view, "#generate-node-export[data-status=failed]")
    assert has_element?(view, "#generate-export-form")
  end

  test "failures are visible and name the stage", %{conn: conn, root: root} do
    plain = Repositories.plain_directory(Path.join(root, "plain"))
    {:ok, view, _html} = live(conn, "/generate")

    generate(view, plain)
    assert has_element?(view, "#generate-error[data-code=not_a_git_repository]")
    assert has_element?(view, "#generate-node-detect[data-status=failed]")
    assert has_element?(view, "#generate-node-analyze[data-status=idle]")
    refute has_element?(view, "#generate-package")

    generate(view, Path.join(root, "missing"))
    assert has_element?(view, "#generate-error[data-code=invalid_repository_path]")

    view |> form("#generate-form", generate: %{path: "relative/path"}) |> render_submit()
    assert has_element?(view, "#generate-error[data-code=invalid_repository_path]")
    assert has_element?(view, "#generate-page[data-state=failed]")
  end
end
