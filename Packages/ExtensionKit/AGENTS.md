# Agent Instructions for extension-kit

## Product Strategy (2026-09-29)

Extensions/plugins are a development mechanism only. The final product has no user-facing extension concept: content capabilities ship with foofoil, without separate installation, enablement, or updates. Keep internal module boundaries and existing ABI/type names where useful; they do not imply a public plugin platform or independent release compatibility promise. Do not plan a Registry, marketplace, or Extension Manager as a product feature. Management code/UI remains available for future reuse, but the app hides its entry points and disables startup update checks and installation prompts. Do not delete the underlying extension implementation merely to hide the product concept. The app’s `./run` embeds sibling Hi-Fi and EPUB modules for Debug; `./package-dmg` embeds them for Release distribution.

## Project Overview

extension-kit provides shared internal contracts for foofoil development modules. It is a Swift package, not an app.

It owns Extension API v1 contracts: the versioned C ABI, Manifest schema, capability identifiers, `ContentRequest` / `ContentSession` value types, navigator and media snapshots, compatibility fixtures, and contract tests.

Host loading, installation, the Extension Registry client, and UI belong in `foofoil`. Capability implementations such as Hi-Fi belong in their own repositories. Do not move those concerns into this package.

The current internal binary boundary is the C ABI (`foofoil_extension_create`) and JSON value messages. Swift protocols, SwiftUI views, `NSView`, and in-process objects are not part of the shared module API.

## Core Principles

1. **Keep the kit small.** Add only contracts, schema, fixtures, and tests that extensions and the host actually share.
2. **Prefer Apple frameworks.** Use Foundation and existing value types. Do not add a third-party dependency unless native APIs cannot meet the requirement.
3. **Preserve ABI and decoding compatibility for released contracts.** This applies to the public C ABI and versioned contracts that hosts and extensions actually consume; it does not require reviving unreleased P0 private `hifi.*` command protocols, which are closed. New Codable fields must decode as optional with sensible defaults. C function-table fields may only be appended; callers must check struct size and function pointers.
4. **Prefer incremental change.** Reuse existing types and validators. Keep diffs focused.

## Architecture

- Put the C header and its compilation unit in `FoofoilExtensionABI`. Put Swift contracts and validators in `FoofoilExtensionKit`.
- Keep types `public` with `public` initializers when they are part of the package API.
- Capability identifiers and contract versions are stable names. Do not rename them to match a single extension domain.
- `min` / `max` Extension API ranges are valid only when every version in between is compatible.
- Do not add host-only types (loaders, installers, registry clients, SwiftUI views) here.
- Preserve existing documentation comments. Add concise Chinese comments for ABI, negotiation, or decoding rules that are not self-evident. Do not comment obvious code.

## Dependencies and Assets

- This package is distributed under the MIT License. New code and assets must be distributable under that license.
- The default decision for a new third-party dependency is **no**.
- Do not commit `.build/`, DerivedData, test artifacts, or machine-specific project state.

## Testing and Verification

- Add or update focused tests for Manifest validation, request/session encoding, capability negotiation, navigator and media contracts, and ABI layout.
- Use the Swift Testing framework under `Tests/FoofoilExtensionKitTests`.
- Run before considering a change complete:

  ```sh
  swift test
  ```

- Treat new warnings as defects. Do not silence warnings without addressing or documenting the underlying reason.

## Change Discipline

- Inspect surrounding types, schema, and fixtures before editing so they stay consistent.
- When creating a file with a `Created by` header, use the human identity returned by `git config user.name`. Never use an agent, model, assistant, or tool name.
- Preserve unrelated user changes in the working tree.
- Do not raise the package's minimum macOS version or change product/module names unless the task explicitly requires it.
- Do not add analytics, telemetry, remote processing, or network services.

## Git Commit Guidelines

- Write commit messages in English.
- Follow Conventional Commits and keep the subject concise, for example: `feat: add media playback snapshot fields`.
- Keep each commit focused on one coherent change and do not include generated or unrelated files.
