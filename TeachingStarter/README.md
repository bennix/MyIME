# MyIME Teaching Starter

This Swift package contains interfaces, fixtures, and smoke tests—not the MyIME
1.0.10 solutions. Follow `CURRENT_LAB.md` on the assigned `labN-starter` branch.

Run the baseline before editing:

```sh
swift test --package-path TeachingStarter
```

The package deliberately keeps InputMethodKit/AppKit adapters thin. Implement and
test pure state, search, scoring, persistence, and evidence models here first; then
connect them to the macOS app target described by the textbook.

For a graded class, import the assigned starter branch into a separate private
GitHub Classroom template. Branches in a public repository prevent accidental
spoilers, but cannot prevent a student from intentionally browsing `main`.
