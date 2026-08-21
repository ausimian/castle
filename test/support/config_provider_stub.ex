defmodule Castle.ConfigProviderStub do
  @moduledoc false

  # A `Config.Provider` that does something small and observable, so that
  # `Castle.Commands.generate/1` can be tested without a real runtime.exs.
  #
  # Its state - which is what Forecastle stashes in build.config, having called
  # init/1 at build time - says what to do:
  #
  #   * `merge:` a keyword list, to merge it into the configuration, and
  #   * `raise:` a message, to fail the way a provider that cannot find what it
  #     needs fails.

  @behaviour Config.Provider

  @impl Config.Provider
  def init(opts) when is_list(opts), do: opts

  @impl Config.Provider
  def load(config, opts) do
    if message = opts[:raise] do
      raise message
    end

    Config.Reader.merge(config, Keyword.get(opts, :merge, []))
  end
end
