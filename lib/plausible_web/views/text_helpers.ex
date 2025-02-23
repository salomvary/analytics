defmodule PlausibleWeb.TextHelpers do
  @moduledoc false

  @spec pretty_join([String.t()]) :: String.t()

  @doc """
  Turns a list of strings into a string and replaces the last comma
  with the word "and".

  ### Examples:

      iex> ["one"] |> PlausibleWeb.TextHelpers.pretty_join()
      "one"

      iex> ["one", "two"] |> PlausibleWeb.TextHelpers.pretty_join()
      "one and two"

      iex> ["one", "two", "three"] |> PlausibleWeb.TextHelpers.pretty_join()
      "one, two and three"
  """
  def pretty_join([str]), do: str

  def pretty_join(list) do
    [last_string | rest] = Enum.reverse(list)

    rest_string =
      rest
      |> Enum.reverse()
      |> Enum.join(", ")

    "#{rest_string} and #{last_string}"
  end
end
