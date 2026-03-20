defmodule TermDiff.Commentary.FileCommentary do
  @moduledoc "Commentary state for a single file, with staleness tracking."

  @type staleness :: :fresh | :stale | :reviewing

  @type t :: %__MODULE__{
          file: String.t(),
          diff_hash: String.t(),
          annotations: [TermDiff.Commentary.Annotation.t()],
          staleness: staleness(),
          reviewed_at: DateTime.t() | nil
        }

  defstruct [:file, :diff_hash, :reviewed_at, annotations: [], staleness: :stale]
end
