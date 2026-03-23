defmodule TermDiff.Agent.ClaudeSettingsTest do
  use ExUnit.Case, async: true

  alias TermDiff.Agent.ClaudeSettings

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "claude_settings"])

  setup do
    File.mkdir_p!(@fixtures_dir)
    on_exit(fn -> File.rm_rf!(@fixtures_dir) end)
    :ok
  end

  describe "bypass_permissions?/1" do
    test "returns true when defaultMode is bypassPermissions" do
      path =
        write_fixture("bypass.json", %{
          "permissions" => %{
            "allow" => ["Bash", "Edit", "Write"],
            "defaultMode" => "bypassPermissions"
          }
        })

      assert ClaudeSettings.bypass_permissions?(path)
    end

    test "returns false when defaultMode is not bypassPermissions" do
      path =
        write_fixture("default.json", %{
          "permissions" => %{
            "allow" => ["Bash"],
            "defaultMode" => "default"
          }
        })

      refute ClaudeSettings.bypass_permissions?(path)
    end

    test "returns false when permissions key is missing" do
      path =
        write_fixture("no_perms.json", %{
          "hooks" => %{}
        })

      refute ClaudeSettings.bypass_permissions?(path)
    end

    test "returns false when defaultMode key is missing" do
      path =
        write_fixture("no_mode.json", %{
          "permissions" => %{
            "allow" => ["Bash"]
          }
        })

      refute ClaudeSettings.bypass_permissions?(path)
    end

    test "returns false when file does not exist" do
      refute ClaudeSettings.bypass_permissions?("/nonexistent/path/settings.json")
    end

    test "returns false when file is invalid JSON" do
      path = Path.join(@fixtures_dir, "bad.json")
      File.write!(path, "not json {{{")

      refute ClaudeSettings.bypass_permissions?(path)
    end
  end

  describe "bypass_permissions?/0 (project path)" do
    test "uses .claude/settings.json in project root" do
      # This just exercises the arity-0 fallback without error
      # The actual path resolution depends on runtime config
      result = ClaudeSettings.bypass_permissions?()
      assert is_boolean(result)
    end
  end

  defp write_fixture(name, data) do
    path = Path.join(@fixtures_dir, name)
    File.write!(path, Jason.encode!(data))
    path
  end
end
