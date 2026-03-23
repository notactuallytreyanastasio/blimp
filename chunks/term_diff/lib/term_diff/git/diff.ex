defmodule TermDiff.Git.Diff do
  @moduledoc "Parse unified diff output into FileDiff/Hunk/DiffLine structs. Pure functions."

  alias TermDiff.Git.Types.{FileDiff, Hunk, DiffLine}

  @spec parse(String.t()) :: [FileDiff.t()]
  def parse(""), do: []

  def parse(raw_diff) do
    raw_diff
    |> split_file_sections()
    |> Enum.map(&parse_file_section/1)
  end

  @spec split_file_sections(String.t()) :: [String.t()]
  defp split_file_sections(raw) do
    raw
    |> String.split(~r/^diff --git /m)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&("diff --git " <> &1))
  end

  @spec parse_file_section(String.t()) :: FileDiff.t()
  defp parse_file_section(section) do
    lines = String.split(section, "\n")
    path = extract_path(hd(lines))

    if binary_diff?(section) do
      %FileDiff{path: path, binary: true}
    else
      hunks = extract_hunks(lines)
      {additions, deletions} = count_changes(hunks)

      %FileDiff{
        path: path,
        hunks: hunks,
        additions: additions,
        deletions: deletions
      }
    end
  end

  @spec extract_path(String.t()) :: String.t()
  defp extract_path(line) do
    case Regex.run(~r/^diff --git a\/(.+) b\//, line) do
      [_, path] -> path
      _ -> "unknown"
    end
  end

  @spec binary_diff?(String.t()) :: boolean()
  defp binary_diff?(section) do
    String.contains?(section, "Binary files")
  end

  @spec extract_hunks([String.t()]) :: [Hunk.t()]
  defp extract_hunks(lines) do
    lines
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        if String.starts_with?(line, "@@") do
          if acc, do: {:cont, acc, [line]}, else: {:cont, [line]}
        else
          if acc, do: {:cont, acc ++ [line]}, else: {:cont, nil}
        end
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&parse_hunk/1)
  end

  @spec parse_hunk([String.t()]) :: Hunk.t()
  defp parse_hunk([header_line | body_lines]) do
    {old_start, old_count, new_start, new_count} = parse_hunk_header(header_line)

    {lines, _old_ln, _new_ln} =
      body_lines
      |> Enum.reject(&String.starts_with?(&1, "\\"))
      |> Enum.reduce({[], old_start, new_start}, fn line, {acc, old_ln, new_ln} ->
        {diff_line, next_old, next_new} = parse_diff_line(line, old_ln, new_ln)
        {acc ++ [diff_line], next_old, next_new}
      end)

    %Hunk{
      header: header_line,
      old_start: old_start,
      old_count: old_count,
      new_start: new_start,
      new_count: new_count,
      lines: lines
    }
  end

  @spec parse_hunk_header(String.t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp parse_hunk_header(header) do
    case Regex.run(~r/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/, header) do
      [_, old_s, old_c, new_s, new_c] ->
        {to_int(old_s), to_int(old_c, 1), to_int(new_s), to_int(new_c, 1)}

      _ ->
        {0, 0, 0, 0}
    end
  end

  defp to_int(str, default \\ 0)
  defp to_int(nil, default), do: default
  defp to_int("", default), do: default
  defp to_int(str, _default), do: String.to_integer(str)

  @spec parse_diff_line(String.t(), non_neg_integer(), non_neg_integer()) ::
          {DiffLine.t(), non_neg_integer(), non_neg_integer()}
  defp parse_diff_line("+" <> content, old_ln, new_ln) do
    {%DiffLine{type: :addition, content: content, new_line_number: new_ln}, old_ln, new_ln + 1}
  end

  defp parse_diff_line("-" <> content, old_ln, new_ln) do
    {%DiffLine{type: :deletion, content: content, old_line_number: old_ln}, old_ln + 1, new_ln}
  end

  defp parse_diff_line(" " <> content, old_ln, new_ln) do
    {%DiffLine{
       type: :context,
       content: content,
       old_line_number: old_ln,
       new_line_number: new_ln
     }, old_ln + 1, new_ln + 1}
  end

  defp parse_diff_line(content, old_ln, new_ln) do
    {%DiffLine{
       type: :context,
       content: content,
       old_line_number: old_ln,
       new_line_number: new_ln
     }, old_ln + 1, new_ln + 1}
  end

  @spec count_changes([Hunk.t()]) :: {non_neg_integer(), non_neg_integer()}
  defp count_changes(hunks) do
    Enum.reduce(hunks, {0, 0}, fn hunk, {adds, dels} ->
      hunk_adds = Enum.count(hunk.lines, &(&1.type == :addition))
      hunk_dels = Enum.count(hunk.lines, &(&1.type == :deletion))
      {adds + hunk_adds, dels + hunk_dels}
    end)
  end
end
