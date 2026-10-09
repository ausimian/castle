# Castle's own appup, compiled into `ebin/castle.appup` by Forecastle's appup
# compiler - in this project's build and in every consumer's, since Hex ships
# source and a consumer compiles Castle with this project's `mix.exs`.
#
# It exists because Castle is part of every consumer release. When Castle's
# version changes between two consumer releases, Forecastle looks for this file
# to decide whether the transition can be hot. Without an entry for the
# version being upgraded from, it judges the transition a `restart_emulator`
# under `auto`. Nothing fails; every such upgrade restarts the emulator instead.
#
# **The first element is the version being released, and it is written before
# that version exists.** `@version` in `mix.exs` stays at the last release until
# `mix publisho` bumps it, so the two disagree on `main` between a release being
# prepared and being tagged. That is harmless: a relup reads this file only when
# Castle's version changes. `test/e2e/appup_test.exs` builds Castle at the
# version named here, and upgrades a consumer from each version named below.
#
# Castle has no application callback and no processes, so `load_module` is the
# whole of each transition. Each instruction names the changed modules it calls,
# which is what lets `:systools` load callees first on the way up and callers
# first on the way down, so that nothing loaded calls a function its callee
# does not have yet, or no longer has.
#
# **The installing process outlives its own code.** `bin/castle install` runs
# the *old* Castle, and after `install_release/1` returns it carries on in the
# old `Castle.Commands`, calling into whatever the relup just loaded. So the
# functions on that path - `Castle.Deployment.read/1` and `rm/1`, and
# `Castle.Peer`'s file primitives - are an API between adjacent versions. See
# AGENTS.md.
{
  ~c"1.0.1",
  [
    {~c"1.0.0",
     [
       {:load_module, Castle.Deployment, []},
       {:load_module, Castle.Peer, []},
       {:load_module, Castle.Commands, [Castle.Deployment, Castle.Peer]},
       {:load_module, Castle, [Castle.Commands, Castle.Deployment, Castle.Peer]}
     ]}
  ],
  [
    {~c"1.0.0",
     [
       {:load_module, Castle.Deployment, []},
       {:load_module, Castle.Peer, []},
       {:load_module, Castle.Commands, [Castle.Deployment, Castle.Peer]},
       {:load_module, Castle, [Castle.Commands, Castle.Deployment, Castle.Peer]}
     ]}
  ]
}
