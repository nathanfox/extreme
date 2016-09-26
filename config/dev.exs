use Mix.Config

config :logger, :console,
  level: :info,
  format: "$time [$level] $metadata$message\n",
  metadata: [:user_id]
