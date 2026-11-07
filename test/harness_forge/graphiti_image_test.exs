defmodule HarnessForge.Graphiti.ImageTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Graphiti.Image
  alias HarnessForge.Evidence.Store

  defp archive(entries) do
    path = Path.join(System.tmp_dir!(), "hf-image-test-" <> Ecto.UUID.generate() <> ".tar")

    try do
      :ok = :erl_tar.create(String.to_charlist(path), entries, [])
      File.read!(path)
    after
      File.rm(path)
    end
  end

  test "memory-only verifier measures exact bytes and rejects changed, missing or extra application files" do
    bytes = archive([{~c"./worker.py", "trusted"}, {~c"./source.lock.json", "locked"}])
    pins = %{"worker.py" => Store.hash("trusted"), "source.lock.json" => Store.hash("locked")}
    assert {:ok, ^pins} = Image.verify_archive(bytes, pins)

    assert {:error, :graph_image_mismatch} =
             Image.verify_archive(bytes, Map.put(pins, "worker.py", Store.hash("substituted")))

    assert {:error, :graph_image_mismatch} =
             Image.verify_archive(bytes, Map.delete(pins, "worker.py"))

    assert {:error, :graph_image_mismatch} =
             Image.verify_archive(bytes, Map.put(pins, "extra.py", Store.hash("x")))
  end

  test "duplicate or escaping archive paths cannot substitute a pinned import" do
    pins = %{"worker.py" => Store.hash("x")}
    duplicate = archive([{~c"worker.py", "x"}, {~c"./worker.py", "x"}])
    assert {:error, :graph_image_mismatch} = Image.verify_archive(duplicate, pins)
    escaping = archive([{~c"../worker.py", "x"}])

    assert {:error, :graph_image_mismatch} =
             Image.verify_archive(escaping, %{"../worker.py" => Store.hash("x")})

    assert {:error, :graph_image_mismatch} = Image.verify_archive("not an archive", pins)

    assert {:error, :graph_image_mismatch} =
             Image.verify_archive(:binary.copy(<<0>>, 8_388_609), pins)
  end

  test "unqualified image names do not invoke docker" do
    assert {:error, :graph_image_mismatch} =
             Image.verify("unix:///tmp/missing.sock", "worker:latest")

    assert {:error, :graph_image_mismatch} =
             Image.verify("tcp://foreign.invalid:2375", "sha256:invalid")
  end
end
