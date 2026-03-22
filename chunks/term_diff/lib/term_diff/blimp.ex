defmodule TermDiff.Blimp do
  @moduledoc """
  Interface to the Blimp compiler. Shells out to the blimp binary
  and parses introspection JSON for the REPL sidebar.
  """

  @project_root Path.expand("../../../..", __DIR__)
  @blimp_binary Path.join(@project_root, "chunks/lang/zig-out/bin/blimp")

  @doc """
  Run blimp --introspect on a .blimp file and return parsed JSON.
  Returns {:ok, map} or {:error, reason}.
  """
  def introspect(file_path) do
    case System.cmd(@blimp_binary, [file_path, "--introspect"], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "Failed to parse introspection JSON: #{output}"}
        end

      {output, _code} ->
        {:error, String.trim(output)}
    end
  end

  @doc """
  Run blimp on a .blimp file for type checking only.
  Returns {:ok, ast_output} or {:error, errors}.
  """
  def check(file_path) do
    case System.cmd(@blimp_binary, [file_path], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc """
  List all .blimp example files.
  """
  def example_files do
    Path.join(@project_root, "chunks/lang/examples")
    |> Path.join("*.blimp")
    |> Path.wildcard()
    |> Enum.sort()
  end

  @doc """
  Read a .blimp file's source.
  """
  def read_source(file_path) do
    case File.read(file_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{file_path}: #{reason}"}
    end
  end
end
