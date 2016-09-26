defmodule ExpectedVersion do
  use ExEnum
  row id: :any, value: -2
  row id: :noStream, value: -1
  row id: :emptyStream, value: -1
  row id: :streamExists, value: -4
  accessor :id
end
