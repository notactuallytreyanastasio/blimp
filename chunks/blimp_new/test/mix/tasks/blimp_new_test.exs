defmodule Mix.Tasks.Blimp.NewTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @test_dir System.tmp_dir!()

  setup do
    app_name = "test_app_#{:erlang.unique_integer([:positive])}"
    app_dir = Path.join(@test_dir, app_name)

    on_exit(fn ->
      File.rm_rf!(app_dir)
    end)

    %{app_name: app_name, app_dir: app_dir}
  end

  test "generates a new app", %{app_name: app_name} do
    in_tmp(fn ->
      output =
        capture_io(fn ->
          Mix.Tasks.Blimp.New.run([app_name])
        end)

      assert output =~ "creating mix.exs"
      assert output =~ "Your Blimp app is ready!"

      assert File.exists?(Path.join(app_name, "mix.exs"))
      assert File.exists?(Path.join(app_name, "lib/#{app_name}/application.ex"))
      assert File.exists?(Path.join(app_name, "config/config.exs"))
      assert File.exists?(Path.join(app_name, "Makefile"))
      assert File.exists?(Path.join(app_name, "deploy.sh"))

      # Verify module names are correct
      mix_content = File.read!(Path.join(app_name, "mix.exs"))
      expected_module = Macro.camelize(app_name)
      assert mix_content =~ "#{expected_module}.MixProject"
    end)
  end

  test "generates actor files with --actors", %{app_name: app_name} do
    in_tmp(fn ->
      capture_io(fn ->
        Mix.Tasks.Blimp.New.run([app_name, "--actors"])
      end)

      assert File.exists?(Path.join(app_name, "lib/#{app_name}/actors/supervisor.ex"))
      assert File.exists?(Path.join(app_name, "lib/#{app_name}/actors/registry.ex"))

      # Actor supervisor should reference PubSub
      sup_content = File.read!(Path.join(app_name, "lib/#{app_name}/actors/supervisor.ex"))
      assert sup_content =~ "DynamicSupervisor"
    end)
  end

  test "raises on invalid app name" do
    assert_raise Mix.Error, ~r/Invalid app name/, fn ->
      Mix.Tasks.Blimp.New.run(["MyApp"])
    end
  end

  test "raises with no arguments" do
    assert_raise Mix.Error, ~r/Expected APP_NAME/, fn ->
      Mix.Tasks.Blimp.New.run([])
    end
  end

  defp in_tmp(fun) do
    tmp = Path.join(System.tmp_dir!(), "blimp_new_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cd!(tmp, fun)
  after
    :ok
  end
end
