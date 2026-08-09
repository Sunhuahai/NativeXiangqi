# Pikafish corresponding-source layout

This directory is the fail-closed staging layout for the exact source that corresponds
to a distributed Pikafish helper. T000 intentionally distributes no helper and no
network, so no release source archive is present and the development manifest is not
release eligible.

A future release preparation must place all of the following in one immutable archive:

1. the source tree for tag Pikafish-2026-01-02, commit
   ce0679e00ee196f7ba17f6ec18941b9a5036f8cf;
2. every project patch listed and hashed in patches/manifest.toml;
3. the exact GPL text, AUTHORS, notices, and modification record;
4. an offline rebuild script and the compiler/target/flags from the locked manifest;
5. source archive, helper, and network checksums plus the exact NNUE permission text.

The upstream build command selected from the pinned source's own make help is:

~~~bash
make profile-build ARCH=apple-silicon COMP=clang
~~~

Upstream profile-build depends on its net target. Before invoking it, release tooling
must verify the locked network byte count and SHA-256 and place the file at
src/pikafish.nnue. A release build must run with network access disabled. T050 owns the
actual helper build, smoke test, patches, and corresponding-source archive.
