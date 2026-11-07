defmodule HarnessForge.Repo do
  use Ecto.Repo,
    otp_app: :harness_forge,
    adapter: Ecto.Adapters.SQLite3
end
