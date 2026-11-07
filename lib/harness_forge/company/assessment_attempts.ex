defmodule HarnessForge.Company.AssessmentAttempts do
  @moduledoc false
  alias HarnessForge.Company.AssessmentValidation, as: Validation
  alias HarnessForge.Evidence.Store
  @keys [:authorize, :session_fingerprint, :view_generation, :reset_token]
  @salt "company-assessment-attempt-v1"

  def options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == Enum.sort(@keys) and
         is_function(opts[:authorize], 0) and Validation.digest?(opts[:session_fingerprint]) and
         Validation.hex?(opts[:view_generation], 32) and is_integer(opts[:reset_token]) and
         opts[:reset_token] >= 0,
       do: :ok,
       else: {:error, :invalid_input}
  end

  def options(_), do: {:error, :invalid_input}

  def authorize(opts) do
    if opts[:authorize].() === true, do: :ok, else: {:error, :operator_session_revoked}
  rescue
    _ -> {:error, :operator_session_revoked}
  catch
    _, _ -> {:error, :operator_session_revoked}
  end

  def mint(rubric, opts) do
    id = Ecto.UUID.generate()
    token = Phoenix.Token.sign(secret(), @salt, payload(rubric, id, opts), max_age: 43_200)

    {:ok,
     %{
       "attempt_id" => id,
       "attempt_token" => token,
       "rubric_id" => rubric.id,
       "rubric_revision_hash" => rubric.revision_hash
     }}
  end

  def verify(token, rubric, id, opts) do
    case Phoenix.Token.verify(secret(), @salt, token, max_age: 43_200) do
      {:ok, actual} ->
        if actual == payload(rubric, id, opts), do: :ok, else: {:error, :invalid_attempt_token}

      _ ->
        {:error, :invalid_attempt_token}
    end
  rescue
    _ -> {:error, :invalid_attempt_token}
  end

  defp payload(rubric, id, opts),
    do: %{
      "version" => 1,
      "workspace_id" => Store.workspace(),
      "session_fingerprint" => opts[:session_fingerprint],
      "view_generation" => opts[:view_generation],
      "reset_token" => opts[:reset_token],
      "rubric_id" => rubric.id,
      "rubric_revision_hash" => rubric.revision_hash,
      "attempt_id" => id
    }

  defp secret,
    do:
      Application.fetch_env!(:harness_forge, HarnessForgeWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)
end
