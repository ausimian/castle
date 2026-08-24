defmodule Castle.DeploymentStub do
  @moduledoc false

  # A stand-in for `Castle.Deployment`, so that the state the ERTS guard exists
  # to refuse can be reached at all. Under `mix test` there is no `RELEASE_ROOT`
  # and the guard is inert - which is the property that makes it safe, and also
  # the reason a refusal cannot be observed without substituting its input.
  #
  # It answers the deployment facts and the filesystem outcomes whose failing
  # forms a fixture cannot produce reliably. The comparison, classification and
  # messages are `Castle.Commands`', and they run for real against whatever this
  # returns. Replies live in the calling process's dictionary, like
  # `Castle.ReleaseHandlerStub`, and for the same reason.

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
  def stub_stat(reply), do: put(:stat, reply)

  @doc """
  Registers the restart-marker path inspection result.

  Unregistered, `lstat/1` calls the filesystem. A registered failure lets a test
  prove that an install which cannot inspect the marker is refused before target
  configuration is re-resolved.
  """
  def stub_lstat(reply), do: put(:lstat, reply)

  @doc """
  Registers what the filesystem will say when the restart marker is read, or when
  it is removed.

  Unregistered, both are the real thing, for the reason `stub_stat/1` is. They are
  here because the answers that decide what `disarm/3` *says* are the failing
  ones, and every fixture that produces a failing `read` or `rm` on a regular file
  in a writable directory does it with a mode - which root and some filesystems
  ignore, so the fixture would only sometimes describe the state it names, and
  would pass either way.

  A reply that is a function of one argument is called with the path, which is
  what lets a failure be made to bite on the marker alone.
  """
  def stub_read(reply), do: put(:read, reply)
  def stub_rm(reply), do: put(:rm, reply)

  def release_root, do: fetch(:release_root)
  def root_dir, do: fetch(:root_dir)

  def stat(path), do: filesystem(:stat, path, &File.stat/1)
  def lstat(path), do: filesystem(:lstat, path, &File.lstat/1)
  def read(path), do: filesystem(:read, path, &File.read/1)
  def rm(path), do: filesystem(:rm, path, &File.rm/1)

  defp filesystem(operation, path, real) do
    case Process.get({__MODULE__, operation}, :unstubbed) do
      :unstubbed -> real.(path)
      reply when is_function(reply, 1) -> reply.(path)
      reply -> reply
    end
  end

  defp put(operation, reply) do
    Process.put({__MODULE__, operation}, reply)
    __MODULE__
  end

  defp fetch(fact) do
    case Process.get({__MODULE__, fact}, :unstubbed) do
      :unstubbed -> raise "#{fact}/0 was called without a registered value"
      value -> value
    end
  end
end
