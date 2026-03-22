defmodule TermDiff.Diff.LineSelection do
  @moduledoc "Pure state for line selection in the diff viewer. No side effects."

  @type t :: %__MODULE__{
          file_path: String.t() | nil,
          anchor_line: non_neg_integer() | nil,
          focus_line: non_neg_integer() | nil,
          active: boolean()
        }

  defstruct file_path: nil, anchor_line: nil, focus_line: nil, active: false

  @spec start(t(), String.t(), non_neg_integer()) :: t()
  def start(_sel, file_path, line_number) do
    %__MODULE__{file_path: file_path, anchor_line: line_number, focus_line: line_number, active: true}
  end

  @spec extend(t(), non_neg_integer()) :: t()
  def extend(%{active: true} = sel, line_number), do: %{sel | focus_line: line_number}
  def extend(sel, _line_number), do: sel

  @spec clear(t()) :: t()
  def clear(_sel), do: %__MODULE__{}

  @spec selected_range(t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def selected_range(%{active: false}), do: nil
  def selected_range(%{anchor_line: a, focus_line: f}), do: {min(a, f), max(a, f)}

  @spec line_selected?(t(), non_neg_integer() | nil) :: boolean()
  def line_selected?(_sel, nil), do: false
  def line_selected?(%{active: false}, _line), do: false

  def line_selected?(sel, line) do
    case selected_range(sel) do
      {s, e} -> line >= s and line <= e
      nil -> false
    end
  end
end
