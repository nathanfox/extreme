defmodule Extreme.Request do
  alias Extreme.Tools
  require Logger

  def prepare(:ping=cmd) do
    correlation_id = Tools.gen_uuid
    res = <<Extreme.MessageResolver.encode_cmd(cmd), 0>> <> correlation_id
    size = byte_size(res)
    <<size::32-unsigned-little-integer>> <> res
  end
  def prepare(:heartbeat_response=cmd, correlation_id) do
    res = <<Extreme.MessageResolver.encode_cmd(cmd), 0>> <> correlation_id
    size = byte_size(res)
    <<size::32-unsigned-little-integer>> <> res
  end
  def prepare(protobuf_msg, credentials, correlation_id \\ nil) do
    cmd = protobuf_msg.__struct__
    data = protobuf_msg.__struct__.encode protobuf_msg
    if correlation_id == nil, do: correlation_id = Tools.gen_uuid
    message = to_binary(cmd, correlation_id, {credentials.user, credentials.pass}, data)

    {message, correlation_id}
  end

  defp to_binary(cmd, correlation_id, {login, password}, data) do
    login_len = byte_size(login)
    pass_len = byte_size(password)
    res = <<Extreme.MessageResolver.encode_cmd(cmd), 1>> <>
          correlation_id <>
          <<login_len::size(8)>>
    res = res <> login <> <<pass_len::size(8)>> <> password <> data
    size = byte_size(res)
    <<size::32-unsigned-little-integer>> <> res
  end
end
