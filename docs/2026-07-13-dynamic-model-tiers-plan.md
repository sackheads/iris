---
title: Implementation Plan for Dynamic Model Tiers
type: plan
status: draft
---

# Implementation Plan: Dynamic Model Tiers

## Step 1: ConfigManager Updates
- Define three new `@Published` or `@Observable` properties: `modelEasy`, `modelMedium`, `modelHard`.
- Set their default values to `gemini-3.1-flash-lite`, `gemini-3.5-flash`, and `gemini-3.1-pro-preview` respectively.
- Ensure they are saved/loaded to/from `UserDefaults`.
- Deprecate or remove the old `geminiModel` property.

## Step 2: SettingsView Updates
- Replace the single `Picker("Model", selection: $config.geminiModel)` with three distinct pickers:
  - "Primary / Medium Model" bound to `$config.modelMedium`
  - "Easy Subagent Model" bound to `$config.modelEasy`
  - "Hard Subagent Model" bound to `$config.modelHard`
- Ensure the `availableModels` array includes the 3.x and 2.5 series.

## Step 3: Architecture Core (ModelTier)
- Define a `ModelTier` enum (`easy`, `medium`, `hard`) in `Models.swift` or `IrisEngine.swift`.
- Update `IrisEngine`'s initializer to accept `modelTier: ModelTier = .medium`.
- Store `modelTier` in `IrisEngine`.

## Step 4: LLMClient Updates
- Determine how `LLMClient` fetches the model name. Currently it probably accesses `ConfigManager.shared.geminiModel` directly.
- Modify `LLMClient` to accept the `modelTier` or a specific `modelName` upon execution or initialization so it knows which model to target.

## Step 5: SubagentManager & Tool Schema
- Update `SubagentManager.runSubagent(role:task:parentConversationId:)` to accept an `effort: String` parameter.
- Map the `effort` string to the `ModelTier` enum and pass it into the new `IrisEngine(state: appState, modelTier: tier)`.
- Update `iris.swift` where `invoke_subagent` is defined to include the `effort` property in its schema.
- Update the execution block in `iris.swift` to extract `effort` and pass it to `SubagentManager`.

## Step 6: System Prompt Heuristics
- Append instructions to `superpowersInstruction` in `iris.swift` clarifying when to use `easy`, `medium`, and `hard` effort levels.

## Step 7: TDD & Build
- Run `swift build` and resolve any missing references to `geminiModel`.
- Run tests.
