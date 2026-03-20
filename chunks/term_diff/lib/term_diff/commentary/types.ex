defmodule TermDiff.Commentary.Types do
  @moduledoc "Data structures for AI commentary on diffs."

  defmodule Annotation do
    @moduledoc "A single comment attached to a line range in a file."

    @type severity :: :info | :warning | :issue

    @type t :: %__MODULE__{
            file: String.t(),
            start_line: pos_integer(),
            end_line: pos_integer(),
            comment: String.t(),
            severity: severity(),
            id: String.t()
          }

    defstruct [:file, :start_line, :end_line, :comment, :severity, :id]
  end

  defmodule ReviewResult do
    @moduledoc "The full result of a review cycle: summary + per-file annotations."

    @type t :: %__MODULE__{
            summary: String.t(),
            annotations: [TermDiff.Commentary.Types.Annotation.t()],
            diff_hash: String.t() | nil,
            reviewed_at: DateTime.t() | nil
          }

    defstruct [:summary, :diff_hash, :reviewed_at, annotations: []]
  end

  defmodule FileCommentary do
    @moduledoc "Commentary state for a single file, with staleness tracking."

    @type staleness :: :fresh | :stale | :reviewing

    @type t :: %__MODULE__{
            file: String.t(),
            diff_hash: String.t(),
            annotations: [TermDiff.Commentary.Types.Annotation.t()],
            staleness: staleness(),
            reviewed_at: DateTime.t() | nil
          }

    defstruct [:file, :diff_hash, :reviewed_at, annotations: [], staleness: :stale]
  end
end
