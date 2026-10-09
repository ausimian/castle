# `test/e2e` builds and upgrades real releases, needs the network for Hex, and
# takes minutes. It is opt-in: `mix test --include e2e`.
ExUnit.start(exclude: [:e2e])
