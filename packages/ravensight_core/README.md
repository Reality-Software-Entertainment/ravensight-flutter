# ravensight_core

The pure Dart core of the Ravensight Flutter SDK, with every platform piece
injected. Games use [`ravensight`](../../README.md), which wires it to
Flutter; this package is published separately so it can be tested with
`dart test` alone.

## Privacy

This package sends nothing by itself: the transport and storage are given
to it. See the `ravensight` README for what the SDK sends and saves.
