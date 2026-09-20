# Iris Gains Agency

The original inspiration for Iris was based on the fact that I couldn't run Hermes on my work laptop to manage my notes, calendar, etc.  We have built a good harness for active conversations, and took a significant detour into /goal land, but we have yet to actually build an *agent*.

That changes now!

## Feature Arc

This is an "epic".  We'll break these features down into individual deliverables, this doc describes the high-level goals of each piece.

### Main "Iris" Chat

Create a conversation that's pinned to the top of the conversation list.  This is the "DM" with a "root" Iris instance.  Much like my DMs with my Hermes agents, this is the place I talk to Iris a lot of the time and it just is always there, provides a sense of continuity and persistence.

This particular conversation is special because it has proactive access to all the other conversations.  It doesn't necessarily go read them all the time, but it's aware they exist, when they are created, and can search and read them.  Needs to land after #177

### Cron Jobs

A key driver of perceived agency is background processing.  Hermes uses cron jobs to accomplish this, which run in a new session.  This is the obvious implementation for driving background work here as well.  Implement cron jobs for Iris so that she can do things independently of active conversations.  

- Cron jobs should be manageable by Iris herself via normal conversation, same as Hermes
- A UI to view them would be nice
- I do not want these to pop into the conversation list whenever they run, but it would be nice to be able to browse through the session logs and see what happened with them
- These sessions should be similar to conversations in terms of the tools that they have, vibecop configurations, and so on.
- What to do about things the jobs try to do that might invoke approvals?
- Iris should strongly prefer to write deterministic jobs that do not require LLM involvement unless the output of the tool suggests work needs to be done.  Eg, don't burn tokens just checking a resource, let python do that.  When the resource changes, *that* is when the model comes into play.
- The "Main" Iris session is aware of cron job exection and the results of them.  This is a Hermes blind spot that annoys me to death.  It will run a cron job and dump its output in the DM channel and have no idea that it just did that.  I want to be able to discuss the cron job result without having to paste it back fresh.
- Any interesting cron job output should go to (a) default: the DM conversation, or (b) A designated conversation that's configured for that job.

### Watches

Similar to cron jobs watching a resource, arguably not that different, but more efficient and lower latency.  Iris should be able to set up "watches" on resources that trigger processing when those resources change.  Potential watch hooks:

* FSEvents - watch for file changes
* a script that frequently checks HEAD on remote urls, or introspects the content
* ... other ideas - conditionals we can program?