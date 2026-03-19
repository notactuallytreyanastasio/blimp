defmodule TermDiff.Repo do
  use Ecto.Repo,
    otp_app: :term_diff,
    adapter: Ecto.Adapters.Postgres
end
