defmodule HarnessForge.Compiler do
  @moduledoc """
  Pure deterministic v1alpha1 compilation. This function validates structure,
  references and runtime intent; it is **not approval authority**. The domain
  command must assemble the spec from an eligible approved immutable snapshot.

  `mode: :preview` (default) renders an explicitly unqualified native package.
  `mode: :managed` fails until a real qualified runtime/backend is integrated.
  Caller-supplied `qualified: true` or profile maps cannot grant enforcement.
  """
  alias HarnessForge.Contracts
  alias HarnessForge.Adapters.Registry
  alias HarnessForge.Contracts.Error

  @identity %{
    "name" => "harnessforge",
    "compiler_version" => "0.1.0",
    "template_version" => "v1alpha1.1"
  }
  @artifact_keys ~w(files digest manifest capabilities diagnostics spec)

  @spec compile(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def compile(spec, opts \\ []) do
    with {:ok, spec} <- Contracts.validate_harness(spec),
         :ok <- repository_scope(spec),
         {:ok, mode} <- compile_mode(opts),
         {:ok, adapter} <- Registry.fetch(spec["spec"]["runtime"]["name"]),
         {:ok, output} <- adapter.compile(spec, %{"mode" => mode}) do
      {:ok, assemble(spec, output, adapter.identity())}
    end
  end

  @doc "Rebuild and compare every byte, rejecting modified or fabricated artifact metadata."
  @spec verify(term()) :: :ok | {:error, Error.t()}
  def verify(artifact) when is_map(artifact) do
    with true <- Enum.sort(Map.keys(artifact)) == Enum.sort(@artifact_keys),
         {:ok, expected} <- compile(artifact["spec"]),
         true <- expected == artifact do
      :ok
    else
      _ -> invalid_artifact()
    end
  end

  def verify(_), do: invalid_artifact()

  defp compile_mode(opts) do
    case Keyword.get(opts, :mode, :preview) do
      :preview ->
        {:ok, "preview"}

      :managed ->
        {:ok, "managed"}

      _ ->
        {:error,
         %Error{code: "invalid_compile_mode", message: "Compile mode must be preview or managed"}}
    end
  end

  # Scope is an opaque repository identity, never a local path or credential URL.
  defp repository_scope(spec) do
    if Enum.all?(
         spec["spec"]["scope"]["repositories"],
         &Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*(\/[A-Za-z0-9][A-Za-z0-9._-]*)*$/, &1)
       ) do
      :ok
    else
      {:error,
       %Error{
         code: "invalid_repository_scope",
         message:
           "Repository scope must use opaque identities without local paths or credential URLs"
       }}
    end
  end

  defp assemble(spec, output, adapter_identity) do
    provenance = %{
      "rules" =>
        Enum.sort_by(spec["spec"]["rules"], & &1["id"])
        |> Enum.map(&Map.take(&1, ["id", "revision_hash", "evidence", "goal_id"])),
      "goals" =>
        Enum.sort_by(spec["spec"]["goals"], & &1["id"]) |> Enum.map(&Map.take(&1, ["id"]))
    }

    report = %{
      "runtime" => spec["spec"]["runtime"],
      "qualification" => "unverified",
      "capabilities" => output["capabilities"],
      "diagnostics" => output["diagnostics"]
    }

    files =
      Map.merge(output["files"], %{
        "harnessforge.spec.json" => Contracts.canonical_json(spec) <> "\n",
        "harnessforge.provenance.json" => Contracts.canonical_json(provenance) <> "\n",
        "harnessforge.capabilities.json" => Contracts.canonical_json(report) <> "\n"
      })

    entries =
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {path, bytes} ->
        %{
          "path" => path,
          "mode" => "0600",
          "size" => byte_size(bytes),
          "sha256" => Contracts.sha256(bytes)
        }
      end)

    identity = %{
      "compiler" => @identity,
      "adapter" => adapter_identity,
      "spec_digest" => Contracts.digest(spec),
      "files" => entries
    }

    digest = Contracts.digest(identity)

    manifest =
      Map.merge(identity, %{
        "digest" => digest,
        "kind" => "native_preview",
        "qualification" => "unverified",
        "manifest_hash_policy" => "manifest excluded to avoid self-reference"
      })

    files =
      Map.put(files, "harnessforge.manifest.json", Contracts.canonical_json(manifest) <> "\n")

    %{
      "files" => files,
      "digest" => digest,
      "manifest" => manifest,
      "capabilities" => output["capabilities"],
      "diagnostics" => output["diagnostics"],
      "spec" => spec
    }
  end

  defp invalid_artifact,
    do:
      {:error,
       %Error{
         code: "invalid_artifact",
         message: "Artifact bytes or metadata do not match the deterministic compiler output"
       }}
end
