# Castle

Runtime support for hot-code upgrades in Elixir releases. Castle is the runtime
half of a pair: [Forecastle](https://github.com/ausimian/forecastle) is the
build-time half. Consumers depend on Castle, which pulls Forecastle in as a
build-time dependency.

## What it does

Castle's job is configuration and release management on a running node.

- **Materialising the target's configuration**, which `install/1` and `commit/1`
  do before they hand a version to `:release_handler`. This is the whole reason
  the pair exists: Mix expands runtime configuration once, at boot, from the
  version it booted; Castle expands it for the version being upgraded *to*,
  before the relup runs.

  There is one way it happens, and there used to be two. The other read a
  `build.config` — the `sys.config` Forecastle renamed at assembly time, having
  stripped the providers out and stashed their initialised state under
  `:castle` — and folded that state over it in the running node, which is
  `Castle.generate/1`. Both halves of that are gone: forecastle#6 stopped
  intercepting configuration at build time, and the third step of
  [#13](https://github.com/ausimian/castle/issues/13) deleted the path that read
  it. Do not reintroduce either. A release whose providers ran in the version
  that happens to be running was configured by the wrong code.

  What is left is `Castle.Peer`: a `:peer` reached over a loopback socket — so no
  epmd, cookie, node name or distribution; the peer reports `nonode@nohost` and
  `is_alive() == false` — booted on the target's own `preboot` script and its
  own emulator, which runs `Config.Provider.boot/1` over the target's own
  provider modules and hands the resolved configuration back to be written.
  Castle does not fold providers itself, and must not acquire the ability to:
  the point of #13 is that Elixir's pipeline stays the only implementation of
  it. What Castle arranges is that the pipeline *writes* rather than configuring
  the VM it happens to be in, which is one field of the provider state and a
  reboot function that does nothing.

  A provider module can differ between the version that is running and the
  version being installed, which is why this cannot be done on the running
  node, and is what the peer earns.

  Six things about it are load-bearing.

  Every evaluation starts from the configuration Mix wrote, and never from the
  result of the last one. Providers are not obliged to be idempotent and the
  ones people write are not — `if System.get_env("FEATURE"), do: config …` in a
  `runtime.exs` sets a key on a run where the variable is set and says nothing
  about it on a run where it is not — so resolving over the previous result
  would leave that key behind, and the version an operator commits would be
  configured differently from the way it boots. `sys.config` cannot be the base,
  because that is the file `:release_handler` reads and so the file the resolved
  result has to land in; the first materialisation therefore copies it to
  `sys.config.pristine` and every later one seeds from there.

  That copy is staged in the working directory below, given the mode
  `sys.config` has, and published by hard link. Not written to its final name,
  and an exclusive create is not enough either: exclusivity makes *creation*
  atomic, not publication, so the file exists and is empty between the open and
  the write — long enough for a racing reader to see something that is not a
  configuration, and, if the install died there, long enough to leave a truncated
  base that every later evaluation would prefer to the original still in
  `sys.config`. A link publishes a file that is already complete, and refuses
  rather than replaces, so the loser of a race reads what the winner published
  instead of its own copy. Staging that never gets published is left where it is:
  an install cannot tell its own leftovers from another install's work in
  progress, so it does not try, and nothing reads that name. Do not "tidy up"
  stray `castle-*` names — files or directories — in code for the same reason.
  `Castle.Peer` removes the working directory *it* made, on every way out, and
  nothing else.

  **Both files this module creates are made inside an owner-only working
  directory and moved out of it, and a new one must be too.** Each holds a
  release's configuration — the base, and the scratch copy the providers resolve
  into — so none may be readable by anyone the `sys.config` it came from or is
  about to become would exclude: an operator who restricts that file has said
  something, and it has to hold for the copies.

  **The protection is the directory, not the file's own mode, and it has to be:
  OTP cannot create a file with a mode.** `:file.open/2`'s modes say how a file
  is to be read and written and nothing about the permissions it is created
  with — kernel's `mode()` type is the whole list — and an unrecognised option is
  ignored rather than refused, so `{:mode, 0o600}` is *accepted* and does
  nothing. The inode is created 0666 against the umask whichever way in you
  take. So a mode can only be applied to a file that already exists, and `chmod`
  does not revoke a descriptor somebody already holds: a reader who opened the
  path while it was 0644 goes on reading everything written afterwards. That is
  a standing read channel, not a blink, and no amount of care at the call site
  closes it. Do not go looking for an atomic create-with-mode; there isn't one.

  What works is `Castle.Peer.work_dir/1`: `mkdir` a directory in the version
  directory, chmod it 0700, and then **check that it is still empty**, refusing
  and removing it if it is not. `plan/2` is the one place the two file paths are
  decided, and it puts both inside that directory under the names they will have
  when they leave. Each is created **exclusively**, so a name already at the
  path is refused rather than followed or truncated, and each is **written
  through the handle that exclusive open returned**.

  **Never reopen a name to place content.** The exclusive open's whole value is
  that it establishes the name did not exist; closing the handle and reopening
  the same name by path throws that away, and anything able to create the name
  in between is handed the configuration. `write_private/2` therefore creates
  and fills in one movement — there is deliberately no way here to bring one of
  these files into existence without also placing its content, because
  separating the two is what let a reopen back in.

  The `chmod` is the one step that still goes by path, because OTP has nothing
  that sets a mode on an open file: `:file.change_mode/2` and
  `:file.write_file_info/2` take a name and reject a handle (`:badarg` and
  `:function_clause`). That is an accepted asymmetry rather than an oversight.
  By the time it runs the content is already committed to the inode the open
  created, so a name swapped underneath it does not receive the configuration —
  it gets narrowed, which is Castle setting some other file to 0600 inside a
  directory it verified empty and made 0700. A nuisance, not a disclosure.

  **The rule is create, narrow, then verify — and write through the handle you
  created.** The verification is not decoration and it is not defence in depth:
  it is there because five successive attempts to reason about whether a window
  was harmless were all wrong, and a sixth judgement of the same kind is worth
  nothing. Do not remove it on the grounds that you can see why the window is
  safe. That is precisely the sentence that preceded each of the previous five
  findings.

  The particular argument it replaced, so nobody reconstructs it: an empty
  directory has nothing behind the window, and permission to traverse a
  directory is checked on every lookup rather than captured at open the way
  permission to read a file is, so a stale directory descriptor grants nothing
  once the chmod has happened. Both halves are true, and both are about
  *reading*. A directory the umask left group-writable — 0002 is an ordinary
  umask and 0000 exists — can be written *into* during that window, and the child
  names are predictable, so an interloper needs no descriptor at all: it plants
  `sys.config` as a symlink to a file it can read and waits for the
  configuration to arrive through it. Empty is safe to read. It is not safe to
  write into.

  Exclusivity and privacy are separate properties and neither substitutes for
  the other. `:exclusive` on the open says nothing about the permissions the
  inode arrives with, which is why it is no answer to the paragraph above — that
  was measured, and `{:mode, _}` alongside it is silently ignored. A private
  directory says nothing about what a name already inside it would do, which is
  why it is no answer to a planted symlink: `File.write/2` follows one, truncates
  what it points at, chmods *that* to 0600, fills it with the configuration, and
  creates the target outright if the link dangles. All measured, all refused by
  `:exclusive`, which returns `:eexist` for a regular file, a symlink and a
  dangling symlink alike. `File.mkdir/1` refuses all three too, which is what
  stops the working directory's own name being taken first.

  It does not defend a version directory other accounts can write to: whoever
  can create a name there can replace `sys.config` itself, so that release is
  compromised before Castle is asked to configure it. The case defended is the
  ordinary one, a version directory anyone may traverse and read.

  `write_private/2` **refuses** to create a file in a directory that grants
  anything to group or other, rather than trusting the caller to have picked a
  path inside the working directory — the invariant is in the primitive because
  remembering it at the call sites is what failed, four times over. It is a
  guard against the next call site rather than against an attacker — a directory
  can be chmodded between the check and the create, which is the gap the
  exclusive create covers — and it also catches a filesystem that took the
  `mkdir` and ignored the `chmod`, where none of this can be honoured and the
  operator's own mode on `sys.config` would not be either.

  The file is given 0600 on creation and the model's mode **last** —
  `write_like/3` is `write_private/2` plus that, for a file written once. The
  ordering matters for the writes that come *after*, not for the first one: a
  `sys.config` at 0440 is an operator declaring their configuration read-only,
  and the scratch is written twice more after Castle creates it — the peer's
  pipeline writes the resolved configuration over it, then this module writes it
  again — with both of those reopening the name, and a file at 0440 cannot be
  reopened for writing. So the model's mode goes on last of all, immediately
  before the rename, and a failure part-way leaves the file narrower than
  intended rather than wider. Do not "simplify" the ordering back.

  **The scratch's later writes rest on the directory, not on the handle.** One of
  them is `Config.Provider.write_config!`, which is `File.write/2` in Elixir's
  own code, in the peer's VM — driving Elixir's pipeline is what this module is
  for, so that is not ours to change and must not be worked around. Nor may the
  creation handle be held open across the peer's run to cover them: the peer
  writes by name in a VM of its own, and a handle kept here would go on pointing
  at whichever inode the name had when it was opened. Elixir truncates the same
  inode today; one that wrote a temporary file and renamed it would leave the
  handle on an orphan and the configuration written through it would silently be
  nobody's. What protects those writes is that the directory was verified empty,
  is 0700, and holds only names Castle created.

  The two operations that move one of these files into place, the link that
  publishes the base and the rename that replaces `sys.config`, need permission
  on the directories rather than on the file, so a restrictive mode never has to
  be relaxed again; nor does removing what is left in the working directory
  afterwards.

  `File.write/2` creates with the process umask and never looks at a mode.
  `File.cp/2` *does* carry the mode — and was adopted here for that reason — but
  it writes the whole file first and narrows it afterwards (`:file.copy`, then
  `copy_file_mode/2` at `file.ex:1285`), which is the same exposure with a
  shorter window. The end state is identical either way, which is exactly why no
  test of the end state caught any of it. Do not add another way to write one of
  these files, and do not create one next to `sys.config` however carefully;
  extend the primitive, and put the file in the working directory.

  **Ownership and group are not reproduced — only the mode bits are.** This is a
  property of the design, not an oversight. Reproducing them needs `chown`,
  which needs privileges a release account does not have, and where Castle could
  chown it is running as root, which is a worse problem than the one being
  solved. Applying the model's numeric mode is what the operator asked for; that
  the process's default group differs from the model's is an environmental fact
  Castle cannot correct. So a deployment that restricts `sys.config` through
  group ownership — `root:secrets` at 0640, say — needs the release account's
  default group to be right for the version directory, because the base and the
  scratch will be created with that group and the mode bits will be honoured
  against it.

  A base that cannot be read as a configuration is refused, naming the remedy,
  rather than resolved from: it is preferred to `sys.config` by definition, so
  failing loudly is the only safe thing left.

  This is permanent design: the path this replaced always had a pristine base —
  `build.config` *was* one, and nothing ever wrote it — and this is what carries
  that property forward now that it is gone.
  `sys.config` gains a `CASTLE_MATERIALISED` comment line, which makes
  the invariant checkable: written by Castle, so a base must exist. A version
  that says that and has no base beside it is refused, with the remedy (unpack
  it again) named, rather than having a once-resolved configuration captured as
  though it were the original.

  With a pristine base, materialising at `commit` is not merely harmless but
  right: it produces what a boot at commit time would produce, which is the
  point of doing it there.

  The peer is started linked and stopped on every path out, including the
  failing ones; `wait_boot` and the call both have deadlines, so a peer that
  never answers cannot hold an install open. Everything that can refuse — a
  missing boot script, an emulator that is not there, a provider that raises, a
  compile environment that does not agree — refuses before `install_release/1`
  is called. The resolved configuration is assembled in the working directory
  and renamed onto `sys.config`, so a version never holds half a configuration.

  The control connection is a socket rather than `connection: :standard_io`,
  which is what the issue suggested. Standard IO multiplexes the peer's console
  output with the frames carrying the call over one byte stream and reserves
  sixteen byte values for the framing, every one of them a UTF-8 lead byte — so
  a provider, or a NIF under it, writing an accented character straight to a
  file descriptor fails the frame's checksum and takes the control process down,
  refusing an install that was about to succeed. Nothing outside `:peer` can
  harden that; the shared stream *is* the mechanism. The socket costs the
  diagnosis of a peer that cannot boot: a detached peer says nothing on its way
  down and the origin holds no handle on it, so a failed boot is noticed when
  the deadline expires rather than at once and with the emulator's reason. That
  was the trade, and it went the way it did because a broken release is broken
  either way while a working one must not be refused.

  Because a detached peer's descriptors are the null device, its standard error
  is relayed through its `user` process — which is what makes Elixir's account
  of a provider that raised reach the operator at all. A raw write still goes
  nowhere, which is the safe direction.

  `Castle.Peer.resolve/1` is called *in the target release*, so
  `{Castle.Peer, :resolve, 1}` is a contract between one version of Castle and
  the next. A target too old to have it fails the call and the install is
  refused.

  Finally, `Castle.Peer` makes the compile-environment check Elixir would have
  made, with Elixir's own validator. Elixir makes it in the branch that
  *applies* a resolved configuration, and again on the boot that follows the
  branch that *writes* one; this drives the writing branch and nothing boots
  afterwards, so without it a release Elixir considers unbootable would be
  installed and the problem found on the way up, where the only way out is a
  rollback. Do not weaken it into something that skips when it does not
  recognise what it was given: it refuses instead, because a check that silently
  passes everything looks exactly like a check that works.

- **`Castle.make_releases/0`** — creates the `RELEASES` file from the running
  permanent release if it does not already exist, so a release assembled by Mix
  can manage its own upgrades. The directory is derived from `code:root_dir()`,
  which no caller has to change directory to reach and none should: the working
  directory was only ever visible to the `File.exists?/1` guard, which is what
  let the file this looked for and the file OTP wrote be different ones.

  **That derivation is right for the default Mix configuration and only for it.**
  `:release_handler` resolves its relative paths against `code:root_dir()`
  (`consult/2` is `file:consult(root_dir_relative_path(File))`, and
  `do_write_release/3` the same), but the *releases directory* is not one of
  them: `init/1` takes it from `{sasl, releases_dir}`, then `RELDIR`, and only
  then `init:get_argument(root)`. Mix sets neither, so on a Mix release the two
  coincide — but a deployment that sets either has Castle writing `RELEASES`
  where the handler will not read it, and then the record check refuses with a
  message naming a restart as the remedy, which a restart does not fix. That is
  [#23](https://github.com/ausimian/castle/issues/23), not something to leave
  implied here: the claim that this directory is "the one OTP writes" is true by
  default and false under configuration OTP documents.

  It calls **`create_RELEASES/3`**, never `/4` with the root
  supplied: `/3` is `create_RELEASES("", RelDir, RelFile, LibDirs)`, and
  `check_rel_data/4` stores library directories as `lib/<app>-<vsn>` when the
  root is empty and as absolute paths under it when it is not — "to make it easy
  to create a relocatable RELEASES file", in OTP's own words. Passing the root
  would bake this machine's paths into a file whose point is that it can be
  moved, and no end-state test would see it.
- **The ERTS guard** — `include_erts: false` is fundamentally incompatible with
  `release_handler`-based hot upgrades in a Mix release, and Castle refuses such
  a deployment rather than serving it. `Castle.Commands.ensure_own_erts/2` is the
  reference account; this is the shape of it.

  `Mix.Release.copy_erts/1` has a clause for `%{erts_source: nil}` that copies
  nothing, and only the other clause writes the `erl` shim that rewrites
  `ROOTDIR` to the release root. `include_erts: false` is what sets `erts_source`
  to nil, and `releases/<vsn>/elixir` keeps its `ERTS_BIN="$ERTS_BIN"` line
  unrewritten, so the launcher runs whichever `erl` is on the path and
  `code:root_dir()` is the shared Erlang installation rather than the deployment.

  **The root is not Castle's to choose differently, and deriving it from
  `RELEASE_ROOT` would be worse rather than better.** It is `release_handler`'s
  own anchor: `root_dir_relative_path/1` is
  `filename:join(code:root_dir(), Pathname)`, and `create_RELEASES/3` stores
  library directories *relatively* — `filename:join("lib", LibName)`, so the file
  stays relocatable — so every `lib/<app>-<vsn>` the handler reads, writes or
  deletes resolves there, as does the `extract_tar(Root, Tar)` an unpack goes
  through and the `erts-<erts_vsn>` a removal deletes. So a Castle that wrote to
  `$RELEASE_ROOT` would put the configuration where the handler never looks, and
  an upgrade would go on using applications under the installation — a silent
  divergence in place of a loud failure. Do not "fix" the guard that way.

  **The release records are the exception, and saying otherwise is the mistake
  this file made first.** `releases/RELEASES` and `releases/<vsn>/…` are *not*
  anchored to the root: `init/1` takes the releases directory from
  `{sasl, releases_dir}`, then `RELDIR`, and only then `init:get_argument(root)`.
  Mix sets neither, so on a Mix release they land under the root by default — but
  "by default" and "necessarily" are different claims, and the second one is
  false. It changes nothing about the guard, because the handler keeps the root
  and the releases directory as separate state and only the second follows
  `RELDIR`: relocating the records moves the bookkeeping and leaves the
  applications being extracted into, resolved against and deleted out of the
  root. That is why `RELDIR` is not a way out, and why the refusal says so.

  The question is asked of the node, and there is exactly one implementation of
  it. **The shell-side gate in Forecastle's `env.sh` was considered and
  refused.** It would have saved the deployment a preboot VM and a refusal on
  every start — `RELEASES` never appears in the deployment, so the hook's local
  absence check invokes it again every time — and that cost is accepted
  deliberately, because a shell test can only approximate what the node knows,
  which is the class of bug #13's third step removed (*"It has to be asked of the
  node rather than of the filesystem"*), and a second implementation of the rule
  can drift from the first. Do not add it later thinking it was an oversight.

  The evidence is that every launcher `mix release` generates exports
  `RELEASE_ROOT` from its own location before it sources `env.sh`, so a set
  `RELEASE_ROOT` naming a directory other than `code:root_dir()` is exact and
  needs no globbing. Nothing else sets the variable, so outside a release — under
  `mix test`, in a VM started by hand — there is nothing to compare and the guard
  is inert, which is what makes it safe in front of every mutating operation. The
  two are the same string on an ordinary release, both being `pwd -P` output in
  scripts Mix generates, so `Path.expand/1` settles it; a `stat` on device and
  inode is the fallback, because refusing a deployment that *does* bring its own
  ERTS — one spelled through a `current` symlink, say — is the one failure here
  an operator cannot work around.

  **What it detects is the divergence, not the missing ERTS, and the message
  asserts no cause at all.** `include_erts: false` is the cause in almost every
  case but it is not the only one: the `erl` shim Mix writes is
  `ROOTDIR="${ERL_ROOTDIR:-…}"`, so an `ERL_ROOTDIR` in the environment diverges
  the two on a release that *did* bring its ERTS. Two directories are the whole
  of the evidence, and nothing here can tell those apart or knows that they
  exhaust the possibilities, so both are offered as examples. This message has
  now been wrong twice in the same way — first asserting the missing ERTS, then
  asserting `ERL_ROOTDIR` as the only alternative — so state the divergence and
  stop. A cause stated confidently from two directories is how a correct refusal
  comes to be read as a bug in the guard, and it sends an operator to rebuild
  something that was not the problem. `Castle.Peer.emulator/2` is the one that
  may still speak of ERTS in particular, because it looked for the emulator and
  it was not there.

  **Do not say that everything `:release_handler` touches resolves under the
  emulator's root — the release records alone do not.** `init/1` takes its
  releases directory from `{sasl, releases_dir}`, then `RELDIR`, and only then
  `init:get_argument(root)`, so those two genuinely relocate it, and a message
  claiming otherwise is false. It does not rescue such a deployment, which is
  why the guard is still right: the handler holds the root and the releases
  directory as *separate* state and only the second follows `RELDIR`.
  `do_unpack_release/4` extracts through `extract_tar(Root, Tar)`,
  `check_rel_data/4` records library directories as `lib/<app>-<vsn>` for
  resolution against `code:root_dir()`, and `do_remove_release/4` deletes
  `filename:join(Root, "erts-" ++ EVsn)`. Relocating the records moves the
  bookkeeping and leaves the applications themselves being extracted into, read
  from and deleted out of the emulator's root.

  `EVsn` there is the *ERTS* version out of the release record, not the release
  version, and `do_remove_release/4` deletes that directory only when no
  remaining release refers to the same emulator. The two are unrelated numbers
  and normally different ones - a release at `0.1.1` carrying `erts-16.2` - so
  prose must not reuse `<vsn>` for both. Writing `erts-<vsn>` beside
  `lib/<app>-<vsn>` reads as one version and names a directory that generally
  does not exist; it had got into `remove/1`'s `@doc` and into the ERTS guard's
  refusal message, which ships. Say `erts-<erts_vsn>`.

  **The comparison has three answers, not two.** `compare_dirs/2` is
  `Path.expand/1` on both and then a `stat` on device and inode, and it returns
  `:same`, `:different` or `{:indeterminate, why}`. The third is the one to keep:
  by the time the `stat` runs the two have already failed to match as strings, so
  a catch-all folding every unusable result into `:different` puts an `:eacces`
  on a parent, an `:enoent`, an `:eloop` and a filesystem with no inode numbers
  into the same branch as two directories that genuinely differ — and then the
  message asserts a difference that was never established. Both answers still
  refuse, so this changes no outcome; it changes what the operator is told, which
  is the part they act on. Do not fold them back together, and note that
  fixtures feel it: a test pointing `RELEASE_ROOT` at a path nothing created
  exercises the *indeterminate* refusal, not this one, so the directories in
  these tests have to exist.

  It gates `make_releases/0` — before the `File.exists?` check, not after,
  because an Erlang installation built by OTP has a `releases/RELEASES` of its
  own and looking first would find it, report success and never say anything —
  and `unpack/1`, `install/1`, `commit/1` and `remove/1`, `remove` most of all,
  since `remove_release` *deletes* paths resolved against `code:root_dir()`. It
  gates `materialise/3` too, which is what `install/1` and `commit/1` do first,
  or the operator's first news would be that some version directory inside the
  Erlang installation holds nothing to configure. `upgradable/0` and `releases/0`
  are deliberately outside it, for the reason `commit`/`remove`/`releases` are
  outside the release-record check and one of its own: they only read, and an
  operator has to be able to ask what the node thinks it is running in order to
  make sense of the refusal. Gating a diagnostic on the condition it diagnoses
  leaves nothing to ask.

  Unlike the record check, `commit` and `remove` *do* carry this one, and that is
  not an inconsistency: the record check could strand an upgrade already under
  way, while this says the deployment could never have been upgraded at all, so
  there is nothing to strand.

  `Castle.Peer.emulator/2`'s refusal stays, and points here rather than
  restating any of it. It is reached more narrowly — a release whose own release
  file names an ERTS that is not under the root it was unpacked into — and it is
  what is left if the guard is ever reached with `RELEASE_ROOT` unset.
- **The release record check** — `unpack/1` and `install/1` refuse a system whose
  release record `:release_handler` synthesised for itself, and they refuse it
  from *inside* the operation. `:release_handler` reads `RELEASES` once, in
  `init/1`, and when it cannot it builds a record out of the boot script's name
  and version with the `libs` field left at `[]`. Nothing can replace that
  afterwards, and creating the file later does not: the first operation that
  changes anything writes the in-memory record back over it. Upgrading from it is
  silently wrong rather than refused — the relup's `point_of_no_return` switches
  code paths for `get_new_libs(Current, New)`, which folds over the *current*
  release's applications and so yields nothing at all, leaving any application
  whose version changed but whose code the relup does not load running from the
  directory of the release being replaced. The discriminator is that empty
  application list, and it is exact: `which_releases/0` reports
  `mk_lib_name(Libs)`, `mk_lib_name([]) -> []`, and a record read from a
  `RELEASES` file names at least `kernel` and `stdlib`. The remedy the message
  names is a restart, because that is the only thing that changes the answer.

  **A restart is necessary and not always sufficient, so the message names the
  state the file has to be in rather than just saying "restart".** The record is
  synthesised when `RELEASES` was missing *or* could not be read, and Forecastle's
  `env.sh` creates it only when it is **absent** (`[ ! -f ... ]`). So a file that
  is present and unreadable is stepped over on every start: the node comes back on
  a freshly synthesised record, the refusal repeats, and an operator following a
  message that named only the restart would loop forever.

  **State the required condition, not the boot-time cause.** The obvious
  correction — branch the advice on why the record was synthesised, absent versus
  unreadable — is wrong in a third case, and that was the first attempt here. The
  file can have been absent at boot and been created, readably, since: the node
  keeps its synthesised record either way, so the refusal still fires, and an
  operator told to check whether the file is "absent" or "present and unreadable"
  finds it is neither and has no applicable advice. A plain restart is exactly
  right for them. So the message asks for `releases/RELEASES` to be *absent or
  consultable* before the restart, which covers all three states and is shorter
  than the branch it replaced. Do not turn it back into a case analysis of the
  cause, and do not collapse it into a bare "restart the system" either.

  **Name the authority, not the mechanism — and this is the lesson of five
  successive corrections to one sentence.** Each named a property of the file and
  each was necessary but not sufficient, so each admitted a narrower
  counterexample: "restart" missed a file that was present and unreadable;
  "present or absent" missed one created readably since boot; "readable" missed
  malformed terms, because `init/1` reads it with `file:consult/1`; "consultable"
  missed a file of two valid terms, because `init/1` accepts only `{ok, [Term]}`.
  There is no reason to think that series had ended, and the hook leaves an
  existing file alone whatever is in it, so every one of those states loops.

  The message therefore asks for a file **`:release_handler` accepts**, and says
  that no single property of the file is the test. That cannot be narrowed further
  because it does not claim a mechanism, and it is what an operator needs anyway:
  the handler is the thing that has to take the file. Do not "improve" it by
  substituting whichever internal criterion is current — that is the move that was
  wrong five times.

  **And it must not name `releases/RELEASES` unqualified**, because that is the
  file the *release* creates, not necessarily the one the handler reads — see
  `Castle.Deployment.root_dir/0` and
  [#23](https://github.com/ausimian/castle/issues/23). Where `RELDIR` or
  `{sasl, releases_dir}` points elsewhere the two are different files, and the
  remedy is then genuinely harder rather than merely differently spelled: the
  hook creates one at the root that the handler will not read, so "absent" does
  not get the operator out either, and the file the handler *does* read has to be
  put there by hand. The message says so. When #23 lands and Castle follows those
  overrides, this paragraph and that sentence both need revisiting — the
  divergence is the thing being described, and it is the thing #23 removes.

  It has to be asked of the node rather than of the filesystem — a file that
  appeared *after* the boot that looked for it passes a shell test and still
  leaves the node on the synthesised record — and it has to be asked *in the call
  that acts*. It was a separate rpc from `bin/castle` while #13 was being built,
  and that was wrong: two rpcs are two moments and possibly two node instances,
  so a node could pass the check on the record it read at boot, restart onto a
  synthesised one, and have the unpack or the install arrive afterwards and go
  ahead on an answer that no longer held. **Do not reintroduce a separate check
  in front of these operations**, in `bin/castle` or anywhere else. It is
  `Castle.Commands.ensure_upgradable/2`, and both operations make it themselves
  before `:release_handler` is asked for anything.

  `install` is checked because that is where the silent damage happens. `unpack`
  is checked because it is the one other operation that *writes* release records:
  `do_unpack_release/4` ends in `write_releases/3` over the records the handler
  holds, so an unpack puts the synthesised record into `RELEASES`, the next boot
  reads it back as though it had always been there, and `Castle.make_releases/0`
  does nothing when the file exists — so an unpack allowed through takes away the
  restart the refusal names. `commit`, `remove` and `releases` are deliberately
  *not* checked, and that is measured rather than assumed: `do_make_permanent/2`
  returns early for a release that is already permanent and errors for every
  other status, `do_remove_release/4` refuses the permanent release outright, and
  `releases` only reads — none of them can write that record back, while refusing
  them could strand an upgrade already under way, a version installed and waiting
  to be committed that the next restart would take back.
- **`Castle.upgradable/0`** — the same question asked on its own, and nothing
  more: a diagnostic, not a gate, and nothing has to call it. It stays because
  the state it reports is otherwise invisible — the file can be present while the
  record the node works from was synthesised — so an operator needs a way to ask
  that does not unpack or install anything.
  [#11](https://github.com/ausimian/castle/issues/11) settled that it belongs in
  the documented surface, and for that same reason: `bin/castle upgradable` is
  how an operator asks, and a diagnostic nobody is told about is one nobody
  thinks to ask.
- **`unpack/1`, `install/1`, `commit/1`, `remove/1`, `releases/0`** — wrappers
  over `:release_handler`, with the target version's configuration materialised
  before `install` and `commit` hand it over, the record check inside `unpack`
  and `install`, and the ERTS guard inside all of them but `releases/0`.

  **`Castle.install/1` composes nothing, and it used to.** It called
  `Commands.materialise/3` and then `Commands.install/4`, and that composition
  was the bug: two callers both configured the target before either reached the
  lock. Materialising is now the third step *inside* `Commands.install/5`, after
  the record check and after the pending-marker refusal and before the marker is
  armed — so a node that will be refused, for its record or for a pending restart
  install, is refused without having configured anything. The note this replaces
  called materialising "only work" on the grounds that it writes into the target's
  version directory and is idempotent; it ends in a rename onto `sys.config`, so
  it is not. See the restart-marker section for the whole of it.

  **And that claim is now tested at the boundary, which is what
  `Castle.install/2..5` is for.** `install` takes the releases directory, the
  handler, the peer and the deployment as defaulted arguments, exactly as
  `Commands.install/5` does, for one reason: a concurrency test that drives
  `Commands.install/5` cannot see anything composed in `Castle.install/1`, so the
  defect above was reintroducible with the whole suite green. One case in
  `commands_test.exs` runs two concurrent callers through `Castle.install/5`
  instead, and fails if a `materialise/3` reappears in front of the install. The
  arity-1 form is unchanged and is still what `bin/castle` calls over `rpc`;
  nothing about the deployment is chosen by a caller in a release, because nothing
  in a release passes the extra arguments.

  **`Castle.commit/1` composes nothing either, and the asymmetry this used to
  describe is gone.** It said an ERTS-less deployment hears "Cannot configure"
  from `commit` and "Cannot install" from `install`, and that the difference was
  exact rather than untidy. It was exact, and it was also the visible symptom of
  the same composition: `commit` materialised in front of the operation, so the
  configuration step's guard answered first. `Commands.commit/5` now materialises
  inside its own serialised region, so every command names itself.
  `erts_guard_test.exs` pins that in the new direction — a "Cannot configure"
  reappearing there would mean a composition had come back at the boundary.

  Every refusal still falls before `install_release/1` is asked for anything,
  which is the line that matters.
- **`Castle.running/1`** — succeeds when the version it is given is the release
  the system is running. `install_release/1`'s reply says only that the upgrade
  was accepted: a transition that restarts the emulator is replied to and then
  rebooted, and an emulator upgrade finishes on the way back up, where it can
  still roll back. So Castle answers the question and leaves the asking to
  Forecastle: `bin/castle install` repeats it rather than trusting the reply,
  from Forecastle 1.0.0 — so the polling is Forecastle's, and not something
  Castle's own state does. Two conditions. The
  version is the running release: the
  `current` one, or the `permanent` one when none is current — `install` leaves
  its target `current` and `commit` promotes it, so both count; `unpacked` (a
  rolled-back continuation) and `tmp_current` (written before the reboot) do
  not. And its boot has finished, which is `:init.get_status/0`'s *provided*
  status being `:started`. Do not gate on the internal status: it stays
  `:starting` for the life of a release started by its boot script, so a booted
  node reports `{:starting, :started}`. The provided status is what the script's
  `{progress, _}` instructions move along, and `started` is its last one — after
  the applications have started, and after `new_emulator_upgrade/2` in the
  hybrid script that continues an emulator upgrade. Without that second
  condition a poll can confirm a node that is still booting, and automation
  that commits straight after installing would make a version that cannot boot
  the permanent one.

  A version the launcher booted *provisionally*, after a transition that
  restarted the emulator, arrives here as `current` and needs nothing of its
  own — which is measured rather than assumed.
  `prepare_restart_new_emulator/7` persists it as `tmp_current` before the
  reboot; on the boot that follows, `transform_release/3` writes that back as
  `unpacked` **on disk** while `set_current/2` hands the handler a record in
  which it is `current` **in memory**, because `init:script_id()` names it. So
  the same two conditions answer the same question across a reboot, which is
  what lets `bin/castle install` poll through one.

  The marker is the whole of the evidence, so it inherits whatever the selected
  boot script does with it. `RELEASE_BOOT_SCRIPT` naming a hand-written script
  that never reaches `{progress, started}` will never be confirmed — `install`
  waits and then fails, and the refusal names the progress the node did reach,
  so it is diagnosable and never a false success — and one that emits the marker
  before its applications start defeats the check. Both are documented rather
  than validated: Mix generates the boot scripts and offers no `rel/` template
  for them, so reaching either state takes deliberate work. (An earlier note
  here claimed `systools_make:add_apply_upgrade/2`'s hard match on the trailing
  marker ruled this out. It does not: that builds the hybrid script for an
  emulator upgrade and says nothing about a script an operator supplies.)

- **The restart marker** — `releases/castle-restart-pending`, armed by
  `install/5` before `install_release/1` is asked for anything and cleared on
  every path where the install failed. Forecastle's `env.sh` fragment consumes
  it on the next start and boots the version it names. The two halves are
  useless apart and landed together
  ([#14](https://github.com/ausimian/castle/issues/14) and
  [forecastle#10](https://github.com/ausimian/forecastle/issues/10)).

  **Two files are the evidence, not one, and that is the point of this marker
  existing at all.** `prepare_restart_new_emulator/7` writes
  `releases/new_start_erl.data` *before* the reboot and nothing ever removes it —
  `transform_release/3` reconciles the release *record* and does not touch the
  file — so a preparation that failed after writing it leaves a file naming a
  version that was never installed. On its own that file is not a boot
  instruction. Castle's marker says a reboot was really asked for; the hook
  requires both, and requires them to name one version.

  **Agreeing on a version is not enough, and the first version of this shipped
  believing it was.** Two files that name the same version do not establish that
  one install produced them. The sequence that breaks it has no exotic step in
  it: an attempt to X fails after OTP's file is written, the operator retries X,
  the retry arms a fresh marker beside the stale file, and a manual or hard
  restart *before the retry reaches `install_release/1`* then presents a matching
  pair. The launcher boots X, which nothing installed, and OTP's records call it
  `unpacked` — the node runs one release while `which_releases/0` reports another.
  Back-to-back or concurrent installs broke it the other way, by overwriting and
  disarming each other's marker.

  **So the pair is owned by an install *attempt*, and four things make it so.**
  `unclaimed/3` and `arm/4` are three of them and the order is the protocol; the
  fourth is that there is only ever one caller in the install at all.

  1. **One pending restart install at a time.** A marker already at the path
     refuses the install rather than being adopted or replaced, which is what
     keeps step 2 from clearing the `new_start_erl.data` that attempt's
     preparation wrote. `publish/2` decides it a second time over, by refusing
     rather than replacing.
  2. **OTP's file is cleared before the marker is armed.** That is what closes
     the window above: after it, `new_start_erl.data` existing means *this*
     attempt's preparation wrote it. Removing it is safe —
     `write_new_start_erl/3` goes through `file:write_file/2`, which creates the
     file when it is absent. The order matters and must not be reversed: an
     attempt that refused *after* clearing would take an already-requested
     reboot away silently.
  3. **The marker names the attempt that armed it**, on a second line, and
     `disarm/3` removes it only if it still does. The marker's name is shared and
     the marker is short-lived — *any* `start` or `daemon` of the deployment
     consumes it, whether or not that start goes on to boot — so removing it by
     name would take a later attempt's marker away. The attempt is the operating
     system pid, the wall clock in nanoseconds and a serial: unique within a node
     and across its restarts, which is as far as ownership has to reach, because
     the marker never outlives the next start. It is not a secret and does not
     need to be — anything able to forge it can write in the releases directory,
     where it could write the marker itself. What it defends against is
     confusion, not forgery. **The hook never reads it**: the version is the
     first line, which is what `head -n 1` gives it, so the file carries this
     without the shell parsing anything it did not before.
  4. **One caller in the install at a time**, which is `Castle.Commands.serialised/2`
     and the whole of what makes the first three mean anything across processes.

  **Steps 1 to 3 are one caller's sequence, and the first version of this
  believed that `release_handler` serialising `install_release/1` was enough to
  make them a protocol. It is not: that serialisation is *downstream* of all of
  them.** Two callers both read the running release, both classify it and both
  pass step 1, because none of that has published anything yet. Step 1 reversed
  with step 2 is then no protection at all — the loser reaches step 2 *after* the
  winner's `install_release/1` has written `new_start_erl.data`, deletes it, and
  the winner's reboot comes back on the permanent release while the loser reports
  that nothing has been changed. An operator sees a timeout and a false
  reassurance.

  **Do not answer this by reordering the protocol.** Publishing before clearing
  leaves a window in which the marker pairs with a *stale* `new_start_erl.data`,
  and the hook then boots a version nothing installed — which is worse than
  losing a reboot, and is what step 2's position exists to prevent. The order is
  right for one caller; the fix is that there is one caller.

  **The serialised region is the whole install, not just the arming**, because the
  classification is a prediction about the running release: an install that
  completes between `restart_planned?/3` and `install_release/1` moves the
  from-version, so `do_get_rh_script/4` evaluates a different relup entry and the
  armed state disagrees with the transition OTP selects. So the running-release
  read, the classification, the arming, `install_release/1` and the disarming are
  all inside it. The ERTS guard is the one part deliberately outside — it reads
  two directories and refuses without touching anything, and a refusal has no
  reason to wait.

  **It is `:global.trans/3` over `[node()]`, and the mechanism was chosen rather
  than assumed.** `global_name_server` is a kernel process running whether or not
  distribution is, and `set_lock/2` restricted to `[node()]` talks to the local
  one only — so this works on a node with `is_alive() == false`, which is the
  ordinary case for a release that configures no distribution, and is the case it
  was measured on. `trans/3` releases the lock in an `after` and `global` monitors
  the holder besides, so a caller that dies releases it instead of wedging every
  later install; retries are `infinity`, so there is no `aborted` to have to mean
  something by. The alternative was a process of Castle's own, and it is a worse
  trade: these modules are deliberately stateless and run inline in whatever
  process asked, so a lock server would be a new entry in the *managed* system's
  supervision tree, with a lifetime and a restart strategy, to serialise a command
  that runs a handful of times in a deployment's life.

  `[node()]` rather than the default `[node() | nodes()]` because every caller
  arrives on the running node — `bin/castle` is `rpc`, and the launcher's preboot
  only calls `make_releases/0` — so this node is the whole set of callers. A
  cluster-wide lock would make an install wait on nodes that share nothing with
  the deployment, and make a network partition its business, and it still would
  not cover a caller in some other VM. **That is the boundary and it should be
  said plainly:** a second VM writing into this releases directory is outside the
  lock, and what defends the marker there is the filesystem half alone —
  `publish/2` refusing rather than replacing — which is no worse than before and
  no better. It waits rather than refusing, and the waiter then meets step 1 and
  is told a restart install is pending: the same message as before, said about a
  pair that is complete instead of said while taking half of it away.

  **`install` and `commit` take it; `unpack` and `remove` do not.** Those two arm
  nothing and hold no two-file invariant of their own, and `release_handler`
  serialising its own record writes is the whole of what they need.

  `commit` was left out at first, on the argument that putting it behind an
  install "waiting on a reboot" would be a deadlock dressed as caution. **That
  was wrong, and the error was about when the lock is held rather than about
  commit.** An install never holds it across a reboot: `install_release/1`
  replies *before* `init:reboot()`, the reboot runs in `release_handler`'s own
  process, so `Commands.install/5` returns and its `trans` releases while the
  system is still up — and after a restart transition the VM that held the lock
  is gone entirely. `bin/castle install` then polls `Castle.running/1` over
  separate rpcs that take no lock at all. The only thing a commit can wait for is
  a *hot* install still inside `install_release/1`, and waiting there is correct:
  committing part-way through an upgrade is the thing not to do.

  What the omission left open was reachable and is the failure this protocol
  exists to prevent. A duplicate install of the version being committed
  materialises between `commit`'s two steps; the commit succeeds; that install
  then fails as already installed; and *its* configuration is what the newly
  permanent release boots on the next restart. A failed caller deciding what a
  successful one boots, through the one operation left outside the region.

  **Materialising the target's configuration is inside the region, and the
  argument for keeping it outside was wrong.** That argument was: it writes only
  into the target's own version directory, its own primitives refuse rather than
  replace, and holding this lock across a peer VM's boot would put every install
  behind another's configuration step. The middle claim is false about the step
  that matters. The staging refuses rather than replaces and
  `sys.config.pristine` refuses rather than replaces, but the *last* thing
  materialising does is rename the resolved configuration onto `sys.config` — a
  replace by design, and necessarily so, because that is the file
  `release_handler` reads. So two callers materialising before either reached the
  lock meant the loser's providers could replace the configuration the winner's
  provisional release was about to boot, and the loser was then refused for the
  winner's marker: a refused install decided what a successful one booted. That
  providers may answer differently across evaluations is not a hypothetical — it
  is the entire reason `sys.config.pristine` exists.

  The third claim is true and is not a reason. It is a throughput argument about
  concurrent installs, and this protocol refuses concurrent installs anyway; an
  install that waits is slow, and an install whose configuration is somebody
  else's is wrong.

  **Inside the region is not enough on its own — it has to be after the
  refusals.** `Commands.install_upgradable/5` runs the record check, then
  `unclaimed/3`, then materialises, then arms. A caller refused for a pending
  restart install must be refused *before* it configures anything, because the
  version it would be configuring is the one the pending install's reboot is
  about to boot. Moving the materialisation inside the lock while leaving it in
  front of `unclaimed/3` fixes nothing, and there is a test whose only job is to
  fail against exactly that arrangement.

  **`commit` materialises inside the same region, and the argument for leaving it
  outside was wrong twice over.** It went: commit is not the same case, because it
  makes permanent a version this node already installed and is running, so there
  is no marker, no reboot and no window between a configuration and a boot of it —
  and putting it behind the install lock would be the deadlock above anyway.

  The first half is true and does not license the second. The window is not
  between a configuration and a *boot*; it is between commit's own two steps. A
  duplicate install of the version being committed materialises there, the commit
  succeeds, that install fails as already installed, and its configuration is what
  the newly permanent release boots on the next restart. And the deadlock does not
  exist — see above: an install never holds this lock across a reboot, so the only
  thing commit can wait for is a hot install mid-`install_release/1`, which is
  exactly when it should wait.

  So `Commands.commit/5` takes `rel_dir` and materialises inside `serialised/2`,
  the way `install` does, and `Castle.commit/1` composes nothing. The two renames
  onto one `sys.config` are now ordered wherever they meet.

  **It is published the way `sys.config.pristine` is** — staged in an owner-only
  working directory and hard-linked into place — and for the same two reasons a
  link was chosen there. A link publishes a file that is already complete, so no
  start can read a marker that is empty or half written; and it refuses rather
  than replaces, so the loser of a race is told instead of silently taking the
  marker over. An exclusive create in place has neither property: it makes
  *creation* atomic and leaves the file empty between the open and the write, and
  a death in that window leaves an empty marker that blocks every later attempt.
  `Castle.Commands` therefore calls `Castle.Peer.work_dir/1`,
  `write_private/2` and `publish/2` **directly**, not through the injected module
  `materialise/3` uses: those start no VM, there is nothing about them a stub
  could stand for, and the guarantee is the point.

  Consuming them is Forecastle's, and what is atomic there is the *claim*: the
  pending marker is taken by rename, so exactly one start can act on the pair,
  and OTP's file is then read and removed separately. The two removals are not
  one operation and cannot be made one — no POSIX call renames two files
  together. What that costs is bounded by the order: the marker goes first, so an
  interruption anywhere after it leaves no marker and the next start boots the
  permanent version. The selection is lost, never duplicated, and never applied
  to a version nothing installed. Do not write that both are consumed
  atomically: this note said it, Forecastle's `AGENTS.md` said it, and
  Forecastle's release note said it, and it was false in all three.

  **It is armed from the relup, and it has to be, because the reply cannot answer
  the question.** `restart_emulator` is replied to with `{ok, Vsn, Descr}` —
  exactly what a completed hot upgrade replies — and `init:reboot()` has already
  been called by the time the reply arrives. So a marker armed unconditionally
  and cleared on `{ok, ...}` would be racing a shutdown, and losing that race
  loses the upgrade silently. `restart_planned?/3` therefore reads the same file
  `release_handler` will read: `do_get_rh_script/4` looks for the from-version in
  the target's own relup and then for the to-version in the from-release's
  downgrade section, and the from-version is the release the system is running,
  which is what `get_latest_release/1` selects and what `running_release/1`
  already computes. **`which_releases/0` is asked once** and the answer used for
  both the record check and this, for the reason the record check lives inside
  the operation: two calls are two moments.

  This is a prediction and not a second state machine. Nothing here writes a
  release record, and it decides exactly one thing — whether to arm. Being wrong
  either way is bounded: unarmed, the reboot returns on the permanent version and
  `install` reports that the version never became the running one; armed without
  a reboot, the hook consumes the marker on the next start and finds nothing to
  correlate it with.

  **The two-stage `restart_new_emulator` is deliberately not armed for**, and the
  reason is not that it is out of scope. The marker OTP writes for it names the
  *temporary hybrid* release, `__new_emulator__<current>`, and
  `new_emulator_make_hybrid_boot/6` gives that version directory a `start.boot`
  and a `sys.config` and none of the launcher's own furniture — no `env.sh`, no
  `elixir`, no `vm.args`. There is nothing there for a launcher to boot, so
  arming would point it at a version it cannot start. It is told apart the way
  `do_install_release/3` tells them apart: the instruction at the *head* of the
  script. Anywhere else it is an error rather than a transition —
  `syntax_check_script/1` accepts only `restart_emulator` after the point of no
  return.

  **A marker that cannot be armed refuses the install**, before
  `install_release/1` is asked for anything, and so does a stale
  `new_start_erl.data` that cannot be cleared — because the alternative in both
  cases is a reboot that comes back on the wrong version with nothing saying so.

  **Settling the marker afterwards happens on every way out, including the ones
  that do not return, and failing to settle it is reported.** Both halves of that
  replaced something weaker.

  The region is `Commands.installed/5`, and it is an *implicit* `try` — the
  function body, with `catch` and `else` clauses, which is the form
  `credo --strict` asks for. It used to be a bare `case` over the reply with
  `disarm` in the two failing branches, so an exit, a throw or a raise out of
  `install_release/1` went past both: the marker stayed armed, and where
  `prepare_restart_new_emulator/7` had already written `new_start_erl.data` the
  pair was complete and the next start booted a version whose install had blown
  up. That is the hazard the whole protocol exists to prevent, reintroduced
  through the one path that is not a return. It is `catch`/`else` and **not**
  `after`: an `after` cannot see which way the block went, so it would disarm the
  successful restart install too, taking away the marker whose entire purpose is
  to outlive the call. There is a test for that.

  An exception is re-raised unchanged once the marker is settled — `Castle` is
  the boundary that raises, `Kernel.CLI` catches on the node and the calling VM
  re-raises, and Castle has nothing to add to an exception out of
  `release_handler` that is worth losing the stacktrace for. The one exception to
  that is a marker it could not settle, where the exception is folded into the
  message instead, because that is the fact an operator most needs and a
  stacktrace is where it would be buried.

  Clearing the marker used to be best-effort on the argument that a releases
  directory the marker cannot be removed from is one it could not have been
  linked into, so the install would already have refused. **That holds only if
  nothing changed in between, and `install_release/1` runs in between** — for as
  long as an upgrade takes, with the system's own code being replaced. Worse, an
  *unreadable* marker was classified as another attempt's and left alone, which
  reads as caution and is not: a marker that cannot be read is no evidence about
  whose it is, and the file it might be is the one the next start acts on.

  So `disarm/3` has four answers and two of them are failures. **Ours** is
  removed, and a removal that fails is reported. **Theirs** is left, which is a
  success — a later attempt's marker is a reboot still owed. **Gone** is a start
  of the deployment having consumed it, which is the outcome that was wanted, so
  `:enoent` from either the read or the removal is success. **Unverifiable** is
  reported: Castle will not remove a marker it cannot show is its own, and will
  not pretend the question was answered. What the operator is told names the
  file, says `new_start_erl.data` may already be beside it, says that an ordinary
  restart will therefore boot the version the install did not finish, and asks
  for the marker to be removed before the system is restarted.

  The read and the removal go through `Castle.Deployment.read/1` and `rm/1`, for
  the reason `stat/1` is there: the answers that decide what Castle *says* are
  the failing ones, and every fixture that makes a `read` or `rm` fail on a
  regular file in a writable directory does it with a mode, which root and some
  filesystems ignore — so the fixture would only sometimes describe the state it
  names and would pass either way. That seam is for outcomes Castle has to speak
  about and cannot cause; it is **not** a general filesystem seam, and the
  primitives that *publish* the marker stay called directly for the reason given
  above.

  **The report changes with it.** `reported/5` says the version was installed,
  that the emulator is restarting, and that the version stays provisional until
  it is committed — instead of "Now running", which is false for as long as the
  reboot takes and which automation reads.

Every one of them is a command entry point, so `Castle` is the command
boundary: an operation that fails raises there, which is what leaves a non-zero
exit status behind for the shell that asked for it. Raising, not halting — the
expression runs on the *running* node, so halting would take down the system
under management; `Kernel.CLI` catches on the node and re-raises in the calling
VM, and only that VM exits. `Castle.Commands` holds the operations themselves,
returning their outcome instead of acting on the process, which is what makes
them testable.

**`Castle.Error` is what `report!/1` raises, and it is not everything a command
raises.** `report!/1` turns a returned `{:error, message}` into one; an
exception, a throw or an exit that the operation did not handle goes straight
past it. That is deliberate for the one place it can happen on purpose —
`installed/5` settles the marker and re-raises `install_release/1`'s failure
unchanged, folding it into a message only where the marker could not be settled
— so anything claiming that a failed command raises `Castle.Error`, in a `@doc`
or here, has to say which failures. Automation told to rescue `Castle.Error`
and nothing else would treat a `release_handler` that blew up as a success.

`Castle.customize/1` is the one function in that module which is *not* one of
them — it runs at build time, in a consumer's `mix.exs`, and returns a value
rather than reporting an outcome. See **Release integration** below. Anything
that says "every function in `Castle`" has to say "but `customize/1`", and the
comment at the head of `lib/castle.ex` does.

**What is published and what is hidden follows from that, and is
[#11](https://github.com/ausimian/castle/issues/11)'s decision.** The whole of
`Castle` now carries `@doc` and `@spec`, and the `@moduledoc` says the two
things a reader has to know before calling any of it: that this is the runtime
half of a pair, and that these are commands rather than an API — a command
prints its report and returns `:ok`, so the return value carries nothing, and a
refusal raises `Castle.Error` rather than returning `{:error, _}`. Every command
`@doc` names the `bin/castle` command that reaches it, because that is the
interface and the function is the thing behind it.

**Say "a refusal", not "a failure", and the distinction is the one drawn just
above.** `report!/1` turns a returned `{:error, message}` into `Castle.Error`,
and that covers every refusal these commands make deliberately — but
`installed/5` re-raises an exception, a throw or an exit out of
`install_release/1` unchanged once the marker is settled, and anything a
dependency raises comes through as itself. So automation that rescues
`Castle.Error` alone misses a command that blew up rather than refused. This
paragraph exists because the blanket version of the claim was written here in
the same commit that corrected it in the `@moduledoc`, three paragraphs apart.

Two decisions inside that. `make_releases/0` is `@doc false`: its only caller is
the launcher's `env.sh` fragment, in the preboot VM of a `start` or `daemon`
whose deployment has no `RELEASES` yet, and by hand it either does nothing (the
file is there) or does what the next start would do anyway. Its contract is with
a shell fragment in another project, so publishing it would document a function
nobody should call. It keeps its `@spec` regardless — the spec is the contract
whether or not the function is published. And `install/2..5` is documented as
what it is, a seam the concurrency test drives: one `@doc` covers every arity of
a clause with defaults, so saying nothing about the extra four would leave them
reading as an API. Every other function is a command an operator invokes, and
hiding one of those would document nothing useful anywhere.

The specs say `:: :ok` and nothing more, because that is what `report!/1`
returns; a spec naming the lines, or an error tuple, would be describing
`Castle.Commands`. Nothing checks them — there is no Dialyzer here — so they are
kept by hand, and a claim in a `@doc` about what a command refuses is worth
checking against `Castle.Commands` before it is trusted.

**A definition with defaults needs one `@spec` per arity, and "every public
function carries a spec" is a claim about arities.** `install/1..5` is five
functions and therefore five specs; the first version of this carried two, for
`install/1` and `install/5`, and left three unspecced while this file and
`RELEASE.md` both said the surface was complete. Nothing catches that, and
`mix docs` is no help either: ExDoc renders one spec against a defaulted
definition, the widest arity's, so the page looks the same with two specs as
with five. `credo --strict` passes, and there is no Dialyzer. So check it with
`Code.Typespec.fetch_specs(Castle)` and count — against
`Castle.__info__(:functions)`, which is the list that has to be covered —
rather than by reading the source, which is what missed three of them.

**The `@doc`s are claims, nothing checks them, and the first draft of them
walked back into two rules this file had already settled.** Both are worth
naming, because both were regressions rather than staleness:

  * `upgradable/0`'s said the record is synthesised when the system started
    "without a `releases/RELEASES` file it could read" — which is the
    *readable* phrasing corrected above, admitting the malformed-terms
    counterexample, and it named the file unqualified besides. A `@doc` that
    describes a refusal has to say what the refusal says: name the authority
    (the file `:release_handler` accepts, no single property of it being the
    test), and qualify the path with `RELDIR` and `{sasl, releases_dir}`.
  * `commit/1`'s said that committing an already-permanent version "succeeds
    and changes nothing", which was true of the shape castle#14 replaced.
    `Commands.commit/5` materialises inside its own serialised region, so the
    target's `sys.config` is rewritten from current provider inputs before
    `make_permanent/1` — which is itself a no-op for that version — is called
    at all. OTP's step being idempotent is not the command being idempotent.

Three more were ordinary staleness of the same kind, and the pattern is that a
`@doc` describing a *sequence* goes stale where a `@doc` describing a value
does not: `install/1`'s claimed two steps before `:release_handler` was asked
for anything, when `install_upgradable/5` asks `which_releases/0` first and
refuses for a pending marker in between, and the line that matters is
`install_release/1` rather than any handler call; the rollback an install
leaves was described as "anything that takes the system down brings that one
back", which is false for the one reboot a restart install has already asked
for and the launcher is holding a marker to carry out; and `unpacked` was
glossed as "staged and never installed", which `running/1`'s own `@doc`
already contradicts. `bin/castle commit`'s argumentless form was described as
defaulting to "the version running now", where `castle.sh.eex` selects a
`:current` release and exits non-zero when there is none.

So: read a `@doc` about a sequence against the function that implements the
sequence, not against the module's summary of it, and read one about
`bin/castle` against Forecastle's `priv/castle.sh.eex`.

Forecastle is what arranges for these to be reachable: it leaves the
configuration Mix wrote alone, adds a `:preboot` script that starts `:castle`,
and writes the `env.sh` fragment and `bin/castle` wrapper that call into this
module.

## Release integration

`Castle.customize/1` is the public integration point, and the whole of it: a
consumer's `mix.exs` names `Castle` and nothing else
([#12](https://github.com/ausimian/castle/issues/12)). It takes `mix release`
options and returns `mix release` options with the build-time steps spliced
around `:assemble`. It lives in `Castle` rather than in a module of its own for
that same reason.

**The splice is `Forecastle.steps/1`, and there must not be a second
implementation of it here.** That function finds `:assemble`, puts
`pre_assemble/1` before it and `post_assemble/1` after it, keeps whatever
surrounded them in the order it was given, and returns a list with no
`:assemble` untouched. `customize/1` is `Keyword.update/4` over `:steps` with
that as the function and nothing else. Forecastle's own release fixture stays on
the explicit `pre_assemble`/`post_assemble` steps deliberately: Forecastle has
to be testable without Castle's API, so do not "tidy" it onto `customize/1`.

**The lazy `fn -> … end` release form is required rather than preferred, and the
`@doc` says so.** Mix evaluates `mix.exs` on every load of the project, the
`mix deps.get` and `mix deps.compile` runs included, so a `Castle.customize/1`
written outside a function is a call to a module that has not been built yet.
`Mix.Release.find_release/2` calls a 0-arity release option function only when a
release is being built (`opts = if is_function(opts_fun_or_list, 0), do:
opts_fun_or_list.()`), by which point every dependency is compiled — which is
also what makes `Forecastle` loadable from here despite being `runtime: false`.

**`:steps` defaults to `[:assemble, :tar]`, and Mix's own default is
`[:assemble]`.** `Mix.Release.from_config!/4` is
`Keyword.pop(opts, :steps, [:assemble])`, so a release that says nothing gets no
tarball — and `Castle.unpack/1` reaches `:release_handler.unpack_release/1`,
which reads `releases/<name>-<vsn>.tar.gz`. A version assembled without `:tar`
can never be handed to a running deployment, and handing versions to running
deployments is the whole of what Castle is for, so the default carries `:tar`.
It is written out in `@default_steps` rather than taken from
`Forecastle.steps/1`'s own default, so that what the `@doc` claims is a claim
about this module's code.

**A `:steps` list that *is* given without `:tar` is honoured, with a warning at
the build. Refusing it, or adding `:tar` back, would be wrong — and this is the
part a future reader will otherwise re-derive incorrectly.** The reason is that
*the deployment an upgrade is installed onto needs no tarball of its own.*
`unpack` reads the tarball of the version being installed, never of the version
running, so a base deployment shipped as a directory — a container image, most
obviously — is a perfectly good Castle deployment built with
`steps: [:assemble]`, and refusing it would refuse a working configuration.
`:tar` is also only Mix's own way of packing one — `make_tar/1`, private to
`Mix.Tasks.Release` and so not callable — and a function step in the project's
list can pack a tarball itself, so the absence of the atom is not the absence of
a tarball. What `customize/1` knows is that the atom is not in the
list; that is what the warning says, and it says nothing further — the same rule
as the ERTS guard's message, which states the divergence and asserts no cause.

Honouring it *silently* was the third option and is the one to keep rejecting.
The cost is invisible until an operator meets it as a `bin/castle unpack` that
cannot find a file, and that failure names a missing tarball rather than the
release option that did not ask for one. The warning goes through
`Mix.shell().error/1`, which is what Forecastle's own Windows warning uses. That
is a reference to `Mix` from a module that ships inside the release, which is
sound because the branch only ever runs at build time, where Mix is by
definition loaded; nothing at runtime reaches it.

**Nothing is said about a list with no `:assemble`, and nothing should be.**
`Mix.Release.validate_steps!/1` requires exactly one, refuses the release and
names the option, and `Forecastle.steps/1` returns such a list untouched so that
refusal can happen. A `:steps` value that is not a list is handed back for the
same reason: `Forecastle.steps/1` guards on `is_list/1`, and a
`FunctionClauseError` out of it would name a module the project never mentioned,
which is precisely what `customize/1` exists to prevent. Mix validates `:steps`
*after* the lazy release function has been called — `find_release/2`, then
`from_config!/4` — so its refusal is always downstream of this.

**It changes exactly one option.** What a consumer still has to declare by hand
is listed in the `@doc`, because the alternative is finding out from a failed
upgrade: the `:appup` project key with `compilers: Mix.compilers() ++ [:appup]`,
a relup from `mix forecastle.relup` left in the project root, and
`include_executables_for: [:unix]` — Windows is unsupported and assembly only
warns — plus the optional `rel/env.sh.eex`. `:steps` is the one option whose
contents are Castle's business; the others are the project's own choices, and
one Castle set silently would be one a consumer could not see in their own
`mix.exs`.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/castle.ex` | The command boundary: print the outcome, or raise — plus `customize/1`, the build-time release integration, which is not a command |
| `lib/castle/commands.ex` | The commands themselves, returning their outcome |
| `lib/castle/deployment.ex` | The facts about the deployment Castle cannot arrange and a test cannot produce: the two roots, and the `stat`/`read`/`rm` whose *failures* decide what a refusal says |
| `lib/castle/peer.ex` | The temporary VM that runs the target's own config providers, both sides of it |
| `lib/castle/error.ex` | The exception a failed command raises |
| `test/support/` | Stubs for `:release_handler`, `:init`, the peer, the deployment and config providers, plus the release-shaped tree a real peer is booted on |

## Working on this project

- Run `mix precommit` before committing. It is the single validation gate —
  `compile --warnings-as-errors`, `deps.unlock --unused`, `format`,
  `credo --strict`, `test`. Do not run the individual checks piecemeal.
- `@version` in `mix.exs` is the single source of truth for the version.
- Add user-visible changes to `RELEASE.md` on the feature branch, using
  [Keep a Changelog](https://keepachangelog.com/) sections. Do not defer release
  notes to release time, and exclude internal CI/lint churn.
- Release with `mix publisho <patch|minor|major>`, which bumps `@version`, folds
  `RELEASE.md` into `CHANGELOG.md` at the `<!-- %% CHANGELOG_ENTRIES %% -->`
  placeholder, commits and tags. Tags are bare semver — no `v` prefix. Pushing
  a tag triggers `.github/workflows/publish.yml`, which publishes to Hex.
- Never commit directly to `main`; work on a feature branch and open a PR.

## Tests

`mix test` covers `Castle.Commands` as units. `:release_handler`, `:init`,
`Castle.Peer` and `Castle.Deployment` are reached through module arguments that
default to them, so the tests hand them `Castle.ReleaseHandlerStub`,
`Castle.InitStub`, `Castle.PeerStub` and `Castle.DeploymentStub` instead;
`materialise/3` takes the version directory it works on and `make_releases/3` the
releases directory, so the tests give them a `tmp_dir` — and neither the commands
nor their tests touch the working directory, which is what lets them all run
async.

Only the cases *about* a synthetic root pass `Castle.DeploymentStub`. Every case
that predates the guard omits the argument and so runs against the real
`Castle.Deployment` — which is worth knowing rather than tidying, because under
`mix test` there is no `RELEASE_ROOT` and that is exactly the inert state: those
cases are the standing evidence that the guard lets an ordinary caller through,
and they would fail if it stopped being inert.
`test/castle_test.exs` drives the boundary itself against the real
`:release_handler` — which is running under `mix test`, because castle depends
on sasl — and the real `:init`, naming releases that do not exist. One test
there is not about the boundary: the record check rests on a claim about OTP's
own data, that a record read from a `RELEASES` file names applications, so it is
asserted against the record the real `:release_handler` read from the OTP
installation's own file rather than against a stub. It fails, loudly and with
the reason visible, on an installation that has no `releases/RELEASES` — and so
does the boundary's `unpack/1` test, now that `unpack` makes the same check.

The record check's discriminators are about *ordering*, so they are written the
way `materialise/3`'s are: the stub is given a reply that would have the
operation succeed, and the assertion is that it was never asked for it —
`Stub.calls(:unpack_release) == []`, `Stub.calls(:install_release) == []`. An
end-state test cannot tell a refusal that came first from one that came after,
because the refusal is the same either way. Two more assert
`Stub.calls(:which_releases) == [[]]` on the successful path: the check happened
*in* the call that acted, which is the whole of what this fixed, and a version
that asked it somewhere else would pass every other assertion here.
`commit/3`'s regression guard is the mirror image — a synthesised record, and
`Stub.calls(:which_releases) == []`, because commit must *not* acquire the check.

The ERTS guard's tests are written the same way, and they have the same
difficulty in a sharper form: the guard is inert without a `RELEASE_ROOT`, and
`mix test` starts with none — so the state it exists to refuse has to be arranged
deliberately, either by substituting the roots or, in the boundary suite, by
putting the variable in the environment. `Castle.DeploymentStub` answers the two
roots and the `stat` and nothing else — the comparison, the normalisation and the
message stay in `Castle.Commands` and run for real — which is the same division
as stubbing `which_releases/0` and letting the record rule run.

The `stat` is stubbed for one reason: two of the three answers cannot be produced
by a fixture. An `:eacces` needs a mode that root and some filesystems ignore,
and a zero inode needs a filesystem reporting no inode numbers. A fixture that
only sometimes produces its state is a test that only sometimes tests anything,
and the first attempt here proved it — it built a 0000 parent, branched on
whether the refusal mentioned `:eacces`, and so passed by printing "skipped" on
any runner where the mode did not bite, including against the regression it
named. Unstubbed, `stat/1` is the real one, so a test that only cares about the
roots does not have to describe the filesystem.
Each gated operation is given a handler primed to succeed and asserted never to
have been asked (`Stub.calls(:remove_release) == []`), and `unpack` and `install`
also assert `Stub.calls(:which_releases) == []`, because on such a deployment the
record check is asking about the Erlang installation and would have nothing to
say: the refusal has to name the reason that is true. `make_releases/3` has a
test of its own for the ordering against `File.exists?`, since an Erlang
installation has a `releases/RELEASES` and looking first would report success.

`test/castle/erts_guard_test.exs` is the other half, and it is `async: false`
because it puts `RELEASE_ROOT` in the environment and the environment is the
node's. It drives the boundary through the real `Castle.Deployment`, so what it
establishes is that the shipping module reads that variable — not that a launcher
exports it, which is a fact about the script `mix release` generates and is not
something a `System.put_env/2` can witness. Every gated command raises,
`upgradable/0` and `releases/0` still answer, and with `RELEASE_ROOT` set to
`code:root_dir()` — or absent — `remove/1` reaches the real `:release_handler`
and is refused for the release not existing, which is how the inert case is told
from the gated one.

One test there asserts the refusal's **entire text** rather than fragments of it.
That is deliberate and it should stay that way: the defect being guarded is a
*categorical claim* about the cause, and no set of refutations forbids one —
"This is caused by include_erts: false" refutes clean against every phrasing this
message has previously been wrong in, while keeping every word a fragment-based
test would require. Only the whole string pins it, and rewording the message on
purpose should mean editing that assertion on purpose.

`test/castle/peer_test.exs` is the exception: it starts real peers. Stubbing the
peer would prove nothing about the one thing it exists to do, which is to run a
release's *own* code. `Castle.SyntheticRelease` lays out a directory tree with
everything `Castle.Peer` needs — an emulator launcher under `erts-<vsn>/bin`,
applications under `lib/<app>-<vsn>`, a `systools` boot script over them, a
release file and a `sys.config` — so a peer boots on the same kind of script a
release ships, without a `mix release`. The test that matters most compiles two
versions of one provider module, loads one into the node running the tests and
puts the other on the peer's code path, and asserts that the answer came from
the peer's. Peer cleanup is asserted from outside: a provider records the
operating system pid of the VM it ran in, and the test waits for it to go.

It builds the **unpacked** shape by default, and the assembled one only when a
test asks for it — because the peer path is reached from `install` and `commit`,
so every version it is asked to configure was unpacked from a tarball. The two
shapes differ in the version directory's release files: Mix assembles one,
`<name>.rel`, while unpacking leaves two, that one plus the `<name>-<vsn>.rel`
`release_handler` copies in beside it. A fixture that only built the assembled
shape is how `Castle.Peer` came to refuse every unpacked release as ambiguous,
having been reviewed seven times against a directory the peer path never meets.

`Castle.Peer.materialise/2` takes `:boot_timeout` and `:resolve_timeout` for the
same reason `Castle.Commands` takes the module to talk to — a deadline nothing
can shorten is a deadline no test can show is enforced. Two tests give it a
second and assert that the refusal names it, which is what keeps the deadlines
from being a claim in a comment.

Idempotence is asserted against a control rather than against a hard-coded
expectation: two versions of the same release are built in one root, sharing a
`runtime.exs` so that the state the providers carry is identical, one is
materialised twice with the environment changing in between — install, then
commit — and the other once with the environment as it ended up. The two
`sys.config` terms have to be equal. That is why `Castle.SyntheticRelease` makes
its symlinks idempotently: a root has to be able to hold two versions.

`Castle.Peer.work_dir/1`, `secure_dir/1`, `write_like/3`, `write_private/2`,
`create_exclusive/1`, `fill/3` and `publish/2` are public for the same kind of
reason: what they guarantee is about *intermediate* states, and a window nothing
can stand in is a window nothing can test. One test takes `work_dir/1`,
`write_like/3` and `publish/2` one at a time and looks at the destination in
between — where it finds no file, rather than a partial one — then checks that
publishing again is refused rather than allowed to replace. Another calls
`work_dir/1` and finds the directory at 0700 and still empty. Call sites use
`write_private/2`; `create_exclusive/1` and `fill/3` are public only so that the
window between them can be stood in, and never to be called in sequence by
anything else.

`fill/3` being separable is what lets a test swap the name between the exclusive
open and the write, and assert that the content reached the inode that was
created while the file the name now points at never saw it — with that same test
asserting the acknowledged cost, that the by-path `chmod` does land on the
swapped name. With the name left alone the two behaviours are identical, so
there is no other way to tell them apart.

`secure_dir/1` is public so that the `mkdir`-to-`chmod` window can be stood in:
a test creates a directory at 0777, plants a `sys.config` symlink inside it, and
asserts that securing it is refused, the directory removed and what the symlink
pointed at untouched. That is the only way to observe it — nothing about the end
state distinguishes a directory that was empty when it was narrowed from one that
was not, which is what made the same mistake possible a sixth time at the
directory after five at the file. A companion test plants a name inside an
already-private directory and asserts `write_private/2` refuses it rather than
writing through it, which is the half a private directory does not cover.

Those have to be written that way. The mode a file *ends up* with is the same
whether it was set before or after the content, so a test of the end state
passes either way — which is how the exposure survived two rounds of review that
had already identified the class. The in-peer observation of the scratch file's
mode is a regression guard on the site that was wrong, not a discriminator: it
passes against a version that had the window too.

What *is* a discriminator, and what makes the exposure unreachable rather than
merely narrow, is the in-peer walk of the version directory taken while both
files exist and both hold configuration: the only thing Castle has put there is
one directory at 0700, every configuration-bearing file it made is inside that,
and the version directory itself holds nothing of Castle's but the two names it
publishes. Against the version that created those files next to `sys.config`
there is no such directory at all, so the assertion cannot pass by accident.
The other discriminator, and the reason the mode ordering cannot be reversed by
accident either, is the release whose `sys.config` is 0440: it materialises twice
and both files end at 0440, where setting the mode first fails to write the file
at all.

Two of these tests would pass for the wrong reason if written carelessly, so
they are written to fail when what they rest on moves. The compile-environment
test asserts the *refusal*, over provider state built by
`Config.Provider.init/3`: if Elixir stops representing that check as a list of
triples, `init/3` stops producing one, no refusal happens, and the test fails.
It is paired with a release whose check is satisfied, so that "refuses
everything" cannot pass for "checks correctly", and with one carrying a shape
Elixir does not produce, which has to be refused rather than skipped.

The restart marker's tests are written the same way, and the discriminators are
the same kind: `restart_planned?/3` is exercised by writing a real relup where
`release_handler` reads one and asserting on the *file* — armed for a script
carrying `restart_emulator`, from the from-release's downgrade section for a
downgrade, and not armed for a hot script, for `restart_new_emulator` at the
head, or when there is no relup at all. A relup with no entry for the running
version is what makes the downgrade case a genuine second lookup rather than the
first one succeeding by accident. Both arming refusals are arranged by putting a
*directory* where a file has to be — at the marker's name for the one, at
`new_start_erl.data` for the other — which is deterministic and needs no file
modes, since a fixture here may not turn on a mode that root or a filesystem can
ignore. And `Stub.calls(:which_releases) == [[]]` on the successful install is now
load bearing twice over: it says the record check happened in the call that acted,
*and* that the classification did not ask a second time.

**The attempt-ownership tests are about states that only exist while
`install_release/1` is in flight**, so `Castle.ReleaseHandlerStub` accepts a
*function* as a reply and calls it with the arguments. That is the only seam
between the arming and the disarming, and it is what makes three otherwise
unobservable things assertable: a preparation that writes `new_start_erl.data`
and *then* fails, so that a same-version retry can be shown to clear it rather
than pair with it; the filesystem as a hard restart before the reboot would find
it, which is the marker alone and no pair; and a marker replaced between the
arming and the disarming, so that `disarm/3` can be shown to leave a marker it
did not write. None of those has an end state that distinguishes it — a
successful install leaves the marker armed either way, and a failed one leaves it
gone either way — which is the same reason `Castle.Peer`'s primitives are public.
A marker already at the path needs no seam of its own: it is a pending attempt,
and what is asserted is that the install is refused, that `install_release/1` was
never called, and that *neither* the marker nor OTP's file was touched — the
second half being the ordering that keeps a refusal from destroying a pending
attempt's evidence.

**Two real callers do need one, and the seam is `which_releases/0` rather than
`install_release/1`.** The state that used to be reachable is two callers past the
running-release lookup and neither of them armed, so what has to be held open is
the *front* of the serialised region — and the lookup is both the first thing in
it and the last thing before anything is written. So `installer/3` runs
`install/5` in a task of its own with a `which_releases/0` that reports where it
got to and, optionally, waits to be released; a second caller is started while the
first is held there, and the discriminator is that its lookup never happens
(`refute_receive {:looked_up, :second}`). `Task.await` and `assert_receive` carry
generous timeouts because `global`'s lock retry backs off by up to a second or
two, and every stub reply and call record lives in the *task's* process
dictionary, so a caller answers with its own `Stub.calls(:install_release)` and
its own `PeerStub.calls()` rather than the test reading them.

Four of them. The second is the other direction — a failed first install hands the
region on, and the waiter arms its own marker. The third is not about the marker
at all: one relup for 1.2.3 whose transition from 1.2.2 is hot and from 1.2.1
restarts the emulator, installed concurrently by two callers running different
versions. It says the classification belongs to the caller that made it — the
second half of why the region reaches past the arming — and that the hot caller
neither adopts nor disarms the marker the restarting one is waiting on.

**The fourth is about the configuration, and it is the one that needs providers
whose results can be told apart.** `Castle.PeerStub` therefore accepts a
*function* reply, like `Castle.ReleaseHandlerStub` does, so a caller's
materialisation can write a distinguishable `sys.config` into the version
directory — which is what the real one ends by renaming into place. Two callers
are given different ones, the first is held at the lookup and goes on to arm and
"reboot", the second is refused for the pending marker, and the assertions are
that the second's peer was **never called** (`PeerStub.calls() == []`) and that
the target is left holding the first's configuration. With both callers answering
`{:ok, []}` there is nothing to see: the end state is identical whichever of them
ran, which is exactly why the composition survived three rounds of review. Note
what this test fails against, because it is the point of it — not just
materialising outside the lock, but materialising *inside* the lock and in front
of `unclaimed/3`, which is the fix that looks sufficient and is not.

**It is also the one case that runs through `Castle.install/5` rather than
`Commands.install/5`, and that is not a detail.** The defect was a composition in
`Castle.install/1`, so a case that only ever called `Commands.install/5` was
asserting about a function the defect was not in: putting `materialise/3` back in
front of the install left it green. `installer/3` takes `through: :boundary` for
this one, which runs the command boundary — so the two callers are two `rpc`s,
which is what they are in a deployment. The boundary prints what succeeded and
raises what failed, so `invoke/2` puts both back into the shape
`Commands.install/5` returns: `with_io/1` inside the task, because that is whose
group leader has to be swapped, and an implicit-`try` `attempt/1` to turn
`Castle.Error` back into an `{:error, message}`. Every other case here stays on
`Commands.install/5`, which is the right level for a claim about the serialised
region itself.

**The exception path has tests of its own, and the seam is
`Castle.ReleaseHandlerStub`'s function reply again.** A raise, an exit and a
throw out of `install_release/1`, each asserted to leave no marker behind, with
`new_start_erl.data` written first in the raise case so that what survives would
be the complete pair. A fourth asserts the opposite for a *successful* restart
install — the marker stays — which is what forbids `try/after` in place of
`catch`/`else`, since an `after` cannot tell the two apart and no other assertion
here would notice.

**Being unable to settle the marker is reached through `Castle.DeploymentStub`,
not through a mode.** `stub_read/1` and `stub_rm/1` take a reply or a function of
the path, so a refusal can be scoped to the marker alone while everything else the
install touches goes through the real `File`. Unstubbed, both are the real thing,
for the reason `stub_stat/1` is: a fixture that only sometimes turns on the state
it names is a test that only sometimes tests anything. The four cases are a
removal refused with `:eacces`, a read refused with `:eio`, both of those *and* a
raise from `install_release/1` — where the exception has to be folded into the
message rather than let out — and the quiet one, a marker a start of the
deployment consumed, where `:enoent` must not be reported as a failure. That last
one is what keeps the reporting from being noise on an ordinary interrupted
install. The `DeploymentStub` in these is given `nil` for both roots, so the ERTS
guard is inert exactly as it is under `mix test` with no `RELEASE_ROOT`.

Every install case now names a `configured(dir)` — the version directory unpacked
and a peer that says it configured it — because materialising is a step of the
install rather than something composed in front of it. That is deliberate rather
than an inconvenience: a case that did not say what the peer did would not have
said what the version it installed is configured with. The ERTS-guard cases pass
an **unstubbed** `Castle.PeerStub` instead, which raises if it is reached, so
"refuses without starting a peer" is asserted by the guard holding rather than by
a separate look.

`test/castle/customize_test.exs` needs none of that machinery, and should not
acquire any: `customize/1` is a pure function on a keyword list, so there is no
release to build and nothing to stub. Two things about how it is written are
load bearing. **Every assertion is on the whole `:steps` list, in order** — a
case that asked whether `:steps` was present, or whether the two Castle steps
appeared somewhere in it, would pass against a splice that put them the wrong
side of `:assemble`, which is the only way to get the splice wrong. And the
missing-`:tar` decision is pinned in **both** halves: that the list is built as
the project wrote it (no `:tar` appended) and that the warning is emitted, since
a case that only looked for the warning would pass against a `customize/1` that
quietly added one. The warning is observed through `Mix.Shell.Process`, so the
file is `async: false` — Mix's shell is one setting for the whole node — and the
setup restores whatever shell was there. The cases that assert *nothing* was
said depend on that shell just as much as the one that asserts something was,
which is why the whole file is sync rather than those two cases.

What is *not* covered here is a booted release: the upgrade of a running
system, and the exit statuses `bin/castle` returns, belong to Forecastle's
`:e2e` suite ([#8](https://github.com/ausimian/castle/issues/8)), which
exercises this code against a real release and asserts on the success messages
each command prints. Those strings — `Unpacked <vsn> ok`,
`Now running <vsn> (previously <other>).`, `Committed <vsn>. …` and the
`releases/0` table — are a contract with that suite. Failure messages are not,
and neither is what a restart install reports: that message may not outlive the
reboot it announces, so the `:e2e` suite asserts the exit status and the state
the system ends up in and leaves the wording to the unit test here.

The restart transition is covered end to end all the same, in both halves:
Forecastle's `restart_upgrade_test.exs` drives a `--restart` relup through
`unpack`/`install`/`commit` against a real supervised release, asserts the OS pid
changes, kills the provisional release before committing to see it roll back, and
installs again from the release that came back.

It is also what finally covers the interaction between a materialised
`sys.config` and a later cold boot of the same version, which used to be listed
below as unverified. The provisional boot *is* that cold boot: it re-runs the
target's own providers over the materialised file, with `SAMPLE_GREETING` changed
underneath it, and answers with the new value. What lets it is that materialising
leaves no `config_provider_booted` marker behind and preserves the header Mix
wrote, so Elixir's pipeline is still armed in the file the launcher reads.

## Known limitations

- **Nothing in the release restarts it after an emulator restart, and that is
  the design.** `init:reboot()` takes the OS process down, `bin/start` is inert,
  and `HEART_COMMAND` is unset, so the external supervisor is the only thing that
  brings the system back. A deployment started by hand from a shell therefore
  stays down until somebody starts it — and comes back on the installed version
  when they do, because the markers are still waiting. See forecastle#10 for why
  a second restart authority was refused rather than added.
- **A hard kill during a restart install can only lose the reboot, not misapply
  it** — and where the pair survives such a kill, booting the target is right
  rather than tolerated. Which window it lands in decides which:

  Between the arming and `prepare_restart_new_emulator/7`, only the marker
  exists — OTP's file was cleared on the way in — so there is no pair, the next
  start boots the permanent version, and the marker is consumed and discarded.
  After `prepare_restart_new_emulator/7`, both exist, and so does a
  `tmp_current` record for the target: the relup was evaluated in the VM that
  died, the target is unpacked with its configuration materialised, and
  `transform_release/3` will make it `current` on the way up. That is the state
  the reboot was going to produce, so the next start producing it is the
  protocol working. `releases/start_erl.data` still names the previous permanent
  version either way, so nothing is committed by a crash.

  There is still no test that plants the pair by hand, and that is a decision
  rather than an omission. What a planted pair adds is a state OTP's records
  contradict — forging the markers for a version the handler has no
  `tmp_current` for leaves the node running one release while `which_releases/0`
  reports another — so pinning it would pin an incoherence. What *is* pinned is
  the state each window leaves: a unit test observes the filesystem from inside
  `install_release/1` and finds the marker alone, and the restart `:e2e` suite
  covers the far window by killing the provisional release before the commit.
- **Serialising the install is node-local, so a second VM writing into the same
  releases directory is outside it.** `Castle.Commands.serialised/2` locks over
  `[node()]`, which is exact for every caller Castle has — `bin/castle` is `rpc`,
  and the launcher's preboot step calls only `make_releases/0` — but it is a
  statement about callers rather than about the directory. Something else running
  `Castle.install/1` in a VM of its own against the same deployment gets the
  filesystem half of the protocol and nothing more: `publish/2` refuses rather
  than replaces, so the marker cannot be silently taken over, and the window the
  lock closes — two callers both past `unclaimed/3` before either publishes — is
  open again between them. Widening the lock does not fix it; a lock the
  filesystem holds would, at the price of a stale one after a hard kill blocking
  every later install. Nothing is known to do this, and Castle does not detect
  it. It is the one limitation here that a lock cannot narrow, which is why the
  filesystem half of the protocol — `publish/2` refusing rather than replacing —
  has to stand on its own.
- **Nothing checks the `@spec`s.** The public surface is documented as of
  [#11](https://github.com/ausimian/castle/issues/11) — see the end of *What it
  does* for what is published and why — but there is no Dialyzer in this
  project, so a spec that stops describing its function fails nothing. They are
  all `:: :ok` today, which is the whole of what `report!/1` returns, so the way
  one goes wrong is a command that starts returning something else and a spec
  that keeps saying `:ok`. The same holds for what the `@doc`s claim a command
  refuses: `mix docs` catches a broken *reference*, and nothing at all catches a
  true sentence that has stopped being true. Both are read against
  `Castle.Commands` by hand.
- **The README is out of date.** It documents an `:appup` compiler and a
  `mix castle.relup` task that moved to Forecastle in 0.3.0, the release
  management commands it describes on `bin/<release>` now live on `bin/castle`,
  and its integration section still tells a consumer to place
  `Forecastle.pre_assemble/1` and `Forecastle.post_assemble/1` around
  `:assemble` by hand, which is what `Castle.customize/1` replaced
  ([#9](https://github.com/ausimian/castle/issues/9)).
