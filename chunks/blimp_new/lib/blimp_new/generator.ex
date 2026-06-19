defmodule BlimpNew.Generator do
  @moduledoc """
  Core generator logic for `mix blimp.new`.

  Validates app names, builds template assigns, and produces the list of files
  that make up a new Blimp web application. Each file is a `{relative_path, content}`
  tuple where content is generated from EEx templates.

  ## Architecture

  A generated Blimp app includes:

  - **Phoenix LiveView** with PubSub for real-time updates
  - **Ecto** with Postgres for persistence
  - **esbuild + Tailwind** asset pipeline
  - **Makefile** with dev/test/deploy targets
  - **deploy.sh** for Hetzner rsync deployment
  - (optional) **Actor supervision tree** for Blimp language actor integration

  ## Actor Integration Design

  When `--actors` is passed, the generator scaffolds a supervision tree that
  bridges Blimp language actors with Phoenix LiveView:

      App.Actors.Supervisor
      ├── App.Actors.Registry (named process registry)
      └── DynamicSupervisor (spawns actor processes)

  Each actor process holds state and communicates via `Phoenix.PubSub`,
  so LiveView processes can subscribe to actor state changes:

      # In a LiveView
      def mount(_params, _session, socket) do
        Phoenix.PubSub.subscribe(MyApp.PubSub, "actor:shop")
        {:ok, socket}
      end

      def handle_info({:actor_state_changed, state}, socket) do
        {:noreply, assign(socket, :shop_state, state)}
      end
  """

  @valid_name_regex ~r/^[a-z][a-z0-9_]*$/

  @doc """
  Validates that an app name is a valid Elixir/OTP application name.

  Must be lowercase, start with a letter, contain only `[a-z0-9_]`.
  """
  @spec validate_app_name(String.t()) :: :ok | {:error, String.t()}
  def validate_app_name(""), do: {:error, "app name cannot be empty"}

  def validate_app_name(name) do
    if Regex.match?(@valid_name_regex, name) do
      :ok
    else
      {:error, "app name must be lowercase, start with a letter, and contain only a-z, 0-9, _"}
    end
  end

  @doc """
  Builds template assigns from an app name and options.

  Returns a map with all variables needed by the EEx templates.
  """
  @spec build_assigns(String.t(), keyword()) :: map()
  def build_assigns(app_name, opts) do
    app_module = Macro.camelize(app_name)

    %{
      app_name: app_name,
      app_module: app_module,
      web_module: "#{app_module}Web",
      repo_module: "#{app_module}.Repo",
      endpoint_module: "#{app_module}Web.Endpoint",
      pubsub_module: "#{app_module}.PubSub",
      actors: Keyword.get(opts, :actors, false),
      secret_key_base: random_string(64),
      signing_salt: random_string(8),
      lv_signing_salt: random_string(8)
    }
  end

  @doc """
  Returns the list of `{path, content}` tuples for all files to generate.
  """
  @spec file_list(map()) :: [{String.t(), String.t()}]
  def file_list(assigns) do
    core_files(assigns) ++ actor_files(assigns)
  end

  # -- Private -----------------------------------------------------------------

  defp core_files(assigns) do
    app = assigns.app_name

    [
      {"mix.exs", render_mix_exs(assigns)},
      {"lib/#{app}/application.ex", render_application(assigns)},
      {"lib/#{app}/repo.ex", render_repo(assigns)},
      {"lib/#{app}/mailer.ex", render_mailer(assigns)},
      {"lib/#{app}_web/router.ex", render_router(assigns)},
      {"lib/#{app}_web/endpoint.ex", render_endpoint(assigns)},
      {"lib/#{app}_web/components/layouts.ex", render_layouts_module(assigns)},
      {"config/config.exs", render_config(assigns)},
      {"config/dev.exs", render_dev_config(assigns)},
      {"config/prod.exs", render_prod_config(assigns)},
      {"config/runtime.exs", render_runtime_config(assigns)},
      {"config/test.exs", render_test_config(assigns)},
      {"assets/js/app.js", render_app_js(assigns)},
      {"assets/css/app.css", render_app_css(assigns)},
      {"Makefile", render_makefile(assigns)},
      {"deploy.sh", render_deploy_sh(assigns)},
      {"test/test_helper.exs", render_test_helper(assigns)},
      {"test/#{app}_web/live/home_live_test.exs", render_home_live_test(assigns)},
      {"lib/#{app}_web/live/home_live.ex", render_home_live(assigns)},
      {".formatter.exs", render_formatter(assigns)},
      {".gitignore", render_gitignore(assigns)}
    ]
  end

  defp actor_files(%{actors: false}), do: []

  defp actor_files(%{actors: true} = assigns) do
    app = assigns.app_name

    [
      {"lib/#{app}/actors/supervisor.ex", render_actor_supervisor(assigns)},
      {"lib/#{app}/actors/registry.ex", render_actor_registry(assigns)}
    ]
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length) |> Base.url_encode64() |> binary_part(0, length)
  end

  # -- Template rendering helpers ----------------------------------------------

  defp eval_template(template, assigns) do
    EEx.eval_string(template, assigns: Map.to_list(assigns))
  end

  # -- Template renderers (inline EEx for portability) -------------------------

  defp render_mix_exs(a) do
    eval_template(
      ~S"""
      defmodule <%= @app_module %>.MixProject do
        use Mix.Project

        def project do
          [
            app: :<%= @app_name %>,
            version: "0.1.0",
            elixir: "~> 1.15",
            elixirc_paths: elixirc_paths(Mix.env()),
            start_permanent: Mix.env() == :prod,
            aliases: aliases(),
            deps: deps(),
            elixirc_options: [warnings_as_errors: true]
          ]
        end

        def application do
          [
            mod: {<%= @app_module %>.Application, []},
            extra_applications: [:logger, :runtime_tools]
          ]
        end

        defp elixirc_paths(:test), do: ["lib", "test/support"]
        defp elixirc_paths(_), do: ["lib"]

        defp deps do
          [
            {:phoenix, "~> 1.8"},
            {:phoenix_ecto, "~> 4.5"},
            {:ecto_sql, "~> 3.13"},
            {:postgrex, ">= 0.0.0"},
            {:phoenix_html, "~> 4.1"},
            {:phoenix_live_reload, "~> 1.2", only: :dev},
            {:phoenix_live_view, "~> 1.1"},
            {:phoenix_live_dashboard, "~> 0.8"},
            {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
            {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
            {:swoosh, "~> 1.16"},
            {:req, "~> 0.5"},
            {:telemetry_metrics, "~> 1.0"},
            {:telemetry_poller, "~> 1.0"},
            {:gettext, "~> 1.0"},
            {:jason, "~> 1.2"},
            {:dns_cluster, "~> 0.2"},
            {:bandit, "~> 1.5"},
            {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
          ]
        end

        defp aliases do
          [
            setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
            "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
            "ecto.reset": ["ecto.drop", "ecto.setup"],
            test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
            "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
            "assets.build": ["tailwind <%= @app_name %>", "esbuild <%= @app_name %>"],
            "assets.deploy": [
              "tailwind <%= @app_name %> --minify",
              "esbuild <%= @app_name %> --minify",
              "phx.digest"
            ]
          ]
        end
      end
      """,
      a
    )
  end

  defp render_application(a) do
    eval_template(
      ~S"""
      defmodule <%= @app_module %>.Application do
        @moduledoc false
        use Application

        @impl true
        def start(_type, _args) do
          children = [
            <%= @app_module %>Web.Telemetry,
            <%= @app_module %>.Repo,
            {DNSCluster, query: Application.get_env(:<%= @app_name %>, :dns_cluster_query) || :ignore},
            {Phoenix.PubSub, name: <%= @app_module %>.PubSub},<%= if @actors do %>
            <%= @app_module %>.Actors.Supervisor,<% end %>
            <%= @app_module %>Web.Endpoint
          ]

          opts = [strategy: :one_for_one, name: <%= @app_module %>.Supervisor]
          Supervisor.start_link(children, opts)
        end

        @impl true
        def config_change(changed, _new, removed) do
          <%= @app_module %>Web.Endpoint.config_change(changed, removed)
          :ok
        end
      end
      """,
      a
    )
  end

  defp render_repo(a) do
    eval_template(
      ~S"""
      defmodule <%= @app_module %>.Repo do
        use Ecto.Repo,
          otp_app: :<%= @app_name %>,
          adapter: Ecto.Adapters.Postgres
      end
      """,
      a
    )
  end

  defp render_mailer(a) do
    eval_template(
      ~S"""
      defmodule <%= @app_module %>.Mailer do
        use Swoosh.Mailer, otp_app: :<%= @app_name %>
      end
      """,
      a
    )
  end

  defp render_router(a) do
    eval_template(
      ~S"""
      defmodule <%= @app_module %>Web.Router do
        use <%= @app_module %>Web, :router

        pipeline :browser do
          plug :accepts, ["html"]
          plug :fetch_session
          plug :fetch_live_flash
          plug :put_root_layout, html: {<%= @app_module %>Web.Layouts, :root}
          plug :protect_from_forgery
          plug :put_secure_browser_headers
        end

        pipeline :api do
          plug :accepts, ["json"]
        end

        scope "/", <%= @app_module %>Web do
          pipe_through :browser

          live "/", HomeLive
        end
      end
      """,
      a
    )
  end

  defp render_endpoint(a) do
    eval_template(
      ~S"""
      defmodule <%= @app_module %>Web.Endpoint do
        use Phoenix.Endpoint, otp_app: :<%= @app_name %>

        @session_options [
          store: :cookie,
          key: "_<%= @app_name %>_key",
          signing_salt: "<%= @signing_salt %>",
          same_site: "Lax"
        ]

        socket "/live", Phoenix.LiveView.Socket,
          websocket: [connect_info: [session: @session_options]],
          longpoll: [connect_info: [session: @session_options]]

        plug Plug.Static,
          at: "/",
          from: :<%= @app_name %>,
          gzip: not code_reloading?

        if code_reloading? do
          socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
          plug Phoenix.LiveReloader
          plug Phoenix.CodeReloader
          plug Phoenix.Ecto.CheckRepoStatus, otp_app: :<%= @app_name %>
        end

        plug Plug.RequestId
        plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

        plug Plug.Parsers,
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Phoenix.json_library()

        plug Plug.MethodOverride
        plug Plug.Head
        plug Plug.Session, @session_options
        plug <%= @app_module %>Web.Router
      end
      """,
      a
    )
  end

  defp render_layouts_module(a) do
    eval_template(
      ~S"""
      defmodule <%= @app_module %>Web.Layouts do
        @moduledoc "Layout components for <%= @app_module %>Web."
        use <%= @app_module %>Web, :html
      end
      """,
      a
    )
  end

  defp render_config(a) do
    eval_template(
      ~S"""
      import Config

      config :<%= @app_name %>,
        ecto_repos: [<%= @app_module %>.Repo],
        generators: [timestamp_type: :utc_datetime]

      config :<%= @app_name %>, <%= @app_module %>Web.Endpoint,
        url: [host: "localhost"],
        adapter: Bandit.PhoenixAdapter,
        render_errors: [
          formats: [html: <%= @app_module %>Web.ErrorHTML, json: <%= @app_module %>Web.ErrorJSON],
          layout: false
        ],
        pubsub_server: <%= @app_module %>.PubSub,
        live_view: [signing_salt: "<%= @lv_signing_salt %>"]

      config :<%= @app_name %>, <%= @app_module %>.Mailer, adapter: Swoosh.Adapters.Local

      config :esbuild,
        version: "0.25.4",
        <%= @app_name %>: [
          args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
          cd: Path.expand("../assets", __DIR__),
          env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
        ]

      config :tailwind,
        version: "4.1.12",
        <%= @app_name %>: [
          args: ~w(--input=assets/css/app.css --output=priv/static/assets/css/app.css),
          cd: Path.expand("..", __DIR__)
        ]

      config :logger, :default_formatter,
        format: "$time $metadata[$level] $message\n",
        metadata: [:request_id]

      config :phoenix, :json_library, Jason

      import_config "#{config_env()}.exs"
      """,
      a
    )
  end

  defp render_dev_config(a) do
    eval_template(
      ~S"""
      import Config

      config :<%= @app_name %>, <%= @app_module %>.Repo,
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        database: "<%= @app_name %>_dev",
        stacktrace: true,
        show_sensitive_data_on_connection_error: true,
        pool_size: 10

      config :<%= @app_name %>, <%= @app_module %>Web.Endpoint,
        http: [ip: {127, 0, 0, 1}, port: 4000],
        check_origin: false,
        code_reloader: true,
        debug_errors: true,
        secret_key_base: "<%= @secret_key_base %>",
        watchers: [
          esbuild: {Esbuild, :install_and_run, [:<%= @app_name %>, ~w(--sourcemap=inline --watch)]},
          tailwind: {Tailwind, :install_and_run, [:<%= @app_name %>, ~w(--watch)]}
        ]

      config :<%= @app_name %>, <%= @app_module %>Web.Endpoint,
        live_reload: [
          patterns: [
            ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
            ~r"lib/<%= @app_name %>_web/(controllers|live|components)/.*(ex|heex)$"
          ]
        ]

      config :<%= @app_name %>, dev_routes: true
      config :logger, :default_handler, level: :debug
      config :phoenix, :stacktrace_depth, 20
      config :phoenix, :plug_init_mode, :runtime
      """,
      a
    )
  end

  defp render_prod_config(a) do
    eval_template(
      ~S"""
      import Config

      config :<%= @app_name %>, <%= @app_module %>Web.Endpoint,
        cache_static_manifest: "priv/static/cache_manifest.json"

      config :swoosh, api_client: Swoosh.ApiClient.Req
      config :swoosh, local: false
      config :logger, level: :info
      """,
      a
    )
  end

  defp render_runtime_config(a) do
    eval_template(
      ~S"""
      import Config

      if System.get_env("PHX_SERVER") do
        config :<%= @app_name %>, <%= @app_module %>Web.Endpoint, server: true
      end

      config :<%= @app_name %>, <%= @app_module %>Web.Endpoint,
        http: [port: String.to_integer(System.get_env("PORT", "4000"))]

      if config_env() == :prod do
        database_url =
          System.get_env("DATABASE_URL") ||
            raise "environment variable DATABASE_URL is missing."

        config :<%= @app_name %>, <%= @app_module %>.Repo,
          url: database_url,
          pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

        secret_key_base =
          System.get_env("SECRET_KEY_BASE") ||
            raise "environment variable SECRET_KEY_BASE is missing."

        host = System.get_env("PHX_HOST") || "example.com"

        config :<%= @app_name %>, <%= @app_module %>Web.Endpoint,
          url: [host: host, port: 443, scheme: "https"],
          http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
          secret_key_base: secret_key_base
      end
      """,
      a
    )
  end

  defp render_test_config(a) do
    eval_template(
      ~S"""
      import Config

      config :<%= @app_name %>, <%= @app_module %>.Repo,
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        database: "<%= @app_name %>_test#{System.get_env("MIX_TEST_PARTITION")}",
        pool: Ecto.Adapters.SQL.Sandbox,
        pool_size: System.schedulers_online() * 2

      config :<%= @app_name %>, <%= @app_module %>Web.Endpoint,
        http: [ip: {127, 0, 0, 1}, port: 4002],
        secret_key_base: "<%= @secret_key_base %>",
        server: false

      config :<%= @app_name %>, <%= @app_module %>.Mailer, adapter: Swoosh.Adapters.Test
      config :logger, level: :warning
      config :phoenix, :plug_init_mode, :runtime
      """,
      a
    )
  end

  defp render_app_js(_a) do
    """
    // Blimp app entrypoint
    import "phoenix_html"
    import {Socket} from "phoenix"
    import {LiveSocket} from "phoenix_live_view"
    import topbar from "../vendor/topbar"

    let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
    let liveSocket = new LiveSocket("/live", Socket, {
      longPollFallbackMs: 2500,
      params: {_csrf_token: csrfToken}
    })

    topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
    window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
    window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

    liveSocket.connect()
    window.liveSocket = liveSocket
    """
  end

  defp render_app_css(a) do
    eval_template(
      ~S"""
      @import "tailwindcss";
      /* <%= @app_module %> styles */
      """,
      a
    )
  end

  defp render_makefile(a) do
    eval_template(
      ~S"""
      # <%= @app_module %> — built with Blimp
      .PHONY: help server setup test deploy clean

      help: ## Show this help
      	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
      		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

      server: ## Start the dev server
      	mix phx.server

      setup: ## Install deps, create DB, build assets
      	mix setup

      test: ## Run tests
      	mix test

      deploy: ## Deploy to production
      	bash deploy.sh

      clean: ## Clean build artifacts
      	mix clean
      	rm -rf _build deps
      """,
      a
    )
  end

  defp render_deploy_sh(a) do
    eval_template(
      ~S"""
      #!/bin/bash
      # Deploy <%= @app_name %> to production
      set -e

      echo "Building release..."
      MIX_ENV=prod mix deps.get --only prod
      MIX_ENV=prod mix compile
      MIX_ENV=prod mix assets.deploy
      MIX_ENV=prod mix release --overwrite

      echo "Deploying..."
      DEPLOY_HOST="${DEPLOY_HOST:-root@your-server}"
      DEPLOY_DIR="${DEPLOY_DIR:-/srv/<%= @app_name %>}"

      rsync -avz --delete \
        _build/prod/rel/<%= @app_name %>/ \
        "$DEPLOY_HOST:$DEPLOY_DIR/"

      ssh "$DEPLOY_HOST" "cd $DEPLOY_DIR && bin/<%= @app_name %> restart || bin/<%= @app_name %> start"

      echo "Deployed to $DEPLOY_HOST:$DEPLOY_DIR"
      """,
      a
    )
  end

  defp render_test_helper(a) do
    eval_template(
      ~S"""
      ExUnit.start()
      Ecto.Adapters.SQL.Sandbox.mode(<%= @app_module %>.Repo, :manual)
      """,
      a
    )
  end

  defp render_home_live_test(a) do
    eval_template(
      ~S"""
      defmodule <%= @app_module %>Web.HomeLiveTest do
        use <%= @app_module %>Web.ConnCase

        import Phoenix.LiveViewTest

        test "renders home page", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/")
          assert html =~ "<%= @app_module %>"
        end
      end
      """,
      a
    )
  end

  defp render_home_live(a) do
    mod = a.app_module

    """
    defmodule #{mod}Web.HomeLive do
      use #{mod}Web, :live_view

      @impl true
      def mount(_params, _session, socket) do
        {:ok, assign(socket, :page_title, "#{mod}")}
      end

      @impl true
      def render(assigns) do
        ~H\"\"\"
        <div class="max-w-2xl mx-auto p-8">
          <h1 class="text-3xl font-bold">#{mod}</h1>
          <p class="mt-4 text-gray-600">Your Blimp app is running.</p>
        </div>
        \"\"\"
      end
    end
    """
  end

  defp render_formatter(_a) do
    """
    [
      import_deps: [:ecto, :ecto_sql, :phoenix],
      subdirectories: ["priv/*/migrations"],
      plugins: [Phoenix.LiveView.HTMLFormatter],
      inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}"]
    ]
    """
  end

  defp render_gitignore(_a) do
    """
    /_build/
    /deps/
    /priv/static/assets/
    /priv/static/cache_manifest.json
    *.ez
    .elixir_ls/
    erl_crash.dump
    """
  end

  defp render_actor_supervisor(a) do
    mod = a.app_module

    "defmodule #{mod}.Actors.Supervisor do\n" <>
      "  @moduledoc \"Supervises Blimp actor processes with PubSub integration.\"\n" <>
      "  use Supervisor\n\n" <>
      "  def start_link(opts) do\n" <>
      "    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)\n" <>
      "  end\n\n" <>
      "  @impl true\n" <>
      "  def init(_opts) do\n" <>
      "    children = [\n" <>
      "      {Registry, keys: :unique, name: #{mod}.Actors.Registry},\n" <>
      "      {DynamicSupervisor, name: #{mod}.Actors.DynSup, strategy: :one_for_one}\n" <>
      "    ]\n\n" <>
      "    Supervisor.init(children, strategy: :one_for_all)\n" <>
      "  end\n" <>
      "end\n"
  end

  defp render_actor_registry(a) do
    mod = a.app_module

    "defmodule #{mod}.Actors.Registry do\n" <>
      "  @moduledoc \"Named process registry for Blimp actors.\"\n" <>
      "  # Started by Actors.Supervisor as:\n" <>
      "  #   {Registry, keys: :unique, name: #{mod}.Actors.Registry}\n" <>
      "end\n"
  end
end
