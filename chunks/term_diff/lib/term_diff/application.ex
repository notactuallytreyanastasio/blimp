defmodule TermDiff.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TermDiffWeb.Telemetry,
      TermDiff.Repo,
      {DNSCluster, query: Application.get_env(:term_diff, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TermDiff.PubSub},
      {TermDiff.Git.Watcher, repo_path: Application.get_env(:term_diff, :repo_path, File.cwd!())},
      TermDiffWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TermDiff.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TermDiffWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
