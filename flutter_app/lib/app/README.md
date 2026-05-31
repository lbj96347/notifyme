# app/

App-level composition: the root `MaterialApp`, theming, routing, and
top-level Firebase/auth state wiring. Things that are about *the app as a
whole* rather than any single feature live here.

Currently the root widget (`NotifyMeApp`) still lives in `lib/main.dart`;
move it here when the app grows beyond the placeholder scaffold.
