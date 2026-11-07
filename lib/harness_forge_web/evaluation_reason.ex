defmodule HarnessForgeWeb.EvaluationReason do
  @moduledoc false

  @transport_labels %{
    "coding_transport_unavailable" =>
      "This run could not verify a local Docker connection. Check Docker, then queue a new task evaluation.",
    "coding_transport_unsupported" =>
      "This run could not use a supported local Docker setup. Review the setup before queuing another task evaluation.",
    "local_docker_required" =>
      "This run requires a supported local Docker connection. Review the setup before queuing another task evaluation.",
    "coding_transport_changed" =>
      "This run could not verify the same local Docker setup throughout the attempt. It cannot qualify a release.",
    "coding_cleanup_context_invalid" =>
      "This run could not verify its cleanup information. Cleanup remains unresolved.",
    "coding_cleanup_origin_unknown" =>
      "This older run could not verify its original local Docker setup. Cleanup remains unresolved."
  }

  def transport_codes, do: Map.keys(@transport_labels)

  def label(nil), do: nil

  def label("model_not_selected"), do: "No selected model is configured for managed tasks."

  def label("runtime_backend_unavailable"),
    do: "This target has no managed execution backend. Review a supported target."

  def label("integrity_only"),
    do: "Saved package integrity passed. This does not qualify a coding runtime."

  def label("offline_runtime_smoke_only"),
    do:
      "The isolated runtime configuration checks passed. This does not qualify model-backed tasks."

  def label("finite_synthetic_task_observations"),
    do: "The built-in synthetic tasks passed. This does not establish company fitness."

  def label("operator_cancelled"), do: "This evaluation was cancelled."

  def label("application_restarted"),
    do: "This evaluation was interrupted when the application restarted."

  def label("restored_requires_reevaluation"),
    do: "This result came from a restored workspace and requires a new evaluation."

  def label(code) when code in ~w(teardown_failed usage_or_cleanup_unverified),
    do: "Cleanup or model usage could not be fully verified. This run cannot qualify a release."

  def label(code) when code in ~w(model_service_unavailable model_unavailable),
    do: "The selected model service or model could not be reached. Review its connection."

  def label(code) when code in ~w(runtime_cloud_disabled cloud_model_denied),
    do: "Managed coding tasks require a configured local model."

  def label("model_configuration_changed"),
    do:
      "The selected model configuration changed during this evaluation. It cannot qualify a release."

  def label("runtime_version_not_qualified"),
    do: "This package does not name a qualified runtime version."

  def label(code)
      when code in ~w(codex_image_receipt_missing codex_image_receipt_untrusted codex_image_receipt_mismatch codex_image_unverified codex_tools_unverified),
      do:
        "The local Codex environment is not verified for this model and harness. Review runtime setup before running a new task."

  def label(code) when code in ~w(codex_preflight_rejected codex_runtime_config_invalid),
    do:
      "Codex's active settings or enabled skills do not match this harness. Review runtime setup."

  def label("codex_events_rejected"),
    do: "Codex did not return a complete, verifiable task result. Inspect its recorded evidence."

  def label("local_model_identity_changed"),
    do: "The selected local model changed during this evaluation. Run a new check."

  def label("local_model_identity_unavailable"),
    do:
      "The selected local model could not be verified. Review its connection before running a task."

  def label(code) do
    Map.get(
      @transport_labels,
      code,
      "This run could not establish a verified result. Review its outcome and cleanup status."
    )
  end
end
