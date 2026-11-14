defmodule HarnessForge.Analyzers.Privacy do
  @moduledoc """
  Privacy guard for repository analysis.

  Secret-like paths are never opened, whether or not git tracks them. Secret-looking
  tokens are redacted from every string before a signals document leaves the analyzer.
  Both checks are heuristics: they lower the risk and do not prove a repository is
  free of secrets.
  """

  @redacted "[REDACTED]"

  @secret_directories ~w(.ssh .aws .gnupg .azure .kube .secrets secrets private_keys)
  @secret_names ~w(.envrc .netrc .npmrc .pypirc .dockercfg .git-credentials .htpasswd token.json auth.json)
  @secret_extensions ~w(.pem .key .p12 .pfx .jks .keystore .kdbx .tfvars .tfstate .ovpn .gpg)

  @secret_stem ~r/\A(?:\.env(?:\..*)?|.*\.env|id_(?:rsa|dsa|ecdsa|ed25519)(?:\..*)?|secrets?(?:\..*)?|credentials?(?:\..*)?|.*credentials.*\.json|service[-_]account.*\.json|.*\.tfstate\..*)\z/

  @token_patterns [
    ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{20,}\b/,
    ~r/\bsk-[A-Za-z0-9_-]{20,}/,
    ~r/\bxox[abeprs]-[A-Za-z0-9-]{10,}/,
    ~r/\bnpm_[A-Za-z0-9]{36}\b/,
    ~r/\bAIza[0-9A-Za-z_-]{35}\b/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}/,
    ~r/\bpypi-[A-Za-z0-9_-]{16,}/,
    ~r/\bglpat-[A-Za-z0-9_-]{16,}/,
    ~r/\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}/,
    ~r/\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}/,
    ~r/\bhf_[A-Za-z0-9]{30,}\b/,
    ~r/\bdop_v1_[a-f0-9]{32,}\b/,
    ~r|\b[a-z][a-z0-9+.-]*://[^/\s:@]*:[^/\s@]+@|i,
    ~r|\b[a-z][a-z0-9+.-]*://[A-Za-z0-9_-]{16,}@|i,
    ~r/(?i)--(?:token|password|passwd|api-key|apikey|auth-token|secret)(?:=|\s+)['"]?[^\s'"-][^\s'"]*/,
    ~r/(?i)\b(?:api[_-]?key|secret|token|passw(?:or)?d)\b\s*[:=]\s*['"]?[A-Za-z0-9_.\/+=-]{16,}/
  ]

  @email ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
  @mention ~r/(?:^|[\s(])@[A-Za-z][A-Za-z0-9-]*/

  @doc "True when a relative path must never be opened."
  @spec secret_path?(String.t()) :: boolean()
  def secret_path?(path) when is_binary(path) do
    segments = path |> String.downcase() |> String.split("/")
    name = List.last(segments)

    Enum.any?(segments, &(&1 in @secret_directories)) or name in @secret_names or
      Path.extname(name) in @secret_extensions or Regex.match?(@secret_stem, name)
  end

  @doc """
  True when text contains something that looks like a credential: a known token shape,
  or a long token mixing upper case, lower case and digits. Callers drop the whole
  command or rule rather than redact it.
  """
  @spec secret?(String.t()) :: boolean()
  def secret?(text) when is_binary(text),
    do: Enum.any?(@token_patterns, &Regex.match?(&1, text)) or high_entropy_token?(text)

  defp high_entropy_token?(text) do
    ~r/[A-Za-z0-9_+=-]{32,}/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.any?(fn token ->
      Regex.match?(~r/[A-Z]/, token) and Regex.match?(~r/[a-z]/, token) and
        length(Regex.scan(~r/[0-9]/, token)) >= 4
    end)
  end

  @doc "True when text carries a personal address or handle."
  @spec identity?(String.t()) :: boolean()
  def identity?(text) when is_binary(text),
    do: Regex.match?(@email, text) or Regex.match?(@mention, text)

  @doc "Redact every string inside a JSON value and return it with the replacement count."
  @spec scrub(term()) :: {term(), non_neg_integer()}
  def scrub(value) when is_binary(value), do: redact(value)

  def scrub(value) when is_list(value) do
    {items, count} = Enum.map_reduce(value, 0, fn item, total -> add(scrub(item), total) end)
    {items, count}
  end

  def scrub(value) when is_map(value) do
    {pairs, count} =
      Enum.map_reduce(value, 0, fn {key, item}, total ->
        {clean, total} = add(scrub(item), total)
        {{key, clean}, total}
      end)

    {Map.new(pairs), count}
  end

  def scrub(value), do: {value, 0}

  defp add({value, count}, total), do: {value, count + total}

  defp redact(text) do
    Enum.reduce(@token_patterns, {text, 0}, fn pattern, {current, count} ->
      found = length(Regex.scan(pattern, current))

      if found == 0,
        do: {current, count},
        else: {Regex.replace(pattern, current, @redacted), count + found}
    end)
  end
end
