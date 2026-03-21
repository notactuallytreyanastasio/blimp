defmodule TermDiff.Commentary.Prompt do
  @moduledoc """
  Build the prompt and JSON schema sent to Claude for diff review.
  Schema is validated server-side by claude -p via --json-schema.
  """

  @review_schema Jason.encode!(%{
    "type" => "object",
    "required" => ["summary", "annotations"],
    "properties" => %{
      "summary" => %{"type" => "string"},
      "annotations" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["file", "start_line", "end_line", "comment", "severity"],
          "properties" => %{
            "file" => %{"type" => "string"},
            "start_line" => %{"type" => "integer"},
            "end_line" => %{"type" => "integer"},
            "comment" => %{"type" => "string"},
            "severity" => %{"type" => "string", "enum" => ["info", "warning", "issue"]}
          }
        }
      }
    }
  })

  @spec json_schema() :: String.t()
  def json_schema, do: @review_schema

  @spec build(String.t()) :: String.t()
  def build(raw_diff) do
    """
    Review the following diff. Provide:
    1. A brief summary of the overall changes (2-3 sentences).
    2. Per-file annotations for notable lines. Use NEW file line numbers.

    Respond ONLY with JSON in this exact structure:
    {
      "summary": "...",
      "annotations": [
        {
          "file": "path/to/file.ex",
          "start_line": 10,
          "end_line": 12,
          "comment": "...",
          "severity": "info|warning|issue"
        }
      ]
    }

    The diff:
    #{raw_diff}
    """
  end
end
