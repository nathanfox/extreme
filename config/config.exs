use Mix.Config

config :extreme, :event_store,
  genserver_timeout: 5000 # can use :infinity if debugging

import_config "#{Mix.env}.exs"
