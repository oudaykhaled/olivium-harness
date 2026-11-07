defmodule HarnessForgeWeb.PackageBuild do
  @moduledoc "Bounded build-form drafts and fixed-copy refusals; never compiler admission."
  alias HarnessForge.Contracts.Error

  @fields ~w(name version runtime runtime_version)
  @name_details [
    "$.metadata.name: invalid format",
    "$.metadata.name: outside permitted bounds",
    "$.metadata.name: invalid string",
    "$.metadata.name: required"
  ]
  @runtime_codes ~w(unsupported_runtime invalid_runtime_intent unsupported_required_control runtime_unqualified)
  @known_reasons ~w(no_approved_claims goal_claim_requires_plan privacy_operation_incomplete cleanup_failed jobs_still_executing evaluations_still_running runtime_unqualified source_unavailable stale_or_revoked_evidence service_unavailable)a

  @type draft :: %{String.t() => String.t()}
  @type outcome :: :name | :generic | {:runtime, String.t()} | {:known, atom()}

  @spec defaults() :: draft()
  def defaults,
    do: %{
      "name" => "my-harness",
      "version" => "0.1.0",
      "runtime" => "opencode",
      "runtime_version" => "unqualified"
    }

  @doc "Checks generation before admitting an exact, unchanged four-field draft."
  @spec input(term(), String.t()) :: {:ok, draft()} | :stale | :invalid
  def input(%{"package" => attrs}, current_generation) when is_map(attrs) do
    case Map.get(attrs, "generation") do
      generation when is_binary(generation) and generation == current_generation ->
        if not is_struct(attrs) and map_size(attrs) == 5 and
             Enum.all?(@fields, &safe_text?(attrs[&1])) and
             attrs["runtime"] in ~w(opencode codex claude_code),
           do: {:ok, Map.take(attrs, @fields)},
           else: :invalid

      _ ->
        :stale
    end
  end

  def input(_, _), do: :stale

  @spec classify(term()) :: outcome()
  def classify(%Error{code: "invalid_harness", details: [_ | _] = details}),
    do: if(name_details?(details, 100), do: :name, else: :generic)

  def classify(%Error{code: code}) when code in @runtime_codes, do: {:runtime, code}
  def classify(reason) when reason in @known_reasons, do: {:known, reason}
  def classify(_), do: :generic

  @spec message(:name_help | :name | :generic | {:runtime, String.t()}) :: String.t()
  def message(:name_help),
    do:
      "Use 1–64 characters. Start with a lowercase letter; then use lowercase letters, numbers, underscores or hyphens."

  def message(:name), do: "Check Package name."

  def message(:generic),
    do: "Check the package values and approved inputs, then try building again."

  def message({:runtime, "unsupported_runtime"}),
    do: "Use a supported coding agent target and runtime version listed below."

  def message({:runtime, "invalid_runtime_intent"}),
    do: "Review approved inputs for the selected coding agent target, then build again."

  def message({:runtime, "unsupported_required_control"}),
    do:
      "The selected coding agent cannot represent a required control. Review approved inputs or choose a compatible target."

  def message({:runtime, "runtime_unqualified"}),
    do:
      "Use a supported runtime profile. Managed execution requires a separately qualified runtime and backend."

  defp safe_text?(value) when is_binary(value) and byte_size(value) <= 4096,
    do: String.valid?(value) and not String.contains?(value, [<<0>>, "\r", "\n"])

  defp safe_text?(_), do: false

  defp name_details?([], _remaining), do: true

  defp name_details?([detail | rest], remaining) when remaining > 0 and detail in @name_details,
    do: name_details?(rest, remaining - 1)

  defp name_details?(_, _), do: false
end
