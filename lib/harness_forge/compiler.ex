defmodule HarnessForge.Compiler do
  @moduledoc """
  Pure deterministic compilation. This function validates structure, references
  and runtime intent; it is **not approval authority**. The domain command must
  assemble the spec from an eligible approved immutable snapshot.

  `harnessforge.dev/v1alpha1` output is frozen: stored artifacts verify by
  recompiling, so its rendering, identity and file layout must never change.
  `harnessforge.dev/v1alpha2` branches here on `apiVersion`, is preview-only, and
  writes its metadata under `.olivium/`. A target whose adapter has no
  `compile_v2/2` returns a visible `unsupported_target` error.

  `mode: :preview` (default) renders an explicitly unqualified native package.
  `mode: :managed` fails until a real qualified runtime/backend is integrated.
  Caller-supplied `qualified: true` or profile maps cannot grant enforcement.
  """
  alias HarnessForge.Contracts
  alias HarnessForge.Adapters.Registry
  alias HarnessForge.Contracts.{Error, HarnessV2}

  @identity %{
    "name" => "harnessforge",
    "compiler_version" => "0.1.0",
    "template_version" => "v1alpha1.1"
  }
  # Bumped once per integration point of the harness enhancement plan. A stored
  # v1alpha2 preview from an older template no longer verifies (every byte is rebuilt
  # and compared) and is refused with `preview_regenerate`.
  @v2_identity %{
    "name" => "harnessforge",
    "compiler_version" => "0.2.0",
    "template_version" => "v1alpha2.4"
  }
  @v2_api_version HarnessV2.api_version()
  @v2_metadata_files ~w(.olivium/spec.json .olivium/provenance.json .olivium/capabilities.json .olivium/manifest.json)
  @artifact_keys ~w(files digest manifest capabilities diagnostics spec)

  @spec compile(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def compile(spec, opts \\ [])

  def compile(%{"apiVersion" => @v2_api_version} = spec, opts) do
    with {:ok, spec} <- Contracts.validate_harness(spec),
         :ok <- repository_scope(spec),
         {:ok, mode} <- compile_mode(opts),
         :ok <- v2_preview_only(mode),
         {:ok, adapter} <- Registry.fetch(spec["spec"]["runtime"]["name"]),
         :ok <- v2_supported(adapter, spec["spec"]["runtime"]["name"]),
         {:ok, output} <- adapter.compile_v2(spec, %{"mode" => mode}),
         :ok <- v2_paths_available(output) do
      {:ok, assemble_v2(spec, output, v2_adapter_identity(adapter))}
    end
  end

  def compile(spec, opts) do
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
      _ -> if older_v2_preview?(artifact), do: preview_regenerate(), else: invalid_artifact()
    end
  end

  def verify(_), do: invalid_artifact()

  # Only the wording of the refusal depends on this; the artifact is refused either way.
  defp older_v2_preview?(%{"spec" => %{"apiVersion" => @v2_api_version}, "manifest" => manifest})
       when is_map(manifest) do
    case manifest["compiler"] do
      %{"name" => "harnessforge", "template_version" => version} when is_binary(version) ->
        version != @v2_identity["template_version"]

      _ ->
        false
    end
  end

  defp older_v2_preview?(_), do: false

  defp preview_regenerate,
    do:
      {:error,
       %Error{
         code: "preview_regenerate",
         message:
           "This v1alpha2 preview was made by an earlier version of the generator and no longer verifies. Generate it again from the repository."
       }}

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

  defp v2_preview_only("preview"), do: :ok

  defp v2_preview_only(_),
    do:
      {:error,
       %Error{
         code: "runtime_unqualified",
         message: "v1alpha2 packages are native previews only; no managed backend is qualified"
       }}

  defp v2_supported(adapter, target) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :compile_v2, 2) do
      :ok
    else
      {:error,
       %Error{
         code: "unsupported_target",
         message: "Generated v1alpha2 packages are not supported for this target yet",
         details: [target]
       }}
    end
  end

  defp v2_adapter_identity(adapter) do
    if function_exported?(adapter, :identity_v2, 0),
      do: adapter.identity_v2(),
      else: adapter.identity()
  end

  # Metadata paths belong to the compiler; an adapter must not be able to replace them.
  defp v2_paths_available(%{"files" => files}) when is_map(files) do
    case Enum.filter(@v2_metadata_files, &Map.has_key?(files, &1)) do
      [] ->
        :ok

      reserved ->
        {:error,
         %Error{
           code: "invalid_runtime_output",
           message: "Adapter output uses a reserved compiler metadata path",
           details: reserved
         }}
    end
  end

  defp v2_paths_available(_),
    do:
      {:error, %Error{code: "invalid_runtime_output", message: "Adapter output has no file map"}}

  @doc false
  # Public only so the v1alpha2 layout can be tested before a target adapter exists.
  # It performs no validation; `compile/2` is the entry point.
  @spec assemble_v2(map(), map(), map()) :: map()
  def assemble_v2(spec, output, adapter_identity) do
    provenance =
      %{
        "generation" => spec["spec"]["generation"],
        "rules" =>
          spec["spec"]["rules"]
          |> Enum.sort_by(& &1["id"])
          |> Enum.map(
            &Map.take(&1, ~w(id origin revision_hash evidence goal_id fingerprint source))
          ),
        "goals" =>
          Enum.sort_by(spec["spec"]["goals"], & &1["id"]) |> Enum.map(&Map.take(&1, ["id"]))
      }
      |> put_learning(spec["spec"])

    report = %{
      "runtime" => spec["spec"]["runtime"],
      "qualification" => "unverified",
      "capabilities" => output["capabilities"],
      "diagnostics" => output["diagnostics"]
    }

    files =
      Map.merge(output["files"], %{
        ".olivium/spec.json" => Contracts.canonical_json(spec) <> "\n",
        ".olivium/provenance.json" => Contracts.canonical_json(provenance) <> "\n",
        ".olivium/capabilities.json" => Contracts.canonical_json(report) <> "\n"
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
      "compiler" => @v2_identity,
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

    %{
      "files" =>
        Map.put(files, ".olivium/manifest.json", Contracts.canonical_json(manifest) <> "\n"),
      "digest" => digest,
      "manifest" => manifest,
      "capabilities" => output["capabilities"],
      "diagnostics" => output["diagnostics"],
      "spec" => spec
    }
  end

  # A lean-ai package records its bundle and the locator gate numbers whether or not
  # the locator hook was rendered. Other profiles keep their provenance bytes.
  defp put_learning(provenance, %{"learning" => learning, "locator" => locator})
       when is_map(learning) and is_map(locator) do
    Map.merge(provenance, %{
      "learning" => learning,
      "locator" =>
        Map.take(
          locator,
          ~w(rendered status replay_n top3_hits wrong max_card_bytes version learned_terms)
        )
    })
  end

  defp put_learning(provenance, _spec), do: provenance

  defp invalid_artifact,
    do:
      {:error,
       %Error{
         code: "invalid_artifact",
         message: "Artifact bytes or metadata do not match the deterministic compiler output"
       }}
end
