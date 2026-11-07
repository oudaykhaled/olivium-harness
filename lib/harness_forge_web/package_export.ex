defmodule HarnessForgeWeb.PackageExport do
  @moduledoc "Pure, fixed-copy presentation of an export result; never export admission."
  alias HarnessForge.Contracts.Error

  @unconfirmed "Export completion could not be confirmed. Inspect the destination before retrying with a new directory."

  @spec valid_digest?(term()) :: boolean()
  def valid_digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.valid?(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  def valid_digest?(_), do: false

  @spec valid_target?(term()) :: boolean()
  def valid_target?(value) when is_binary(value) and byte_size(value) in 1..4096,
    do: String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>)

  def valid_target?(_), do: false

  @doc "Confirms only the exact submitted identity and maps every other result to fixed copy."
  @spec present(term(), String.t(), String.t()) :: map()
  def present({:ok, %{"digest" => digest, "path" => path}}, expected_digest, expected_path) do
    if valid_digest?(digest) and safe_path?(path) and digest == expected_digest and
         path == expected_path,
       do: %{status: :success, path: path, message: "Export complete", invalid_target: false},
       else: failure(@unconfirmed)
  end

  def present({:error, %Error{code: "export_conflict"}}, _, _),
    do:
      failure(
        "Export destination already exists. Choose a new directory. This refused attempt did not replace the existing destination.",
        true
      )

  def present({:error, %Error{code: "unsafe_artifact_path"}}, _, _),
    do:
      failure(
        "Use a new absolute directory under an existing real parent, without symbolic links or traversal.",
        true
      )

  def present({:error, %Error{code: "invalid_artifact"}}, _, _),
    do:
      failure(
        "Package integrity could not be verified. Review the package and rebuild from current approved inputs."
      )

  def present({:error, :stale_or_revoked_evidence}, _, _),
    do:
      failure(
        "This package uses withdrawn or changed evidence. Review current claims in Evidence and rebuild."
      )

  def present({:error, :stale_or_revoked_plan}, _, _),
    do:
      failure(
        "This package's Company plan is no longer eligible. Review and approve the current exact plan, then rebuild."
      )

  def present({:error, :privacy_operation_incomplete}, _, _),
    do:
      failure(
        "Workspace content removal is incomplete. Resolve the pending privacy operation before exporting."
      )

  def present(_, _, _), do: failure(@unconfirmed)

  defp safe_path?(path) do
    valid_target?(path) and Path.type(path) == :absolute and path != "/" and
      not String.contains?(path, "\\") and
      Enum.all?(String.split(path, "/", trim: true), &(&1 not in [".", ".."]))
  end

  defp failure(message, invalid_target \\ false),
    do: %{status: :error, message: message, invalid_target: invalid_target}
end
