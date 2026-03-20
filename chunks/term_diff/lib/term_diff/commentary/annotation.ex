defmodule TermDiff.Commentary.Annotation do
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
