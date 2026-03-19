defmodule TermDiff.Git.Types do
  @moduledoc "Data structures for representing git status, diffs, hunks, and lines."

  defmodule FileEntry do
    @moduledoc "A single file from git status output."

    @type file_status :: :modified | :added | :deleted | :renamed | :untracked | nil

    @type t :: %__MODULE__{
            path: String.t(),
            staged_status: file_status(),
            unstaged_status: file_status()
          }

    defstruct [:path, :staged_status, :unstaged_status]
  end

  defmodule DiffLine do
    @moduledoc "A single line within a diff hunk."

    @type line_type :: :context | :addition | :deletion

    @type t :: %__MODULE__{
            type: line_type(),
            content: String.t(),
            old_line_number: non_neg_integer() | nil,
            new_line_number: non_neg_integer() | nil
          }

    defstruct [:type, :content, :old_line_number, :new_line_number]
  end

  defmodule Hunk do
    @moduledoc "A single hunk from a unified diff."

    @type t :: %__MODULE__{
            header: String.t(),
            old_start: non_neg_integer(),
            old_count: non_neg_integer(),
            new_start: non_neg_integer(),
            new_count: non_neg_integer(),
            lines: [DiffLine.t()],
            collapsed: boolean(),
            highlighted_at: DateTime.t() | nil
          }

    defstruct [
      :header,
      :old_start,
      :old_count,
      :new_start,
      :new_count,
      lines: [],
      collapsed: false,
      highlighted_at: nil
    ]
  end

  defmodule FileDiff do
    @moduledoc "Complete diff for a single file."

    @type t :: %__MODULE__{
            path: String.t(),
            old_path: String.t() | nil,
            hunks: [Hunk.t()],
            binary: boolean(),
            additions: non_neg_integer(),
            deletions: non_neg_integer()
          }

    defstruct [:path, :old_path, hunks: [], binary: false, additions: 0, deletions: 0]
  end

  defmodule RepoState do
    @moduledoc "Complete state of the monitored repository."

    @type t :: %__MODULE__{
            files: [FileEntry.t()],
            diffs: %{String.t() => FileDiff.t()},
            branch: String.t() | nil,
            last_updated: DateTime.t() | nil
          }

    defstruct files: [], diffs: %{}, branch: nil, last_updated: nil
  end
end
