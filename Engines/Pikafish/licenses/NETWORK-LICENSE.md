# Pikafish NNUE license evidence

- Engine release: https://github.com/official-pikafish/Pikafish
- Release tag: Pikafish-2026-01-02
- Release asset: Pikafish.2026-01-02.7z (55,332,846 bytes, SHA-256
  84257063905615919fb4ee6a70273a94843bb6ec04c45e3ac706098838bc1a49)
- Locked network: pikafish.nnue inside that archive, 53,212,941 bytes, SHA-256
  c4026370d7516d9b0f668447f9ca1931241538bdc689cde6fec6a991ac4d5f77, network
  version header 0x7AF32F20 (matches the pinned engine's expected header).
- License text: NNUE-LICENSE.md, shipped verbatim inside the release archive
  and preserved in this directory. The same terms are documented upstream in
  https://github.com/official-pikafish/Networks (README.md).
- Verified: 2026-08-09

## Permission analysis

The release's NNUE-LICENSE.md states that any usage of the Pikafish weights
constitutes agreement to this License, and that the weights file (pikafish.nnue)
released with Pikafish and weights further derived from it are:

1. Only for legal use; consequences caused by use beyond the legal scope, such as
   online cheating, are borne by the user.
2. No commercial use without permission.

The upstream text separately identifies a permission list at
https://pikafish.org/list.html. NativeXiangqi has not established that it is on that
list and therefore records commercial_permission = false.

The repository also describes different CC0 terms for weights trained for the
Fairy-Stockfish Xiangqi variant. That statement does not relicense pikafish.nnue.

The complete, unmodified license text shipped with the locked release is preserved
in NNUE-LICENSE.md and is authoritative over this analysis.

## Asset correction record

T000 initially locked the mutable `master-net` asset (51,585,654 bytes, SHA-256
3cd15292bf8c979884262f57fc723959fc0dea43b4d8d544f88db5ceb2479e24, verified
2026-08-09). T050 proved that asset carries network version header 0x6a448afa and
is rejected by the pinned engine (expected 0x7AF32F20), so the lock moved to the
network shipped inside the engine's own release archive. The engine's `uci` smoke,
`isready`, and fixed-FEN search pass only with the corrected asset.
