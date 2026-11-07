# Run with the pinned Elixir/OTP, from the trusted source checkout.
# mix.lock is project code, never an imported user document.
defmodule HarnessForge.Packaging.Inventory do
  def run(target) do
    File.mkdir_p!(target)

    {lock, _bindings} =
      "mix.lock"
      |> File.read!()
      |> Code.string_to_quoted!(emit_warnings: false)
      |> Code.eval_quoted()

    dependencies =
      lock
      |> Enum.sort_by(fn {name, _} -> to_string(name) end)
      |> Enum.map(fn {name, locked} -> dependency(to_string(name), locked, target) end)

    inventory = %{
      "format" => "harnessforge-source-inventory-v1",
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "architecture" => to_string(:erlang.system_info(:system_architecture)),
      "mix_lock_sha256" => hash(File.read!("mix.lock")),
      "dependencies" => dependencies,
      "limits" => "Source dependency inventory; not a complete native/transitive binary SBOM."
    }

    File.write!(Path.join(target, "inventory.json"), :json.encode(inventory))
    File.cp!("mix.lock", Path.join(target, "mix.lock"))
    File.cp!(".tool-versions", Path.join(target, ".tool-versions"))

    for component <- ~w(Elixir Erlang-OTP topbar heroicons daisyui) do
      source = "packaging/licenses/#{component}-LICENSE"
      File.cp!(source, Path.join(target, "#{component}-LICENSE"))
    end

    rows =
      Enum.map(
        dependencies,
        &"| #{&1["name"]} | #{&1["version"]} | #{Enum.join(&1["licenses"], ", ")} |"
      )

    File.write!(
      Path.join(target, "inventory.md"),
      "# Locked source dependencies\n\n| Name | Version/ref | Declared licenses |\n| --- | --- | --- |\n" <>
        Enum.join(rows, "\n") <> "\n"
    )
  end

  defp dependency(
         name,
         {:hex, _package, version, checksum, _build, _requirements, _repo, outer},
         target
       ) do
    metadata_path = Path.join(["deps", name, "hex_metadata.config"])
    {:ok, terms} = :file.consult(String.to_charlist(metadata_path))
    metadata = Map.new(terms)
    licenses = Map.fetch!(metadata, "licenses")
    if licenses == [], do: raise("Missing declared license for #{name}")
    copy_notices(name, licenses, target)

    %{
      "name" => name,
      "kind" => "hex",
      "version" => version,
      "checksum" => checksum,
      "outer_checksum" => outer,
      "licenses" => licenses,
      "links" => Map.new(Map.get(metadata, "links", []))
    }
  end

  defp dependency(name, {:git, url, revision, _opts}, _target)
       when name in ~w(heroicons daisyui) do
    %{
      "name" => name,
      "kind" => "git",
      "version" => revision,
      "revision" => revision,
      "url" => url,
      "licenses" => ["MIT"]
    }
  end

  defp dependency(name, _locked, _target), do: raise("Unreviewed dependency kind: #{name}")

  defp copy_notices(name, licenses, target) do
    directory = Path.join(target, name)
    File.mkdir_p!(directory)

    files =
      Path.wildcard("deps/#{name}/*")
      |> Enum.filter(
        &(File.regular?(&1) and
            Regex.match?(~r/^(license|copying|notice|readme)/i, Path.basename(&1)))
      )

    Enum.each(files, &File.cp!(&1, Path.join(directory, Path.basename(&1))))

    cond do
      Enum.any?(files, &Regex.match?(~r/^(license|copying)/i, Path.basename(&1))) ->
        :ok

      licenses == ["Apache-2.0"] ->
        File.cp!("LICENSE", Path.join(directory, "LICENSE-Apache-2.0"))

      name == "phoenix_live_reload" ->
        File.cp!(
          "packaging/licenses/phoenix_live_reload-LICENSE",
          Path.join(directory, "LICENSE-MIT")
        )

      true ->
        raise("Missing license material for #{name}")
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

case System.argv() do
  [target] -> HarnessForge.Packaging.Inventory.run(Path.expand(target))
  _ -> raise("Usage: elixir packaging/inventory.exs OUTPUT_DIRECTORY")
end
