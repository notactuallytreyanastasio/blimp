defmodule TermDiff.Diff.Language do
  @moduledoc """
  Maps file paths to highlight.js language identifiers.
  """

  @extension_map %{
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".eex" => "xml",
    ".heex" => "xml",
    ".leex" => "xml",
    ".zig" => "zig",
    ".js" => "javascript",
    ".jsx" => "javascript",
    ".mjs" => "javascript",
    ".ts" => "typescript",
    ".tsx" => "typescript",
    ".c" => "c",
    ".h" => "c",
    ".cpp" => "cpp",
    ".hpp" => "cpp",
    ".cc" => "cpp",
    ".rs" => "rust",
    ".go" => "go",
    ".java" => "java",
    ".kt" => "kotlin",
    ".swift" => "swift",
    ".py" => "python",
    ".rb" => "ruby",
    ".sh" => "bash",
    ".bash" => "bash",
    ".zsh" => "bash",
    ".lua" => "lua",
    ".html" => "xml",
    ".htm" => "xml",
    ".xml" => "xml",
    ".svg" => "xml",
    ".css" => "css",
    ".scss" => "scss",
    ".less" => "less",
    ".json" => "json",
    ".yaml" => "yaml",
    ".yml" => "yaml",
    ".toml" => "ini",
    ".md" => "markdown",
    ".sql" => "sql",
    ".graphql" => "graphql",
    ".gql" => "graphql",
    ".r" => "r",
    ".R" => "r",
    ".erl" => "erlang",
    ".hrl" => "erlang",
    ".blimp" => "elixir"
  }

  @filename_map %{
    "Makefile" => "makefile",
    "Dockerfile" => "dockerfile",
    "Vagrantfile" => "ruby",
    "Gemfile" => "ruby",
    "Rakefile" => "ruby"
  }

  @spec detect(String.t()) :: String.t() | nil
  def detect(""), do: nil

  def detect(path) do
    filename = Path.basename(path)

    Map.get(@filename_map, filename) || Map.get(@extension_map, Path.extname(path))
  end
end
