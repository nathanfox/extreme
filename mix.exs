defmodule Extreme.Mixfile do
  use Mix.Project

  def project do
    [app: :extreme,
     version: "0.5.1",
     elixir: ">= 1.0.0 and <= 1.4.0",
     source_url: "https://github.com/exponentially/extreme",
     description: """
     Elixir TCP adapter for EventStore.
     """,
     package: package,
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [
      applications: [:logger, :ex_enum,
        :exprotobuf, :uuid, :gpb, :httpoison, :poison]
    ]
  end

  defp deps do
    [
      {:httpoison, "~> 0.8.3"},
      {:poison, "~> 2.2"},
      {:exprotobuf, "~> 0.10.2"},
      {:uuid, "~> 1.0" },
      {:ex_doc, ">= 0.11.4", only: [:test]},
      {:earmark, ">= 0.0.0", only: [:test]},
      {:ex_enum, github: "kenta-aktsk/ex_enum"}
    ]
  end

  defp package do
    [
      files: ["lib", "include", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["Milan Burmaja", "Milan Jaric"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/exponentially/extreme"}
    ]
  end
end
