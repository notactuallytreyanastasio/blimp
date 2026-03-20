defmodule TermDiff.Commentary.Prompt do
  @moduledoc """
  Build the prompt sent to Claude for diff review.

  This is a placeholder -- the real prompt will be written by hand.
  The key contract: it must instruct Claude to return JSON with
  "summary" and "annotations" keys.
  """

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
