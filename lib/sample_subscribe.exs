defmodule SampleSubscribe do
  use GenServer
  require Logger

  def start_link(:persub, server, stream, group_name, buffer_size) do
    GenServer.start_link __MODULE__, {:persub, server, stream, group_name, buffer_size}
  end

  def init({:persub, server, stream, group_name, buffer_size}) do
    Extreme.start_persistent_subscription(server, self, %PersistentSubscriptionParams{stream: stream, group_name: group_name, buffer_size: buffer_size})
    {:ok, []}
  end

  def handle_call({:on_persistent_event, e}, _from, state) do
    Logger.debug "SampleSubscribe.handle_call :on_persistent_event, event_number: #{inspect e.event.event_number}, e: #{inspect e}"
    {:reply, {:ok, %Extreme.Messages.PersistentSubscriptionAckEvents{}}, state}
    # If a message is not successfully processed then a Nak can be sent.
    # {:reply, {:ok, %Extreme.Messages.PersistentSubscriptionNakEvents{ action: :Retry}}, state}
    # action can be one of :Unknown, :Park, :Retry, :Skip, or :Stop
  end
end
