defmodule HarnessForge.SetupLocalImportBoundsTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Evidence.LocalImport

  setup do
    root = Path.join([File.cwd!(), "tmp", "bounded-read-" <> Ecto.UUID.generate()])
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "policy.md")}
  end

  test "reserved allowance counts UTF-8 bytes and permits an exact empty file", c do
    body = "مراجعة التغييرات ✅\n"
    File.write!(c.path, body)
    assert {:ok, observed} = LocalImport.inspect_document(c.root, c.path)
    assert observed["size"] == byte_size(body)
    assert {:ok, %{"body" => ^body}} = LocalImport.read_document(c.root, c.path, bounds(observed))
    File.write!(c.path, "")
    assert {:ok, empty} = LocalImport.inspect_document(c.root, c.path)
    assert {:ok, %{"body" => ""}} = LocalImport.read_document(c.root, c.path, bounds(empty))
  end

  test "a file grown or replaced after reservation cannot use that allowance", c do
    File.write!(c.path, "before")
    {:ok, observed} = LocalImport.inspect_document(c.root, c.path)
    File.write!(c.path, "before plus a new byte range")

    assert {:error, :source_unavailable} =
             LocalImport.read_document(c.root, c.path, bounds(observed))

    File.rename!(c.path, Path.join(c.root, "prior-policy.md"))
    File.write!(c.path, "after!")

    assert {:error, :source_unavailable} =
             LocalImport.read_document(c.root, c.path, bounds(observed))
  end

  test "symlink replacement and escaping paths cannot return outside bytes", c do
    File.write!(c.path, "inside")
    {:ok, observed} = LocalImport.inspect_document(c.root, c.path)
    outside = Path.join(Path.dirname(c.root), "outside-" <> Ecto.UUID.generate() <> ".md")
    File.write!(outside, "OUTSIDE_CANARY")
    on_exit(fn -> File.rm(outside) end)
    File.rm!(c.path)
    File.ln_s!(outside, c.path)

    assert {:error, :symlink_not_allowed} =
             LocalImport.read_document(c.root, c.path, bounds(observed))

    assert {:error, _} = LocalImport.inspect_document(c.root, outside)
  end

  test "metadata rejects oversized bodies before reservation and binary reads fail closed", c do
    File.write!(c.path, :binary.copy("a", 1_048_577))
    assert {:error, :file_too_large} = LocalImport.inspect_document(c.root, c.path)
    File.write!(c.path, <<0, 255, 1>>)
    {:ok, observed} = LocalImport.inspect_document(c.root, c.path)
    assert {:error, :binary_file} = LocalImport.read_document(c.root, c.path, bounds(observed))

    assert {:error, :invalid_input} =
             LocalImport.read_document(c.root, c.path, %{
               "allowance_bytes" => 1_048_577,
               "fingerprint" => %{}
             })
  end

  defp bounds(observed),
    do: %{"allowance_bytes" => observed["size"], "fingerprint" => observed["fingerprint"]}
end
