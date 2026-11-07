defmodule HarnessForge.Graphiti.ReplayTranscriptTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Graphiti.ReplayTranscript

  defp page(logical, value) do
    %{
      "logical_call_id" => logical,
      "stage_id" => "stage:public",
      "config_digest" => String.duplicate("a", 64),
      "prompt_name" => "extract_nodes.extract_text",
      "phase" => "inputs",
      "seam_id" => "llm.messages.v1",
      "entries" => [%{"value" => %{"role" => "system", "content" => value}, "receipt_ref" => nil}]
    }
  end

  test "original input slots are immutable and exact replay cannot discard retained native options" do
    input = page("call:1", "Original public input")
    assert {:ok, cache} = ReplayTranscript.retain_page(ReplayTranscript.new(), input)
    cache = put_in(cache, ["inputs", "call:1", "max_tokens"], 1024)
    assert {:ok, ^cache} = ReplayTranscript.retain_page(cache, input)

    assert {:error, :closure_incomplete} =
             ReplayTranscript.retain_page(cache, page("call:1", "Substituted input"))

    assert {:error, :closure_incomplete} =
             ReplayTranscript.retain_receipt(ReplayTranscript.new(), nil, %{}, %{})
  end

  test "logical completion drops the input and raw transcript together without dropping another call" do
    assert {:ok, cache} =
             ReplayTranscript.retain_page(ReplayTranscript.new(), page("call:1", "One"))

    assert {:ok, cache} = ReplayTranscript.retain_page(cache, page("call:2", "Two"))
    cache = put_in(cache, ["receipts", "call:1"], [%{"body" => "Raw response marker"}])

    completed = %{
      page("call:1", "ignored")
      | "phase" => "derived",
        "seam_id" => "llm.response.v1"
    }

    assert {:ok, cleared} = ReplayTranscript.retain_page(cache, completed)
    refute Map.has_key?(cleared["inputs"], "call:1")
    refute Map.has_key?(cleared["receipts"], "call:1")
    assert cleared["inputs"]["call:2"] == cache["inputs"]["call:2"]
  end

  test "retention limits bound original input and simultaneously pending calls" do
    assert {:error, :closure_incomplete} =
             ReplayTranscript.retain_page(
               ReplayTranscript.new(),
               page("oversize", String.duplicate("x", 49_153))
             )

    cache =
      Enum.reduce(1..16, ReplayTranscript.new(), fn i, previous ->
        {:ok, next} = ReplayTranscript.retain_page(previous, page("call:#{i}", "Public"))
        next
      end)

    assert {:error, :closure_incomplete} =
             ReplayTranscript.retain_page(cache, page("call:17", "Public"))
  end
end
