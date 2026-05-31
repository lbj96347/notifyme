# Repository Guidelines

## Project Structure & Module Organization

NotifyMe is split into a Flutter client and Firebase backend. `flutter_app/` contains the mobile app; feature code lives under `lib/features/`, shared models/enums under `lib/shared/`, app shell code under `lib/app/`, and Flutter tests under `test/`. `firebase_functions/` contains TypeScript Cloud Functions in `src/`; compiled JavaScript is emitted to `lib/` and should be treated as build output. Firebase project configuration and rules are at the repository root (`firebase.json`, `firestore.rules`, `firestore.indexes.json`). Product and setup documentation live in `docs/`, and webhook sender examples live in `examples/`.

## Build, Test, and Development Commands

Run Flutter commands from `flutter_app/`:

- `flutter pub get` installs Dart dependencies.
- `flutter analyze` runs the configured Flutter lints.
- `flutter test` runs widget/unit tests.
- `flutter run` launches the app on a connected device or simulator.

Run Functions commands from `firebase_functions/`:

- `npm install` installs Node dependencies.
- `npm run build` compiles TypeScript to `lib/`.
- `npm run lint` checks TypeScript style.
- `npm test` builds and runs `node --test lib/*.test.js`.
- `npm run serve` starts the Functions emulator; `npm run emulators` starts all configured emulators.

## Coding Style & Naming Conventions

Flutter uses `package:flutter_lints/flutter.yaml`; keep Dart files formatted with `dart format .` and use `snake_case.dart` filenames. Prefer feature-local services, repositories, screens, and models inside their matching `lib/features/<feature>/` directory. Functions use TypeScript, Node 20, ESLint, double quotes, and `@typescript-eslint/recommended`; keep source in `src/` and avoid editing generated `lib/` files by hand.

## Testing Guidelines

Place Flutter tests in `flutter_app/test/` with `_test.dart` suffix. Place Functions tests beside source in `firebase_functions/src/` with `.test.ts` suffix; the build step generates runnable `.test.js` files. When changing the webhook payload contract, update validation tests, Flutter model parsing, and all relevant examples.

## Commit & Pull Request Guidelines

Git history is not available in this checkout, so use short imperative commit subjects such as `Add webhook validation tests` or `Update inbox empty state`. Pull requests should describe the user-visible change, list test commands run, link related issues, and include screenshots or screen recordings for Flutter UI changes. Note any Firebase setup, rules, index, or emulator changes explicitly.

## Security & Configuration Tips

Do not commit real Firebase credentials or generated `firebase_options.dart`; use `flutter_app/lib/firebase_options.dart.example` as the template. Keep Firestore rules scoped to authenticated user `uid`s, and keep the webhook contract synchronized across Functions, Flutter, docs, and `examples/`.
