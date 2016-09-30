defmodule PersistentSubscriptionParams do
  defstruct stream: "", group_name: "", buffer_size: 10
end

defmodule Extreme.Subscription do
  use GenServer
  require Logger
  alias Extreme.Messages, as: ExMsg

  @timeout Application.get_env(:extreme, :event_store)[:genserver_timeout]

  def start_link(connection, subscriber, params = %PersistentSubscriptionParams{}) do
    Logger.debug "Subscription.start_link connection: #{inspect connection}"
    GenServer.start_link __MODULE__, {connection, subscriber, params}
  end
  def start_link(connection, subscriber, read_params) do
    GenServer.start_link __MODULE__, {connection, subscriber, read_params}
  end
  def start_link(connection, subscriber, stream, resolve_link_tos) do
    GenServer.start_link __MODULE__, {connection, subscriber, stream, resolve_link_tos}
  end

  def init({connection, subscriber, {stream, from_event_number, per_page, resolve_link_tos, require_master}}) do
    read_params = %{stream: stream, from_event_number: from_event_number, per_page: per_page,
      resolve_link_tos: resolve_link_tos, require_master: require_master}
    GenServer.cast self, :read_and_stay_subscribed
    {:ok, %{subscriber: subscriber, connection: connection, read_params: read_params, status: :initialized, buffered_messages: [], read_until: -1, subscription_id: ""}}
  end
  def init({connection, subscriber, stream, resolve_link_tos}) do
    read_params = %{stream: stream, resolve_link_tos: resolve_link_tos}
    GenServer.cast self, :subscribe
    {:ok, %{subscriber: subscriber, connection: connection, read_params: read_params, status: :initialized, buffered_messages: [], read_until: -1, subscription_id: ""}}
  end
  def init({connection, subscriber, params = %PersistentSubscriptionParams{}}) do
    Logger.debug "Persistent subscription init self: #{inspect self} connection: #{inspect connection}"
    GenServer.cast self, :connect_to_persistent_subscription
    {:ok, %{subscriber: subscriber, connection: connection, params: params, status: :initialized, buffered_messages: [], read_until: -1, subscription_id: ""}}
  end

  def handle_cast({:ok, %ExMsg.PersistentSubscriptionStreamEventAppeared{}=e, correlation_id = correlation_id}, state) do
    Logger.debug "Subscription.handle_cast persistent event :ok, e: #{inspect e} correlation_id: #{inspect correlation_id} state: #{inspect state}"
    {:ok, ack} = GenServer.call state.subscriber, {:on_persistent_event, e.event}, @timeout
    ack = %{ack | subscription_id: state.subscription_id, processed_event_ids: [e.event.event.event_id]}
    GenServer.cast state.connection, { :persistent_subscription_ack, ack, correlation_id }
    {:noreply, state}
  end

  def handle_cast(:connect_to_persistent_subscription, state) do
    {:ok, subscription_confirmation} = GenServer.call state.connection, {:persistent_subscription, self, connect_to_persistent_subscription(state.params)}
    Logger.debug "Subscription.handle_cast :connect_to_persistent_subscription, Successfully subscribed to stream #{inspect subscription_confirmation} self: #{inspect self} state: #{inspect state}"
    #GenServer.cast self, :read_events
    {:noreply, %{state | status: :subscribed, subscription_id: subscription_confirmation.subscription_id}}
  end
  def handle_cast(:read_and_stay_subscribed, state) do
    {:ok, subscription_confirmation} = GenServer.call state.connection, {:subscribe, self, subscribe(state.read_params)}
    Logger.info "Subscription.handle_cast :read_and_stay_subscribed, Successfully subscribed to stream #{inspect subscription_confirmation}"
    GenServer.cast self, :read_events
    read_until = subscription_confirmation.last_event_number + 1
    {:noreply, %{state | read_until: read_until, status: :reading_events}}
  end
  def handle_cast(:subscribe, state) do
    {:ok, subscription_confirmation} = GenServer.call state.connection, {:subscribe, self, subscribe(state.read_params)}
    Logger.info "Subscription.handle_cast :subscribe, Successfully subscribed to stream #{inspect subscription_confirmation}"
    {:noreply, %{state | status: :subscribed}}
  end
  def handle_cast(:read_events, %{read_params: %{from_event_number: from}, read_until: from}=state) do
    Logger.debug "Subscription.handle_cast :read_events read_params from until, state: #{inspect state}"
    GenServer.cast self, :push_buffered_messages
    {:noreply, %{state|status: :pushing_buffered}}
  end
  def handle_cast(:read_events, state) do
    Logger.debug "Subscription.handle_cast :read_events, state: #{inspect state}"
    {read_events, keep_reading} = read_events(state.read_params, state.read_until)
    state = case keep_reading do
      true  -> state
      false -> %{state|status: :pushing_buffered}
    end
    state = Extreme.execute(state.connection, read_events)
            |> process_response(state)
    {:noreply, state}
  end
  def handle_cast(:push_buffered_messages, state) do
    Logger.debug "Subscription.handle_cast :push_buffered_messages, state: #{inspect state}"
    Enum.each state.buffered_messages, fn e -> send state.subscriber, {:on_event, e} end
    {:noreply, %{state|status: :subscribed, buffered_messages: []}}
  end
  def handle_cast({:ok, %Extreme.Messages.StreamEventAppeared{}=e}, %{status: :subscribed}=state) do
    Logger.debug "Subscription.handle_cast :ok status :subscribed, e: #{inspect e} state: #{inspect state}"
    send state.subscriber, {:on_event, e.event}
    {:noreply, state}
  end
  def handle_cast({:ok, %Extreme.Messages.StreamEventAppeared{}=e}, state) do
    Logger.debug "Subscription.handle_cast :ok, e: #{inspect e} state: #{inspect state}"
    buffered_messages = state.buffered_messages
                        |> List.insert_at(-1, e.event)
    {:noreply, %{state|buffered_messages: buffered_messages}}
  end

  def process_response({:ok, %ExMsg.ReadStreamEventsCompleted{}=response}, state) do
    Logger.info "Subscription.process_response :ok, Last read event: #{inspect response.next_event_number - 1}"
    push_events {:ok, response}, state.subscriber
    send_next_request response, state
  end
  def process_response({:error, :StreamDeleted, %ExMsg.ReadStreamEventsCompleted{}=response}, state) do
    Logger.error "Subscription.process_response :error :StreamDeleted, Stream is HARD deleted"
    push_events {:extreme, :error, :stream_hard_deleted, state.read_params.stream}, state.subscriber
    send_next_request response, state
  end
  def process_response({:error, :NoStream, %ExMsg.ReadStreamEventsCompleted{}=response}, state) do
    Logger.warn "Subscription.process_response :error :NoStream, Stream doesn't exist yet"
    push_events {:extreme, :warn, :no_stream, state.read_params.stream}, state.subscriber
    send_next_request response, state
  end

  defp push_events({:ok, %ExMsg.ReadStreamEventsCompleted{}=response}, subscriber) do
    Enum.each response.events, fn e -> send subscriber, {:on_event, e} end
  end
  defp push_events({:extreme, _, _, _}=msg, subscriber), do: send(subscriber, msg)

  defp send_next_request(_, %{status: :pushing_buffered}=state) do
    GenServer.cast self, :push_buffered_messages
    state
  end
  defp send_next_request(%{next_event_number: next_event_number}, state) do
    GenServer.cast self, :read_events
    %{state|read_params: %{state.read_params|from_event_number: next_event_number}}
  end

  defp read_events(%{from_event_number: from, per_page: per_page}=params, read_until) when from + per_page < read_until do
    result = ExMsg.ReadStreamEvents.new(
      event_stream_id: params.stream,
      from_event_number: from,
      max_count: per_page,
      resolve_link_tos: params.resolve_link_tos,
      require_master: params.require_master
    )
    {result, true}
  end
  defp read_events(params, read_until) do
    result = ExMsg.ReadStreamEvents.new(
      event_stream_id: params.stream,
      from_event_number: params.from_event_number,
      max_count: read_until - params.from_event_number,
      resolve_link_tos: params.resolve_link_tos,
      require_master: params.require_master
    )
    {result, false}
  end

  defp subscribe(params) do
    ExMsg.SubscribeToStream.new(
      event_stream_id: params.stream,
      resolve_link_tos: params.resolve_link_tos
    )
  end

  defp connect_to_persistent_subscription(params) do
    ExMsg.ConnectToPersistentSubscription.new(
      subscription_id: params.group_name,
      event_stream_id: params.stream,
      allowed_in_flight_messages: params.buffer_size
    )
  end
end
