defmodule HarnessForge.CompanyCLITest do
  use HarnessForge.DataCase, async: false
  alias HarnessForge.{CLI, Company}

  setup do
    path = Path.join(File.cwd!(), "tmp/company-cli-#{Ecto.UUID.generate()}.json")
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "company commands use the same scoped context and bounded strict JSON", %{path: path} do
    assert {:ok, nil} = CLI.run(["company", "profile"])
    File.write!(path, Jason.encode!(%{"name" => "CLI Example"}))
    assert {:ok, saved} = CLI.run(["company", "profile", path])
    assert {:ok, ^saved} = Company.get_profile()
    File.write!(path, ~s({"name":"A","name":"B"}))
    assert {:error, :invalid_company_config} = CLI.run(["company", "profile", path])
    File.write!(path, String.duplicate("a", 262_145))
    assert {:error, :invalid_company_config} = CLI.run(["company", "profile", path])
  end

  test "CLI does not accept supplied workspace or approval authority", %{path: path} do
    File.write!(path, Jason.encode!(%{"name" => "Forged", "workspace_id" => "foreign"}))
    assert {:error, _} = CLI.run(["company", "profile", path])
    assert {:ok, nil} = Company.get_profile()
    assert {:ok, help} = CLI.run(["help"])
    assert "company build PLAN_ID REVISION_HASH" in help["commands"]
  end
end
