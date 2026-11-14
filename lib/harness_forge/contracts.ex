defmodule HarnessForge.Contracts do
  @moduledoc """
  Frozen v1alpha1 interchange contracts and deterministic JSON hashing.

  `harnessforge.dev/v1alpha2` specs are validated against their own schema and
  semantic rules (`HarnessForge.Contracts.HarnessV2`). Every other value keeps
  the v1alpha1 path unchanged so stored artifacts continue to verify.

  String keys are required. Canonical JSON accepts integers, but never floats,
  and sorts object keys by their UTF-8 bytes. No Unicode normalization occurs.
  This is the HarnessForge canonical format, not RFC 8785.
  """
  alias HarnessForge.Contracts.{Error, HarnessV2}

  @schema_path Path.expand("../../priv/schemas/harness-v1alpha1.json", __DIR__)
  @external_resource @schema_path
  @schema @schema_path |> File.read!() |> Jason.decode!()
  @v2_schema_path Path.expand("../../priv/schemas/harness-v1alpha2.json", __DIR__)
  @external_resource @v2_schema_path
  @v2_schema @v2_schema_path |> File.read!() |> Jason.decode!()
  @v2_api_version HarnessV2.api_version()
  @max_bytes 2_000_000
  @max_depth 16

  @spec schema() :: map()
  def schema, do: @schema

  @spec schema_v2() :: map()
  def schema_v2, do: @v2_schema

  @doc "Decode bounded JSON, rejecting duplicate object keys before converting to maps."
  @spec decode_harness(binary()) :: {:ok, map()} | {:error, Error.t()}
  def decode_harness(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, value} <- decode_json(bytes), do: validate_harness(value)
  end

  def decode_harness(_), do: invalid(["$: JSON input exceeds 2000000 bytes"])

  @doc "Decode bounded canonical JSON without granting it a harness schema or authority."
  @spec decode_json(binary()) :: {:ok, term()} | {:error, Error.t()}
  def decode_json(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with :ok <- scan_depth(bytes, 0, false, false),
         {:ok, decoded} <- Jason.decode(bytes, objects: :ordered_objects),
         {:ok, value} <- ordered_to_maps(decoded),
         :ok <- validate_json_bounds(value) do
      {:ok, value}
    else
      _ -> invalid(["$: invalid JSON, duplicate keys, or excessive nesting"])
    end
  end

  def decode_json(_), do: invalid(["$: JSON input exceeds 2000000 bytes"])

  @spec validate_harness(term()) :: {:ok, map()} | {:error, Error.t()}
  def validate_harness(%{"apiVersion" => @v2_api_version} = value) do
    with :ok <- validate_json_bounds(value),
         [] <- check(value, @v2_schema, "$", @v2_schema),
         [] <- HarnessV2.semantic_errors(value) do
      {:ok, value}
    else
      {:error, %Error{} = error} -> {:error, error}
      errors when is_list(errors) -> invalid(errors)
    end
  end

  def validate_harness(value) do
    with :ok <- validate_json_bounds(value),
         [] <- check(value, @schema, "$", @schema),
         [] <- semantic_errors(value) do
      {:ok, value}
    else
      {:error, %Error{} = error} -> {:error, error}
      errors when is_list(errors) -> invalid(errors)
    end
  end

  @doc """
  Validate a bounded JSON document against one of our frozen schemas, reporting
  failures under `code`. Applies the same bounds and keyword subset as harness
  validation; callers add their own semantic checks.
  """
  @spec validate_document(term(), map(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def validate_document(value, schema, code) when is_map(schema) and is_binary(code) do
    with :ok <- validate_json_bounds(value),
         [] <- check(value, schema, "$", schema) do
      {:ok, value}
    else
      {:error, %Error{} = error} -> {:error, %{error | code: code}}
      errors when is_list(errors) -> invalid(errors, code)
    end
  end

  @doc "True for a contained relative path: not absolute, not home-relative, no `..` segment."
  @spec relative_path?(term()) :: boolean()
  def relative_path?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and not String.starts_with?(path, "~") and
      not String.contains?(path, ["\\", <<0>>]) and ".." not in String.split(path, "/")
  end

  def relative_path?(_), do: false

  @spec canonical_json(term()) :: binary()
  def canonical_json(value), do: value |> encode() |> IO.iodata_to_binary()

  @spec digest(term()) :: String.t()
  def digest(value), do: value |> canonical_json() |> sha256()

  @spec sha256(binary()) :: String.t()
  def sha256(bytes) when is_binary(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp encode(value) when is_map(value) and not is_struct(value) do
    pairs =
      value
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn
        {key, item} when is_binary(key) -> [Jason.encode!(key), ":", encode(item)]
        _ -> raise ArgumentError, "canonical JSON requires string object keys"
      end)

    ["{", Enum.intersperse(pairs, ","), "}"]
  end

  defp encode(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &encode/1), ","), "]"]

  defp encode(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: Jason.encode!(value)

  defp encode(_), do: raise(ArgumentError, "value is outside the canonical JSON contract")

  defp validate_json_bounds(value) do
    case bounded(value, 0, 0) do
      {:ok, _} ->
        :ok

      :error ->
        invalid(["$: expected bounded UTF-8 JSON with string keys, integers, and depth <= 16"])
    end
  end

  defp bounded(_, depth, size) when depth > @max_depth or size > @max_bytes, do: :error

  defp bounded(value, depth, size) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, size + 2}, fn {key, item}, {:ok, acc} ->
      with true <- is_binary(key),
           {:ok, next} <- bounded(key, depth + 1, acc),
           {:ok, total} <- bounded(item, depth + 1, next + 2) do
        {:cont, {:ok, total}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp bounded(value, depth, size) when is_list(value) do
    Enum.reduce_while(value, {:ok, size + 2}, fn item, {:ok, acc} ->
      case bounded(item, depth + 1, acc + 1) do
        {:ok, total} -> {:cont, {:ok, total}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp bounded(value, _, size) when is_binary(value) do
    if byte_size(value) <= @max_bytes and String.valid?(value) do
      total = size + byte_size(Jason.encode!(value))
      if total <= @max_bytes, do: {:ok, total}, else: :error
    else
      :error
    end
  end

  defp bounded(value, _, size) when is_integer(value) do
    if value >= -9_007_199_254_740_991 and value <= 9_007_199_254_740_991,
      do: {:ok, size + 17},
      else: :error
  end

  defp bounded(value, _, size) when is_boolean(value) or is_nil(value), do: {:ok, size + 5}
  defp bounded(_, _, _), do: :error

  defp scan_depth(_, depth, _, _) when depth > @max_depth, do: :error
  defp scan_depth(<<>>, _, _, _), do: :ok

  defp scan_depth(<<_, rest::binary>>, depth, true, true),
    do: scan_depth(rest, depth, true, false)

  defp scan_depth(<<92, rest::binary>>, depth, true, false),
    do: scan_depth(rest, depth, true, true)

  defp scan_depth(<<34, rest::binary>>, depth, in_string, false),
    do: scan_depth(rest, depth, not in_string, false)

  defp scan_depth(<<byte, rest::binary>>, depth, false, false) when byte in [123, 91],
    do: scan_depth(rest, depth + 1, false, false)

  defp scan_depth(<<byte, rest::binary>>, depth, false, false) when byte in [125, 93],
    do: scan_depth(rest, depth - 1, false, false)

  defp scan_depth(<<_, rest::binary>>, depth, in_string, escaped),
    do: scan_depth(rest, depth, in_string, escaped)

  defp ordered_to_maps(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
        case ordered_to_maps(item) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp ordered_to_maps(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case ordered_to_maps(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp ordered_to_maps(value), do: {:ok, value}

  # This validator intentionally implements only the keywords used by our frozen schema.
  defp check(value, %{"$ref" => "#/$defs/" <> name}, path, root),
    do: check(value, root["$defs"][name], path, root)

  defp check(value, %{"anyOf" => alternatives}, path, root) do
    if Enum.any?(alternatives, &(check(value, &1, path, root) == [])),
      do: [],
      else: [path <> ": no allowed value type matched"]
  end

  defp check(value, schema, path, root) do
    cond do
      Map.has_key?(schema, "const") and value != schema["const"] ->
        [path <> ": unexpected constant"]

      schema["type"] && not type?(value, schema["type"]) ->
        [path <> ": invalid " <> schema["type"]]

      schema["enum"] && value not in schema["enum"] ->
        [path <> ": unexpected enum value"]

      is_map(value) ->
        check_object(value, schema, path, root)

      is_list(value) ->
        check_array(value, schema, path, root)

      is_binary(value) ->
        check_string(value, schema, path)

      is_integer(value) ->
        range_errors(value, schema, path, "minimum", "maximum")

      true ->
        []
    end
  end

  defp type?(value, "object"), do: is_map(value) and not is_struct(value)
  defp type?(value, "array"), do: is_list(value)
  defp type?(value, "string"), do: is_binary(value)
  defp type?(value, "integer"), do: is_integer(value)
  defp type?(value, "boolean"), do: is_boolean(value)
  defp type?(value, "null"), do: is_nil(value)

  defp check_object(value, schema, path, root) do
    properties = schema["properties"] || %{}
    missing = Enum.filter(schema["required"] || [], &(not Map.has_key?(value, &1)))

    unknown =
      if schema["additionalProperties"] == false,
        do: Map.keys(value) -- Map.keys(properties),
        else: []

    Enum.map(missing, &(path <> "." <> &1 <> ": required")) ++
      Enum.map(unknown, &(path <> "." <> &1 <> ": unknown field")) ++
      Enum.flat_map(properties, fn {key, child} ->
        if Map.has_key?(value, key),
          do: check(value[key], child, path <> "." <> key, root),
          else: []
      end)
  end

  defp check_array(value, schema, path, root) do
    size_errors = range_errors(length(value), schema, path, "minItems", "maxItems")

    duplicate_errors =
      if schema["uniqueItems"] && length(Enum.uniq(value)) != length(value),
        do: [path <> ": duplicate items"],
        else: []

    child_errors =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        check(item, schema["items"] || %{}, "#{path}[#{index}]", root)
      end)

    size_errors ++ duplicate_errors ++ child_errors
  end

  defp check_string(value, schema, path) do
    length_errors = range_errors(String.length(value), schema, path, "minLength", "maxLength")

    pattern_errors =
      if schema["pattern"] && not Regex.match?(Regex.compile!(schema["pattern"]), value),
        do: [path <> ": invalid format"],
        else: []

    length_errors ++ pattern_errors
  end

  defp range_errors(value, schema, path, min_key, max_key) do
    if (schema[min_key] && value < schema[min_key]) ||
         (schema[max_key] && value > schema[max_key]),
       do: [path <> ": outside permitted bounds"],
       else: []
  end

  defp semantic_errors(%{"spec" => spec}) do
    rules = spec["rules"]
    goals = MapSet.new(spec["goals"], & &1["id"])

    duplicates =
      for section <- ["rules", "goals", "policies", "agents", "skills"],
          key = if(section in ["agents", "skills"], do: "name", else: "id"),
          ids = Enum.map(spec[section], & &1[key]),
          length(Enum.uniq(ids)) != length(ids),
          do: "$.spec.#{section}: duplicate identifiers"

    duplicates ++
      Enum.flat_map(rules, fn rule ->
        evidence_errors =
          Enum.flat_map(rule["evidence"], fn citation ->
            if citation["start_byte"] < citation["end_byte"],
              do: [],
              else: ["$.spec.rules: citation must have a nonempty byte range"]
          end)

        goal_id = rule["goal_id"]

        goal_errors =
          if goal_id && not MapSet.member?(goals, goal_id),
            do: ["$.spec.rules: goal_id does not reference a supplied goal"],
            else: []

        basis_errors =
          if rule["evidence"] == [] and is_nil(goal_id),
            do: ["$.spec.rules: evidence or an explicit goal is required"],
            else: []

        evidence_errors ++ goal_errors ++ basis_errors
      end)
  end

  defp invalid(details),
    do:
      {:error,
       %Error{
         code: "invalid_harness",
         message: "Harness specification failed validation",
         details: Enum.take(Enum.sort(details), 100)
       }}

  defp invalid(details, code),
    do:
      {:error,
       %Error{
         code: code,
         message: "Document failed contract validation",
         details: Enum.take(Enum.sort(details), 100)
       }}
end
