# Tuning the Iris use cases

## Intro discussion: Brian & Planner

### brian

❯ The pub/sub feature got kinda quietly built in the night a while ago without much fanfare.  What can we actually do
  with it?  What are its most salient features?  What is it used for today?

### planner

Pub/sub topics (#696, shipped in commit 9b9063f8)

  It's cross-session topic messaging layered on the existing peer-messaging plumbing (send_to_session, the peer ledger,  rate limiter, guard). Crucially, it added no new tool — it's two small extensions to tools that already existed.

  What you can actually do

  - Subscribe by listing topic names in your session card: set_session_card gained a topics field (≤8 names,
    [a-z0-9-]{1,32}). Peers then see topics: dev,ops next to you in list_sessions.
  - Publish with send_to_session addressed to to: "topic:<name>" — a fourth address form beside session-id, role: and name:. One call fans out to every other subscriber. You must be subscribed yourself to publish, so every broadcaster is visibly a listed member.
  - A topic isn't "created" or approved by anyone — the first subscribe brings it into being; it exists while someone's
    subscribed or a message is still retained.

  Most salient features

  - One send instead of N. That's the entire value proposition — fewer calls for the publisher. Subscribers still each
    get a turn (an idle one is woken, a busy one queues it), so it does not save subscriber work.
  - Ordering + catch-up. Per-topic sequence numbers; a late subscriber gets the last 5 messages from the past 24h once, marked (history). Retained 50/topic, 7 days (SQLite table, migration v34_topic_messages).
  - Anti-storm design, which is the interesting engineering. Two rules stop a broadcast becoming 400 wakes: (1) a turn that a topic message started cannot itself publish to a topic (it can only reply privately to the publisher or
    direct-send); (2) a publish costs one rate-token per subscriber reached — a 20-subscriber blast spends the whole 20-send budget and the next waits ~5 min.
  - Trust model. A topic message is peer text, never treated as the user's. Guard-judged once at publish (tier 3,
    peer_topic, charged to the publisher); a withheld message reaches nobody and is stored nowhere (fail-closed). A
    subscriber that reads one is marked touched-by-unattended-input, and the header flags when the publisher had read outside content (#813).
  - Hard limits: ≤20 subscribers, ≤2 KB body, no in_reply_to/expects_reply/attachments on a topic message (replies go privately to the publisher). Global to one Mac — no cross-machine, no per-workspace scoping, no private/ACL'd topics, no edit/retract (all explicitly deferred).

 What it's used for today — the honest answer: effectively nothing yet.

  I want to be precise here rather than sell it:

    1. It's a feature of the Iris app, between conversations running inside one Iris instance on one Mac. That is not how
       this team (Overseer/planner/devs) talks — we're separate Claude Code CLI sessions wired through the c2c ferry
       (/tmp/cc-socks sockets, which also crosses machines). Iris's send_to_session/topics and the ferry are different
       mechanisms; topics doesn't touch our coordination at all.
    2. You aren't running Iris for real yet (the #817/#813 read-out is still parked on exactly that). So no live Iris
       multi-session team is exercising it.

  The designed use — and the thing that motivated #696 — is literally our own pattern: the Overseer broadcasting a
  decision or warning to every dev in one call instead of one-at-a-time. If you ever run the overseer+devs team inside
  Iris rather than as CLI sessions, topics is the one-call broadcast for that. Until then it's tested capability sitting
  ready, not something in production use.

  One thing worth flagging: it was built straight from a spec marked "proposal, no code," so it's a complete, tested
  implementation of an unused feature. That's fine as pre-built capability, but it's worth a conscious decision whether
  the in-app session team is a direction you actually want, or whether the ferry is the real substrate and Iris's own
  send_to_session layer is speculative.

  On pub/sub: the short version is it's a well-engineered, fully-tested broadcast layer inside the Iris app that nothing
  currently uses, because the team that would use its motivating pattern (Overseer→devs) runs over the c2c ferry outside Iris, and you're not running Iris for real yet. Worth deciding deliberately whether in-app session teams are a real direction or whether that whole send_to_session layer is speculative — happy to dig into either if useful.

### brian

❯ your description is dead on, and that's the main use case (in-iris overseer-style teams).  c2c is really just for
  firing jobs to work mostly, the bulk of what happens here is still local to this mac.  I am thinking of extending the
  use case, so that's why I was asking.

### planner

Good — that's settled before any code gets written. Now your extension idea.

The honest read on where pub/sub leaves you: it's the broadcast primitive for an in-Iris team, but it's one piece, and the gaps between "tested capability" and "a substrate a team actually runs on" are the interesting part:

- No acks or receipts. A publish is fire-and-forget wake — the Overseer can't know a dev received a decision, only that it sent. Our CLI team papers over this with explicit reply-and-report discipline; an in-Iris Overseer has no equivalent unless subscribers are expected to in_reply_to every broadcast (which the breadth rule half-discourages).
- No oversight surface inside the app. The thing that makes our team legible to you isn't send_to_session — it's the Overseer's dashboard.html and rules.md. In-Iris you'd have list_sessions + session cards and nothing that rolls up "who's doing what, what's blocked, what needs you." That's the piece you'd actually feel the absence of.
- One-Mac ceiling is baked in. Fine while the bulk is local — but it means work can never be a team member, only a job target over c2c. If the extension ever wants a remote session in the loop, topics can't carry it (cross-machine was explicitly deferred).

The sharper question underneath this, and the one that changes what I'd actually recommend building: [[iris-two-use-cases]] — your own framing — is second-brain vs. software-factory, with the standing invariant that the factory must not tax the second-brain. Extending in-Iris teams pushes hard on the factory side and puts orchestration machinery (roles, dispatch, oversight UI, broadcast storms) into an app that's 95% your personal assistant. That's not a reason not to — it's a reason to decide deliberately which identity this serves before it grows a control plane.

So, to not speculate across the whole space: what's the shape you're picturing — autonomous sessions coordinating with each other (goal loops that hand work off and broadcast status without you in the loop), or a human-in-the-loop team like ours, but inside Iris (you as the Brian-equivalent, an in-app Overseer, a dashboard)? Those need almost disjoint things next, and I'd rather pressure-test the one you mean than hand you a survey. If you want to go deep on it, I'd run it through brainstorming properly rather than freehand a design here.

## Reframing

I think in the series of feature bugs I haven't done a good job of fully describing how I intend to use iris, so let me describe a few things that may amount to a slight tweak of interpretation (re the above assertions):

* The main ("pinned") Iris session ("Iris") is the primary agent that I talk to for all kinds of things:
  * Second brain stuff
  * email, calendaring, todo lists, file management, research, etc
  * overall iris-app concerns (visibility into all sessions, agents)
  * The reason we leave some headroom for this agent is just because it's the main one I'll talk to most of the time; it's like `Clomp` in the home lab bot space - my majordomo, but here on the mac and with different access rights and patterns.
* I'll create separate conversations for random reasons, just generic iris agents
* I'll also create Overseer-like squads to work in the style of the current Overseer teams
* I will also create completely new agent profiles that exist outside of either of these paradigms.  Who knows yet?

While I will definitely have an "Overseer" keeping things on track in this spin of the idea - if for no other reason than to keep Iris' context clean - Iris should be able to answer questions about what the other agents are doing and understand the hierarchy.  She should be able to broadcast or message the Overseer to guide things.

I'm mentally leaning on pub/sub a bit for this; activity/status/question notifications can be published, Iris can see them, but unless there is some standing order or question from me, it doesn't demand immediate action.  "Noted."

So it's not so much a split-brain use case "iris" and "not iris", it's more that there's an extended hierarchy, or a dotted-line reporting scheme with Iris at the top.

Iris can be somewhat like the "Director" in Grain - https://github.com/ai-on-gke/grain

## Following on from that..

- I think we need to loosen the cap on pub/sub subscriptions.  <20 might be a bit tight.
- It seems like having an 'ack' with parameters ("ack: working on <foo> first") would cut down on the overhead by a lot.
- I think the durability/replay capacity we have today seems sufficient

### The "Not Using Iris" Note

When the team was seeking some usage information from my daily use of Iris, I made it clear that wasn't happening yet.  I've been quite busy at work and in life and have multiple harnesses running in both places, so there hasn't been a lot of room for Iris lately.  I'm going to change that soon, so let's not bake in "he doesn't use Iris" as a foundational theme.  I think we're getting to the point with all the performance work and bug fixes that it should start being usable for actual work soon, if not already.

## One more thing

This is a completely different feature, but let's work it in (can be a separate issue/epic).

Another awesome idea from Grain that I want to steal immediately is the "Inbox".  This is a mail-like interface that collects all the "items for Brian" that bubble up from agents.  Instead of having to repeatedly query the overseer about what's waiting on me, and ask it to explain things in more detail, and we get confused about which question I said "A" to..  All of that flows intead into the Inbox.  This can be a separate row beneath the main Iris that opens a mailbox view.

In that mailbox view there is a separate item for each pending question that describes it in full, explains the problem and the options, pros/cons, provides me with options to choose (or a free-form response if I don't like the options).

I can click 'Submit' to send the reply directly back to the interested parties (presumably Overseer, Asking Agent, maybe Planner - their profiles will guide this).  That clears the item from my active inbox.  If follow-up questions arrive, they are either appended and it resurfaces, or there is a link to the prior item (for context.)

These could also just be notifications - "I made a call for you, let me know if it needs to change" or "This decision was made, veto it by xx:yy:zz".  I can either respond to those or click 'Approve' or 'Dismiss' or something to mark it complete.

With this system, we don't really need to play the "telephone" game of agent -> planner -> overseer relay.  The agent with the question can simply publish its question to the inbox's input topic.  The interested meta-agents can subscribe to that too just to be aware.  The replies go right back to the interested targets.
