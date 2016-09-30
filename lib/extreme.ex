defmodule Extreme do
  use GenServer
  alias Extreme.Request
  require Logger
  alias Extreme.Response
  alias Extreme.Messages, as: ExMsg

  @timeout Application.get_env(:extreme, :event_store)[:genserver_timeout]

  ## Client API

  @doc """
  Starts connection to EventStore using `connection_settings` and optional `opts`.
  """
  def start_link(connection_settings, opts \\[]) do
    GenServer.start_link __MODULE__, connection_settings, opts
  end

  @doc """
  Executes protobuf `message` against `server`. Returns:

  - {:ok, protobuf_message} on success .
  - {:error, :not_authenticated} on wrong credentials.
  - {:error, error_reason, protobuf_message} on failure.
  """
  def execute(server, message) do
    GenServer.call server, {:execute, message}, @timeout
  end


  @doc """
  Reads events specified in `read_events`, sends them to `subscriber`
  and leaves `subscriber` subscribed per `subscribe` message.

  `subscriber` is process that will keep receiving {:on_event, event} messages.
  `read_events` :: Extreme.Messages.ReadStreamEvents
  `subscribe` :: Extreme.Messages.SubscribeToStream

  Returns {:ok, subscription} when subscription is success.
  If `stream` is hard deleted `subscriber` will receive message {:extreme, :error, :stream_hard_deleted, stream}
  If `stream` is soft deleted `subscriber` will receive message {:extreme, :warn, :stream_soft_deleted, stream}.

  In case of soft deleted stream, new event will recreate stream and it will be sent to `subscriber` as described above
  Hard deleted streams can't be recreated so suggestion is not to handle this message but rather crash when it happens
  """
  def read_and_stay_subscribed(server, subscriber, stream, from_event_number \\ 0, per_page \\ 4096, resolve_link_tos \\ true, require_master \\ false) do
    GenServer.call server, {:read_and_stay_subscribed, subscriber, {stream, from_event_number, per_page, resolve_link_tos, require_master}}, @timeout
  end

  @doc """
  Subscribe `subscriber` to `stream` using `server`.

  `subscriber` is process that will keep receiving {:on_event, event} messages.

  Returns {:ok, subscription} when subscription is success.

  NOTE: If `stream` is hard deleted, `subscriber` will NOT receive any message!
  """
  def subscribe_to(server, subscriber, stream, resolve_link_tos \\ true) do
    GenServer.call server, {:subscribe_to, subscriber, stream, resolve_link_tos}, @timeout
  end

  def start_persistent_subscription(server, subscriber, params = %PersistentSubscriptionParams{}) do
    GenServer.call server, {:start_persistent_subscription, subscriber, params}, @timeout
  end

  def send_persistent_subscription_ack(server, correlation_id, ack) do
    GenServer.cast server, {:persistent_subscription_ack, correlation_id, ack}
  end

  ## Server Callbacks

  @subscriptions_sup Extreme.SubscriptionsSupervisor

  def init(connection_settings) do
    user = Keyword.fetch! connection_settings, :username
    pass = Keyword.fetch! connection_settings, :password
    GenServer.cast self, {:connect, connection_settings, 1}
    {:ok, sup} = Extreme.SubscriptionsSupervisor.start_link self
    {:ok, %{socket: nil, pending_responses: %{}, subscriptions: %{}, subscriptions_sup: sup, credentials: %{user: user, pass: pass}, received_data: <<>>, should_receive: nil}}
  end

  def handle_cast({:persistent_subscription_ack, ack, correlation_id}, state) do
    {message, _correlation_id} = Request.prepare ack, state.credentials, correlation_id
    :ok = :gen_tcp.send state.socket, message
    Logger.debug "sent ack msg, ack: #{inspect ack} correlation_id: #{inspect correlation_id} message: #{inspect message}"
    {:noreply, state}
  end

  def handle_cast({:connect, connection_settings, attempt}, state) do
    db_type = Keyword.get(connection_settings, :db_type, :node)
    |> cast_to_atom
    case connect db_type, connection_settings, attempt do
      {:ok, socket} -> {:noreply, %{state|socket: socket}}
      error         -> {:stop, error, state}
    end
  end

  defp connect(:cluster, connection_settings, attempt) do
    {:ok, host, port} = Extreme.ClusterConnection.get_node connection_settings
    connect(host, port, connection_settings, attempt)
  end
  defp connect(:node, connection_settings, attempt) do
    host = Keyword.fetch! connection_settings, :host
    port = Keyword.fetch! connection_settings, :port
    connect(host, port, connection_settings, attempt)
  end
  defp connect(:cluster_dns, connection_settings, attempt) do
    {:ok, host, port} = Extreme.ClusterConnection.get_node(:cluster_dns, connection_settings)
    connect(host, port, connection_settings, attempt)
  end
  defp connect(host, port, connection_settings, attempt) do
    Logger.info "Connecting Extreme to #{host}:#{port}"
    opts = [:binary, active: :once]
    case :gen_tcp.connect(String.to_char_list(host), port, opts) do
      {:ok, socket} ->
        Logger.info "Successfuly connected to EventStore @ #{host}:#{port}"
        :timer.send_after 1_000, :send_ping
        {:ok, socket}
      _             ->
        max_attempts = Keyword.get connection_settings, :max_attempts, :infinity
        reconnect = case max_attempts do
          :infinity -> true
          max when attempt <= max -> true
          _ -> false
        end
        if reconnect do
          reconnect_delay = Keyword.get connection_settings, :reconnect_delay, 1_000
          Logger.warn "Error connecting to EventStore @ #{host}:#{port}. Will retry in #{reconnect_delay} ms."
          :timer.sleep reconnect_delay
          db_type = Keyword.get(connection_settings, :db_type, :node)
          |> cast_to_atom
          connect db_type, connection_settings, attempt + 1
        else
          {:error, :max_attempt_exceeded}
        end
    end
  end

  def handle_call({:execute, protobuf_msg}, from, state) do
    {message, correlation_id} = Request.prepare protobuf_msg, state.credentials
    Logger.debug "Will execute #{inspect protobuf_msg}"
    :ok = :gen_tcp.send state.socket, message
    state = put_in state.pending_responses, Map.put(state.pending_responses, correlation_id, from)
    {:noreply, state}
  end
  def handle_call({:start_persistent_subscription, subscriber, params}, _from, state) do
    Logger.debug "Extreme.handle_call :start_persistent_subscription: #{inspect subscriber} params: #{inspect params} state: #{inspect state}"
    {:ok, subscription} = Extreme.SubscriptionsSupervisor.start_persistent_subscription(state.subscriptions_sup, subscriber, params)

    Logger.debug "Extreme.handle_call :start_persistent_subscription subscription: #{inspect subscription}"
    {:reply, {:ok, subscription}, state}
  end
  def handle_call({:read_and_stay_subscribed, subscriber, params}, _from, state) do
    {:ok, subscription} = Extreme.SubscriptionsSupervisor.start_subscription state.subscriptions_sup, subscriber, params
    Logger.debug "Subscription is: #{inspect subscription}"
    {:reply, {:ok, subscription}, state}
  end
  def handle_call({:subscribe_to, subscriber, stream, resolve_link_tos}, _from, state) do
    {:ok, subscription} = Extreme.SubscriptionsSupervisor.start_subscription state.subscriptions_sup, subscriber, stream, resolve_link_tos
    Logger.debug "Extreme.handle_call :subscribe_to subscription: #{inspect subscription}"
    {:reply, {:ok, subscription}, state}
  end
  def handle_call({:subscribe, subscriber, msg}, from, state) do
    Logger.debug "Extreme.handle_call :subscribe Subscribing #{inspect subscriber} with: #{inspect msg}"
    {message, correlation_id} = Request.prepare msg, state.credentials
    Logger.debug "Extreme.handle_call :subscribe Subscribe state before: #{inspect state}"
    :ok = :gen_tcp.send state.socket, message
    state = put_in state.pending_responses, Map.put(state.pending_responses, correlation_id, from)
    state = put_in state.subscriptions, Map.put(state.subscriptions, correlation_id, subscriber)
    Logger.debug "Extreme.handle_call :subscribe Subscribe state after: #{inspect state}"
    {:noreply, state}
  end
  def handle_call({:persistent_subscription, subscriber, msg}, from, state) do
    Logger.debug "Extreme.handle_call :persistent_subscription subscriber: #{inspect subscriber} with: #{inspect msg}"
    {message, correlation_id} = Request.prepare msg, state.credentials
    Logger.debug "Extreme.handle_call :persistent_subscription Request.prepare return: message: #{inspect message} correlation_id: #{inspect correlation_id}"
    :ok = :gen_tcp.send state.socket, message
    state = put_in state.pending_responses, Map.put(state.pending_responses, correlation_id, from)
    state = put_in state.subscriptions, Map.put(state.subscriptions, correlation_id, subscriber)
    {:noreply, state}
  end

  def handle_info(:send_ping, state) do
    message = Request.prepare :ping
    :ok = :gen_tcp.send state.socket, message
    {:noreply, state}
  end
  def handle_info({:tcp, socket, pkg}, state) do
    :inet.setopts(socket, active: :once) # Allow the socket to send us the next message
    state = process_package pkg, state
    {:noreply, state}
  end
  def handle_info({:tcp_closed, _port}, state), do: {:stop, :tcp_closed, state}


  # This package carries message from it's start. Process it and return new `state`
  defp process_package(<<message_length :: 32-unsigned-little-integer, content :: binary>>, %{socket: _socket, received_data: <<>>} = state) do
    #Logger.debug "Processing package with message_length of: #{message_length}"
    slice_content(message_length, content)
    |> process_content(state)
  end
  # Process package for unfinished message. Process it and return new `state`
  defp process_package(pkg, %{socket: _socket} = state) do
    Logger.debug "Processing next package. We need #{state.should_receive} bytes and we have collected #{byte_size(state.received_data)} so far and we have #{byte_size(pkg)} more"
    slice_content(state.should_receive, state.received_data <> pkg)
    |> process_content(state)
  end

  defp slice_content(message_length, content) do
    if byte_size(content) < message_length do
      Logger.debug "We have unfinished message of length #{message_length}(#{byte_size(content)}): #{inspect content}"
      {:unfinished_message, message_length, content}
    else
      case content do
        <<message :: binary - size(message_length), next_message :: binary>> -> {message, next_message}
        <<message :: binary - size(message_length)>>                         -> {message, <<>>}
      end
    end
  end

  defp process_content({:unfinished_message, expected_message_length, data}, state) do
    %{state|should_receive: expected_message_length, received_data: data}
  end
  defp process_content({message, <<>>}, state) do
  #Logger.debug "Processing single message: #{inspect message} and we have already received: #{inspect state.received_data}"
    state = process_message(message, state)
    #Logger.debug "After processing content state is #{inspect state}"
    %{state|should_receive: nil, received_data: <<>>}
  end
  defp process_content({message, rest}, state) do
  Logger.debug "Processing message: #{inspect message}"
  Logger.debug "But we have something else in package: #{inspect rest}"
    state = process_message message, %{state|should_receive: nil, received_data: <<>>}
    process_package rest, state
  end

  defp process_message(message, state) do
    #"Let's finally process whole message: #{inspect message}"
    if String.slice(message, 0, 1) != <<4>>, do: Logger.debug "Extreme.process_message: message: #{inspect message} parsed message: #{inspect Response.parse(message)} state: #{inspect state}"
    Response.parse(message)
    |> respond(state)
  end

  defp respond({:pong, _correlation_id}, state) do
    #Logger.debug "#{inspect self} got :pong"
    :timer.send_after 1_000, :send_ping
    state
  end
  defp respond({:heartbeat_request, correlation_id}, state) do
    Logger.debug "#{inspect self} Tick-Tack"
    message = Request.prepare :heartbeat_response, correlation_id
    :ok = :gen_tcp.send state.socket, message
    %{state|pending_responses: state.pending_responses}
  end
  defp respond({:error, :not_authenticated, correlation_id}, state) do
    {:error, :not_authenticated}
    |> respond_with(correlation_id, state)
  end
  defp respond({_auth, correlation_id, response}, state) do
    Logger.debug "Extreme.respond correlation_id: #{inspect correlation_id} state: #{inspect state}"
    response
    |> respond_with(correlation_id, state)
  end

  defp respond_with(response, correlation_id, state) do
    Logger.debug "Responding with response: #{inspect response}"
    case Map.get(state.pending_responses, correlation_id) do
      nil ->
        respond_to_subscription(response, correlation_id, state.subscriptions)
        state
      from ->
        :ok = GenServer.reply from, Response.reply(response)
        pending_responses = Map.delete state.pending_responses, correlation_id
        %{state|pending_responses: pending_responses}
    end
  end

  defp respond_to_subscription(response, correlation_id, subscriptions) do
    Logger.debug "Extreme.respond_to_subscription response: #{inspect response} correlation_id: #{inspect correlation_id} subscriptions: #{inspect subscriptions}"
    case Map.get(subscriptions, correlation_id) do
      nil ->
        Logger.error "Can't find correlation_id #{inspect correlation_id} for response #{inspect response}"
        :ok
      subscription ->
        #Logger.debug "Extreme.respond_to_subscription, subscription: #{inspect subscription} #{inspect Response.reply(response)}"
        case Response.reply(response) do
          {:ok, %ExMsg.PersistentSubscriptionStreamEventAppeared{}} = reply ->
            Logger.debug "case %ExMsg.PersistentSubscriptionStreamEventAppeared{} = reply, reply: #{inspect reply}"
            GenServer.cast subscription, Tuple.append(reply, correlation_id)
          reply ->
            GenServer.cast subscription, reply
        end
    end
  end

  @doc """
  Cast the provided value to an atom if appropriate.
  If the provided value is a string, convert it to an atom.
  """
  def cast_to_atom(value) when is_binary(value),
    do: String.to_atom(value)

  @doc """
  Cast the provided value to an atom if appropriate.
  If the provided value is not a string, return it as-is.
  """
  def cast_to_atom(value) when not is_binary(value),
    do: value
end
