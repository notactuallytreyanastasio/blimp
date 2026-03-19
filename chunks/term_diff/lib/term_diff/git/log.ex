defmodule TermDiff.Git.Log do
  @moduledoc "Parse git log output. Pure functions."

  @type log_entry :: %{hash: String.t(), message: String.t()}

  @spec parse_oneline(String.t()) :: [log_entry()]
  def parse_oneline(""), do: []

  def parse_oneline(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_oneline_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec parse_oneline_entry(String.t()) :: log_entry() | nil
  defp parse_oneline_entry(line) do
    case String.split(line, " ", parts: 2) do
      [hash, message] -> %{hash: hash, message: message}
      _ -> nil
    end
  end
end
