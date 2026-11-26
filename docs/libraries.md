# Libraries

I'd like to introduce a core iris concept of "Libraries".

## Iris' Library

We have already stipulated that iris will keep its own documents in 'OKF' format.  In addition
to the stick 'memories' and USER.md and such, actual permanent documents should be written to
~/.iris/memory/library/ typically in OKF markdown format.

This would be things like postmortems, lessons-learned, recipes to save, plans, instructions, 
itineraries, drafted emails, or any other artifact that iris decides to or is instructed to
create or save.  This is a permanent archive of information, work, learnings, snippets, etc.

Iris is responsible for categorizing and organizing this library in whatever way makes sense
to it.  As an example, here is a directory structure curated by multiple house bots in a
different library:

```
$ find . -type d -maxdepth 3 | grep -v \.git
.
./rune
./rune/journal
./rune/inbox
./rune/identity
./rune/scratch
./rune/scratch/cve_inventory
./rune/actual-mcp-server
./rune/actual-mcp-server/generated
./rune/actual-mcp-server/docker
./rune/actual-mcp-server/types
./rune/actual-mcp-server/test-data
./rune/actual-mcp-server/bin
./rune/actual-mcp-server/node_modules
./rune/actual-mcp-server/tests
./rune/actual-mcp-server/.claude
./rune/actual-mcp-server/docs
./rune/actual-mcp-server/examples
./rune/actual-mcp-server/scripts
./rune/actual-mcp-server/src
./rune/proposals
./agent-identity-kit
./agent-identity-kit/DOCS
./agent-identity-kit/DOCS/superpowers
./agent-identity-kit/inspiration
./clomp
./clomp/journal
./clomp/inbox
./clomp/identity
./clomp/scratch
./common
./common/code-reviews
./common/code-reviews/approved
./common/code-reviews/pending
./common/coordination
./common/coordination/tasks
./common/coordination/signals
./common/coordination/history
./common/coordination/registry
./common/coordination/skills
./common/archive
./common/archive/coordination
./common/archive/skills
./common/archive/protocols
./common/plugins
./common/plugins/nats-inbox
./common/projects
./common/projects/archive
./common/projects/backlog
./common/projects/drafts
./common/projects/hermes-memory
./common/projects/active
./common/roundtable
./common/roundtable/instructions
./common/skills
./common/skills/pre-upgrade-backup
./common/skills/agent_skills
./common/infrastructure
./common/infrastructure/k8s-configs
./common/infrastructure/nodes
./common/infrastructure/clusters
./common/infrastructure/networks
./common/infrastructure/scripts
./common/infrastructure/services
./common/hermes-roundtable
./common/hermes-roundtable/history
./common/hermes-roundtable/active
./common/protocols
./common/omgs
./scromp
./scromp/discord
./scromp/inbox
./scromp/inbox/budget
./scromp/archive
./scromp/archive/2026-06-01
./scromp/archive/2026-06-22
./scromp/archive/2026-06-21
./scromp/scratch
./scromp/proposals
```

I would encourage *some* kind of structure rather than a flat document dump, 
but I leave the specifics up to iris.

## External Libraries

### Romar Agents

In addition to Iris' own library, Iris can be pointed to external libraries with
different characteristics.  As mentioned above, there is a shared house OKF library
(called 'agents') that Iris could index and absorb or reference.  Iris might create an
`agents/iris/` subdirectory for publishing shared documents, or access `agents/scromp/inbox`
on my behalf to push things to other bots, etc.

### Work notes

My work notes would be another example of an external library, and is one of the main
reasons Iris exists.  This would be fully curated by Iris as a Librarian - when I drop
new notes in there, Iris would pick them move, process them, categorize and move them,
use them to generate other actions/tasks, etc.

### Read-only Libraries

It may also be useful to point Iris at other libraries that are not meant to be curated,
but are just sources of information.  This might not even be OKF, but could house a
variety of document types - even images, slides, etc.

### How a library's notes are checked

A folder of your own notes, such as an Obsidian vault, can be added under Settings → Security → Libraries.
Its notes are still outside text for the guard, and reading one still marks the conversation. The setting
only chooses who runs tier 3: "On this Mac" (the default: the guard check runs on this Mac, so no second
cloud provider sees the note), "Cloud" (the note is also sent to the canary's provider, which can differ from the chat provider, for a
vault that is scanned there anyway), or "No check". Either way a note still goes to your chat model when Iris reads it.
Only a `read_file` is matched to a library: a note printed by `run_command` (`cat`, `grep`) is checked by
the global tier-3 engine. A note judged safe is remembered across launches, so it isn't checked again until it
changes, the guard's settings or this library's setting change, or 30 days pass ([verdict cache](prompt_injection_guard_design.md#verdict-cache-tier-23)). Only Settings changes it; the registry below does not. See the guard's [per-library bullet](prompt_injection_guard_design.md#tier-3-auxiliary-model-classifier-probe-implemented).

## Indexing

To keep track of the external libraries that Iris knows about, Iris should maintain an
index file in ~/.iris/memory/library/EXTERNAL_LIBRARIES.md which will track the location
of the libraries and their corresponding traits.

### Traits

A not-necessarily-inclusive list of traits a library might have:
- read-only, read-write
- curated-by-iris
- shared
- intermittent-sync
- owner(s)
- purpose, topic
- convert-to-okf
- ..probably others?

We should choose safe defaults for these (non-destructive) and only change them when instructed.

## Skill

We should create a library access, library management skill for Iris to reliably 
manage her own library as well as how to interact with others she's meant to access
or curate.  It should encourage Iris to contribute to the library/libraries as 
appropriate.

We'll ship this skill and a bare ~/,iris/memory/library/ directory as this is intended
to be a core feature of the agent.  Maintaining libraries is a primary function.
