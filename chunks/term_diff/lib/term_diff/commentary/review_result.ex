defmodule TermDiff.Commentary.ReviewResult do
  @moduledoc "The full result of a review cycle: summary + per-file annotations."

  @type t :: %__MODULE__{
          summary: String.t(),
          annotations: [TermDiff.Commentary.Annotation.t()],
          diff_hash: String.t() | nil,
          reviewed_at: DateTime.t() | nil
        }

  defstruct [:summary, :diff_hash, :reviewed_at, annotations: []]
end
