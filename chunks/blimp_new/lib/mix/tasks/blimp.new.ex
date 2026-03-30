defmodule Mix.Tasks.Blimp.New do
  @shortdoc "Creates a new Blimp web application"

  @moduledoc """
  Creates a new Blimp web application.

      $ mix blimp.new my_app
      $ mix blimp.new my_app --actors

  ## Options

    * `--actors` - Include Blimp actor supervision tree for
      bridging Blimp language actors with Phoenix LiveView via PubSub

  ## What gets generated

  A complete Phoenix LiveView application with:

    * Ecto + Postgres for persistence
    * Phoenix PubSub for real-time
    * esbuild + Tailwind asset pipeline
    * Makefile with dev/test/deploy targets
    * deploy.sh for rsync-based deployment
    * (optional) Actor supervision tree with Registry + DynamicSupervisor

  ## Zero to deployed

      $ mix blimp.new my_shop
      $ cd my_shop
      $ make setup
      $ make server        # dev at localhost:4000
      $ make test           # run tests
      $ make deploy         # deploy to production
  """

  use Mix.Task

  alias BlimpNew.Generator

  @impl Mix.Task
  def run(args) do
    {opts, argv, _} = OptionParser.parse(args, strict: [actors: :boolean])

    case argv do
      [app_name] ->
        generate(app_name, opts)

      [] ->
        Mix.raise("Expected APP_NAME. Usage: mix blimp.new my_app [--actors]")

      _ ->
        Mix.raise("Expected a single APP_NAME. Usage: mix blimp.new my_app [--actors]")
    end
  end

  defp generate(app_name, opts) do
    case Generator.validate_app_name(app_name) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.raise("Invalid app name #{inspect(app_name)}: #{reason}")
    end

    assigns = Generator.build_assigns(app_name, opts)
    files = Generator.file_list(assigns)
    target_dir = Path.join(File.cwd!(), app_name)

    if File.dir?(target_dir) do
      Mix.raise("Directory #{target_dir} already exists")
    end

    File.mkdir_p!(target_dir)

    for {path, content} <- files do
      full_path = Path.join(target_dir, path)
      full_path |> Path.dirname() |> File.mkdir_p!()
      File.write!(full_path, content)
      Mix.shell().info("  creating #{path}")
    end

    Mix.shell().info("""

    Your Blimp app is ready!

        cd #{app_name}
        make setup
        make server

    Then visit http://localhost:4000
    """)
  end
end
