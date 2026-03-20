defmodule TermDiff.Commentary.Parser do
  @moduledoc "Parse Claude's JSON response into ReviewResult structs."

  alias TermDiff.Commentary.{Annotation, ReviewResult}

  @spec parse_response(String.t()) :: {:ok, ReviewResult.t()} | {:error, String.t()}
  def parse_response(raw_text) do
    with {:ok, json_str} <- extract_json(raw_text),
         {:ok, decoded} <- Jason.decode(json_str),
         {:ok, result} <- validate_and_build(decoded) do
      {:ok, result}
    end
  end

  defp extract_json(text) do
    cond do
      # Try markdown code fences first
      match = Regex.run(~r/```json\s*(.*?)\s*```/s, text) ->
        {:ok, Enum.at(match, 1)}

      # Try bare JSON object
      match = Regex.run(~r/\{.*\}/s, text) ->
        {:ok, hd(match)}

      true ->
        {:error, "no JSON found in response"}
    end
  end

  defp validate_and_build(%{"summary" => summary, "annotations" => annotations})
       when is_list(annotations) do
    parsed =
      Enum.map(annotations, fn ann ->
        %Annotation{
          file: ann["file"],
          start_line: ann["start_line"],
          end_line: ann["end_line"],
          comment: ann["comment"],
          severity: parse_severity(ann["severity"]),
          id: generate_id()
        }
      end)

    {:ok,
     %ReviewResult{
       summary: summary,
       annotations: parsed,
       reviewed_at: DateTime.utc_now()
     }}
  end

  defp validate_and_build(_), do: {:error, "invalid response: missing summary or annotations"}

  defp parse_severity("warning"), do: :warning
  defp parse_severity("issue"), do: :issue
  defp parse_severity(_), do: :info

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
