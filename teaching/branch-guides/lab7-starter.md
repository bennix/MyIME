# Lab 7 starter — Word lattice and Beam Search

Implement configurable Beam Search over `LatticeEdge`. Keep `lastWord` in the
hypothesis state. On a tiny lattice, compare against complete enumeration; then
report top-1/top-5 and P50/P95 for widths 2, 4, 8, 12, and 24.
