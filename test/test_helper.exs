# `test/e2e` builds and upgrades real releases, needs the network for Hex, and
# takes minutes. It is opt-in: `mix test --include e2e`.
ExUnit.start(exclude: [:e2e])

# Elixir's `:logger` application, as on a consumer node. Castle does not depend
# on it, so `mix test` would otherwise leave kernel's primary level at `notice`,
# and the `info` lines the commands log would never reach a capture.
{:ok, _} = Application.ensure_all_started(:logger)
