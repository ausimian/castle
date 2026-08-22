defmodule Castle.IoSink do
  @moduledoc false

  # An IO device that collects what is written to it, for the tests that start a
  # real peer.
  #
  # `ExUnit.CaptureIO` cannot host one: it captures by making a `StringIO` the
  # group leader, the peer's output is forwarded to whatever the group leader is,
  # and starting the elixir application sets the encoding of its standard IO -
  # which `StringIO` answers `{:error, :enotsup}` to, taking the peer's boot down
  # with it. So this accepts anything an IO device is asked and remembers the
  # rest.

  @doc """
  Runs `fun` with this as the group leader, and returns its value along with
  everything that was written.

  The peer's control process inherits the group leader of whoever started it,
  which is what puts the peer's output in here.
  """
  def with_group_leader(fun) do
    sink = spawn_link(fn -> loop("") end)
    previous = Process.group_leader()
    true = Process.group_leader(self(), sink)

    try do
      {fun.(), contents(sink)}
    after
      Process.group_leader(self(), previous)
    end
  end

  defp contents(sink) do
    ref = make_ref()
    send(sink, {:contents, self(), ref})

    receive do
      {^ref, contents} -> contents
    after
      5_000 -> raise "the io sink did not answer"
    end
  end

  defp loop(written) do
    receive do
      {:io_request, from, reply_as, request} ->
        {reply, written} = handle(request, written)
        send(from, {:io_reply, reply_as, reply})
        loop(written)

      {:contents, from, ref} ->
        send(from, {ref, written})
        loop(written)
    end
  end

  defp handle({:put_chars, encoding, chars}, written) do
    {:ok, written <> to_binary(encoding, chars)}
  end

  defp handle({:put_chars, encoding, module, fun, args}, written) do
    handle({:put_chars, encoding, apply(module, fun, args)}, written)
  end

  defp handle({:requests, requests}, written) do
    Enum.reduce(requests, {:ok, written}, fn request, {_reply, acc} -> handle(request, acc) end)
  end

  defp handle({:setopts, _opts}, written), do: {:ok, written}
  defp handle(:getopts, written), do: {[binary: true, encoding: :unicode], written}
  defp handle(_request, written), do: {{:error, :enotsup}, written}

  defp to_binary(encoding, chars) do
    case :unicode.characters_to_binary(chars, encoding, :unicode) do
      binary when is_binary(binary) -> binary
      _otherwise -> ""
    end
  end
end
