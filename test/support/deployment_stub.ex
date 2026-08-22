defmodule Castle.DeploymentStub do
  @moduledoc false

  # A stand-in for `Castle.Deployment`, so that the state the ERTS guard exists
  # to refuse can be reached at all. Under `mix test` there is no `RELEASE_ROOT`
  # and the guard is inert - which is the property that makes it safe, and also
  # the reason a refusal cannot be observed without substituting its input.
  #
  # It answers the two facts and nothing else: the comparison, the path
  # normalisation and the message are `Castle.Commands`', and they run for real
  # against whatever this returns. Replies live in the calling process's
  # dictionary, like `Castle.ReleaseHandlerStub`, and for the same reason.

  @doc """
  Registers the pair of roots, and returns this module so that it can be passed
  straight to the function under test.
  """
  def stub(release_root, root_dir) do
    Process.put({__MODULE__, :release_root}, release_root)
    Process.put({__MODULE__, :root_dir}, root_dir)
    __MODULE__
  end

  @doc """
  Registers what the filesystem will say about both paths.

  Unregistered, `stat/1` is the real one, so a test that only cares about the
  roots does not have to describe the filesystem too. Registered, it is how the
  two answers no fixture can produce on demand - a `stat` refused with `:eacces`,
  and a filesystem reporting no inode numbers - are reached at all.
  """
  def stub_stat(reply) do
    Process.put({__MODULE__, :stat}, reply)
    __MODULE__
  end

  def release_root, do: fetch(:release_root)
  def root_dir, do: fetch(:root_dir)

  def stat(path) do
    case Process.get({__MODULE__, :stat}, :unstubbed) do
      :unstubbed -> File.stat(path)
      reply when is_function(reply, 1) -> reply.(path)
      reply -> reply
    end
  end

  defp fetch(fact) do
    case Process.get({__MODULE__, fact}, :unstubbed) do
      :unstubbed -> raise "#{fact}/0 was called without a registered value"
      value -> value
    end
  end
end
