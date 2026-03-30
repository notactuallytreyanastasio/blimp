defmodule BlimpNew.MixProject do
  use Mix.Project

  @version "0.1.0"
  @scm_url "https://github.com/bobbby/blimp"

  def project do
    [
      app: :blimp_new,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      source_url: @scm_url,
      description:
        "Blimp web application generator — scaffold real-time Phoenix apps with actor integration",
      package: package(),
      elixirc_options: [warnings_as_errors: true]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :eex]
    ]
  end

  defp deps do
    []
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @scm_url}
    ]
  end
end
