defmodule HarnessForge.Models.StageUsageTest do
  use ExUnit.Case, async: true
  alias HarnessForge.Models.StageAuthority

  test "embedding prompt/total usage settles input tokens with zero generated tokens" do
    pin = %{"stage" => "embedder", "endpoint" => "https://api.openai.com/v1/embeddings"}

    assert %{input_tokens: 17, output_tokens: 0} =
             StageAuthority.reported_usage(%{"prompt_tokens" => 17, "total_tokens" => 17}, pin)

    assert nil ==
             StageAuthority.reported_usage(%{"prompt_tokens" => 17, "total_tokens" => 18}, pin)

    assert nil == StageAuthority.reported_usage(%{"prompt_tokens" => 17}, pin)
  end

  test "input-only usage cannot settle generation or an unknown route as zero cost" do
    usage = %{"prompt_tokens" => 17, "total_tokens" => 17}

    assert nil ==
             StageAuthority.reported_usage(usage, %{
               "stage" => "extraction",
               "endpoint" => "https://api.openai.com/v1/chat/completions"
             })

    assert nil ==
             StageAuthority.reported_usage(usage, %{
               "stage" => "embedder",
               "endpoint" => "https://api.openai.com/v1/chat/completions"
             })

    assert nil == StageAuthority.reported_usage(nil, %{})
  end
end
