---
type: "design"
title: "Sandboxed Web Search Architecture"
description: "Documents the rationale and implementation details of the sandboxed web search capability in Iris."
tags: ["security", "sandboxing", "tools", "web_search", "python"]
timestamp: "2026-07-10T19:05:00Z"
---

# Sandboxed Web Search Architecture

When building autonomous agents, granting them unfiltered access to the web introduces a massive surface area for [Prompt Injection](prompt_injection_guard_design.md) and untrusted data execution. If a web parser has a vulnerability, or an LLM is susceptible to malicious instructions hidden in HTML (`<untrusted_context>`), the system is compromised.

To mitigate this, Iris implements a natively sandboxed `search_web` tool.

## The Problem with `URLSession`

The most idiomatic way to perform a web search in a native macOS Swift app is to use `URLSession`. However, `URLSession` runs within the same memory space and process as the host application (Iris). If a vulnerability exists in the parsing of the web payload, it could compromise the main Iris process, escaping any constraints.

## The Solution: Python via `apple/container`

Instead of relying on native Swift networking for agent web searches, Iris delegates the task:

1. **Dynamic Script Generation:** When `search_web` is invoked, Iris dynamically writes a zero-dependency Python 3 script (`search_web.py`) to `~/.iris/`. This script uses the standard `urllib` and `html.parser` libraries to scrape the DuckDuckGo Lite endpoint.
2. **Process Execution:** Iris executes this Python script by internally piping it through the standard `runCommand` pipeline.
3. **Sandboxed Execution:** Crucially, if the user has enabled the `apple/container` sandboxing integration, `runCommand` intercepts the process spawn and executes it *inside a lightweight, isolated Linux virtual machine*.

## Benefits

* **Process Isolation:** The parsing of untrusted, adversarial HTML content happens entirely inside the Python process running in a disposable Linux VM.
* **Network Isolation:** The actual outbound TCP connection originates from within the sandbox, which can be firewalled or restricted independently of the host macOS system.
* **Zero Dependencies:** By relying on Python's robust standard library (`urllib` and `html.parser`), we avoid forcing the user to install Node, npm, or complex Ruby toolchains. Python 3 is universally available on developer macOS systems (via Xcode Command Line Tools) and is standard in Linux containers.
* **Tier 1 Synergy:** Once the JSON results are passed back to the host, they are still immediately funneled through the [Prompt Injection Guard](prompt_injection_guard_design.md) to receive their `<untrusted_context>` XML wrappers before reaching the LLM context. Since #235 the guard splits the array first and classifies each result's normalized title and snippet on its own, up to tier 2 — scoring all ten at once made the classifier flag the whole search — then reassembles the survivors under one wrapper, followed by a `[N of M search results withheld by the injection guard]` line when any were dropped. A payload that is not a JSON array of results, such as the script's `{"error": "..."}`, falls back to whole-output sanitization.
