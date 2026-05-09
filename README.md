# GMDB

A humble (and probably incomplete) Swift port of Gus Mueller's fantastic and venerable [FMDB](https://github.com/ccgus/fmdb). 

## About

GMDB is a Swift wrapper around SQLite, born from implementing the tests in FMDB's `FMDatabaseTests` and adding functionality until most of them passed. If FMDB has served you well over the years, you'll feel (mostly) right at home here — with the caveat that this is very much a work in progress. 

I'm not entirely sure why I did this. I found a version of this halfway completed in my projects folder from last year (2025) and decided to finish it. The original FMDB plays just fine with Swift. Whatever.

I tried to keep it as familiar feeling as I could but some things had to be tweaked slightly. 

It's called GMDB for two reasons:
- G comes after F
- Gus Mueller wrote the original

**Version 0.1.1** — consider this a starting point, not a finished product.

## Known Limitations

When running all tests in the suite some will fail. If run individually all of the pass however. Not sure what's going on there since they are serialized.

Some things from FMDB aren't (yet) supported:

- Formatted updates and related conveniences
- Likely other things that haven't surfaced in testing yet

## Installation

Add GMDB to your `Package.swift`:

```swift
.package(url: "https://github.com/somegeekintn/GMDB", from: "0.1.1")
```

## Credits

All credit for the original design and years of SQLite wrangling goes to [Gus Mueller](https://github.com/ccgus) and the FMDB contributors. This is just a Swift-flavored tribute.

## License

MIT
