# Auxiliary Models Framework Design

## Overview
Iris requires small, dedicated local models (Auxiliary Models) to perform fast, specialized background tasks without burning primary cloud API tokens, incurring network latency, or compromising security.

**Primary Use Cases:**
1. **Vibecop ("Smart Approval")**: Evaluates commands/actions proposed by the primary model to automatically approve safe actions or block dangerous ones (e.g., using Gemma 4 12B or Gemma 4 E2B).
2. **Prompt Injection Guardian**: A fast classifier or heuristic model to analyze user input for adversarial attacks (Tiers 2 & 3 of the security model).

---

## Execution Backend: Pros & Cons Analysis
Since Iris is a native macOS application, we need to embed a local inference engine. We will also build the interface to optionally support an external Ollama daemon if the user is already running it, but embedding is the primary goal.

The two strongest candidates for native Swift execution are **`llama.cpp`** and **`mlx-swift`**.

### Option 1: Embedded `llama.cpp` (via Swift Package)
`llama.cpp` is the industry standard for CPU/GPU cross-platform inference, heavily optimized for Apple Silicon via Metal.

**Pros:**
*   **Massive Ecosystem**: Unrivaled support for `.gguf` quantized models. Every new model is immediately quantized and uploaded to HuggingFace in GGUF format.
*   **Robustness & Features**: Extremely stable, widely tested, and supports advanced sampling, speculative decoding, and strict grammars (highly useful for forcing Vibecop to output strict JSON).
*   **Memory Efficiency**: Excellent `mmap` support for loading huge models from disk without duplicating memory.

**Cons:**
*   **C++ Interop**: Requires bridging C++ to Swift. While Swift packages exist, it adds a C++ dependency layer to a pure Swift project.
*   **Not "Pure Apple"**: Built as a cross-platform tool; it doesn't take intrinsic advantage of high-level Swift/Apple framework paradigms.

### Option 2: Apple `mlx-swift`
Apple's official machine learning framework designed specifically for Apple Silicon.

**Pros:**
*   **Native Ecosystem**: A "Pure Apple" solution. Deeply integrated with macOS and Swift.
*   **Performance**: Bleeding-edge optimizations directly from Apple engineers for M1/M2/M3/M4 chips.
*   **Future-Proof**: Highly likely to become the absolute standard for on-device Apple ML over the next few years.

**Cons:**
*   **Format Fragmentation**: Uses MLX-specific weights (e.g., `.safetensors` converted to MLX format). It does not support standard `.gguf` out of the box, requiring conversion scripts or finding specific MLX ports on HuggingFace.
*   **Ecosystem Immaturity**: The library and Swift wrappers are newer and evolving rapidly, which could lead to API churn.
*   **Quantization Scarcity**: While it supports quantization, the ecosystem of pre-quantized MLX models on HuggingFace is vastly smaller than the ocean of GGUF models.

### Recommendation
For the initial implementation, we will build around **Embedded `llama.cpp`** due to its mature Swift bindings, strict grammar support (critical for deterministic Vibecop decisions), and universal GGUF support. This allows us to easily fetch and run almost any model directly off HuggingFace. 

We will abstract the engine interface (`protocol AuxiliaryInferenceEngine`) so we can easily swap to `mlx-swift` in the future if the MLX ecosystem reaches parity with GGUF, or fall back to an external **Ollama** REST API if the user configures it.

---

## Model Lifecycle & Management

### The `AuxiliaryModelManager`
We need a dedicated subsystem to handle the lifecycle of these heavy assets, storing them locally in `~/.iris/models/`.

*   **Registry (`models.json`)**: Tracks installed models, their file paths, file sizes, and assigned roles.
*   **Downloader**: A background `URLSession` queue that streams models directly from HuggingFace.
*   **Memory Management**: Models are hundreds of megabytes or gigabytes. The manager loads them into memory lazily when their specific role is invoked, and unloads them (or relies on macOS memory compression/mmap) when idle. The exceptions are the prompt guard's tier-3 canary and Vibecop: when protection or Vibecop is on with an Ollama or llama.cpp engine, the app builds that engine at launch, so the first prompt doesn't pay the model's cold load (#792). MLX is left to first use, since its load can download the model. The model is then resident from launch, and Ollama still unloads it after five idle minutes.

### UI Configuration
A new **Local Models** tab will be added to `SettingsView`:
*   **Role Assignments**: Dropdowns to assign specific models to specific roles (e.g., Vibecop, PromptGuard). Includes an "Ollama API" override option.
*   **Download Hub**: A UI to browse a curated list of recommended models (with sizes), enter custom HuggingFace URLs, and monitor download progress.
*   **Storage Management**: A list of downloaded models showing file sizes, with a trash can icon to delete unused files and reclaim SSD space.

---

## Integration Hooks

*   **Vibecop**: Hooked into `AppState.requestApproval`. Before popping the UI dialog, Iris queries the Vibecop auxiliary model with the proposed command and system context. If the model replies `APPROVE`, it bypasses the UI, but on the host only for a read (`ReadOnlyCommand.vibecopMayApprove`), and never for a command once the person has denied one in that conversation (#600).
*   **PromptGuard**: Hooked into `HookManager.fireBeforeAgent`. The PromptGuard model scans incoming text. If it classifies it as malicious, it returns `.block` before the primary LLM even sees the request.
