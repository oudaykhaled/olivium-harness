defmodule HarnessForge.Graphiti.Private do
  @moduledoc false
  alias HarnessForge.{Contracts, Workspaces}

  # Credentials survive only in encrypted workspace-local state. They are
  # bound to the original workspace, partition and storage incarnation. The
  # snapshot restore path discards ciphertext and all original resource IDs.
  def seal(value, partition, instance) do
    nonce = :crypto.strong_rand_bytes(12)
    bytes = Contracts.canonical_json(value)

    {cipher, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key(),
        nonce,
        bytes,
        aad(partition, instance),
        true
      )

    "v1." <> Base.url_encode64(nonce <> tag <> cipher, padding: false)
  end

  def open("v1." <> encoded, partition, instance) do
    with {:ok, <<nonce::binary-size(12), tag::binary-size(16), cipher::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         true <- byte_size(cipher) in 1..16_384,
         bytes when is_binary(bytes) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key(),
             nonce,
             cipher,
             aad(partition, instance),
             tag,
             false
           ),
         {:ok, value} <- Jason.decode(bytes),
         true <- is_map(value) do
      {:ok, value}
    else
      _ -> {:error, :reconcile_required}
    end
  rescue
    _ -> {:error, :reconcile_required}
  end

  def open(_, _, _), do: {:error, :reconcile_required}

  defp aad(partition, instance),
    do:
      Contracts.canonical_json(%{
        "workspace_id" => Workspaces.current_id(),
        "partition_id" => partition,
        "instance_id" => instance,
        "purpose" => "graph-backend-v1"
      })

  defp key do
    secret =
      Application.fetch_env!(:harness_forge, HarnessForgeWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :crypto.mac(:hmac, :sha256, secret, "HF-GRAPH-CREDENTIALS-v1")
  end
end
