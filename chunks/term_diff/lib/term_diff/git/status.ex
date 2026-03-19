defmodule TermDiff.Git.Status do
  @moduledoc "Parse git status --porcelain output into FileEntry structs. Pure functions."

  alias TermDiff.Git.Types.FileEntry

  @spec parse(String.t()) :: [FileEntry.t()]
  def parse(raw_output) do
    raw_output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec parse_line(String.t()) :: FileEntry.t() | nil
  defp parse_line(<<staged, unstaged, ?\s, path::binary>>) do
    %FileEntry{
      path: String.trim(path),
      staged_status: char_to_status(staged),
      unstaged_status: char_to_status(unstaged)
    }
  end

  defp parse_line(_), do: nil

  @spec char_to_status(integer()) :: FileEntry.file_status()
  defp char_to_status(?M), do: :modified
  defp char_to_status(?A), do: :added
  defp char_to_status(?D), do: :deleted
  defp char_to_status(?R), do: :renamed
  defp char_to_status(??), do: :untracked
  defp char_to_status(_), do: nil
end
