defmodule TermDiff.Agent.ClaudeSettings do
  @moduledoc """
  Reads `.claude/settings.json` and exposes permission configuration.

  Used to determine whether YOLO mode should default to ON for new agent runs
  based on the project's `permissions.defaultMode` setting.
  """

  @settings_filename ".claude/settings.json"

  @doc """
  Returns `true` if the project's `.claude/settings.json` has
  `permissions.defaultMode` set to `"bypassPermissions"`.

  Uses the project root from application config (`:term_diff, :repo_path`)
  or falls back to `File.cwd!/0`.
  """
  @spec bypass_permissions?() :: boolean()
  def bypass_permissions? do
    project_root = Application.get_env(:term_diff, :repo_path, File.cwd!())
    path = Path.join(project_root, @settings_filename)
    bypass_permissions?(path)
  end

  @doc """
  Returns `true` if the given settings file path has
  `permissions.defaultMode` set to `"bypassPermissions"`.

  Returns `false` if the file doesn't exist, is malformed, or
  the key is missing/different.
  """
  @spec bypass_permissions?(String.t()) :: boolean()
  def bypass_permissions?(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, parsed} <- Jason.decode(contents),
         %{"permissions" => %{"defaultMode" => mode}} <- parsed do
      mode == "bypassPermissions"
    else
      _ -> false
    end
  end
end
