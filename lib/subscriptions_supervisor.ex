defmodule Extreme.SubscriptionsSupervisor do
  use Supervisor
  require Logger

  def start_link(connection, opts \\ []) do
    Supervisor.start_link __MODULE__, connection, opts
  end

  def start_subscription(supervisor, subscriber, read_params) do
    Supervisor.start_child(supervisor, [subscriber, read_params])
  end
  def start_subscription(supervisor, subscriber, stream, resolve_link_tos) do
    Supervisor.start_child(supervisor, [subscriber, stream, resolve_link_tos])
  end
  def start_persistent_subscription(supervisor, subscriber, params = %PersistentSubscriptionParams{}) do
    Logger.debug "In Extreme.SubscriptionsSupervisor.start_persistent_subscription supervisor: #{inspect supervisor} subscriber: #{inspect subscriber} params: #{inspect params}"
    Supervisor.start_child(supervisor, [subscriber, params])
  end

  def init(connection) do
    children = [
      worker(Extreme.Subscription, [connection], restart: :temporary)
    ]
    supervise children, strategy: :simple_one_for_one
  end
end
