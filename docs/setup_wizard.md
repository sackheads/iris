# setup wizard

The first-time experience is getting a little harried.  Popping up the settings when
we don't find anything set up is fine, but it's not obvious now what people need to
do with all these model downloads especially.

Let's create a first-time-use setup wizard flow that walks people through the setup
gently and explains a few things.

## Proposed sequence
1. light/dark/system theme.  do we even have themes yet or is it always dark? :D
2. Markdown or plain text copy defaults, global hotkey.
   - this is more to advertise the sweet markdown mode honestly
3. Google creds
   - test connections?
4. Base model - gemini/anthropic/openai, urls, keys, etc.
   - Just let them pick one, but say "You can revisit this later in settings"
   - click to test connection, error/retry on failure
5. Vibecop : explain what it does, enable/disable,
     give a few default models *and tell them accurate disk sizes*
   - Default options: Gemma 4 E2B (~3.1GB, fast), Gemma 4 12B (~7.4GB, heavy).
   - Gemma 4 12B is ~7.4GB, not 1-2 — always show accurate sizes.
   - execute the download
6. Prompt injection protection: enable/disable, explain what it does.
   - model defaults or they can add their own urls/model names
   - include model sizes
   - execute the download
7. Sandboxing: explain what it does, requirements, enable/disable

Save all of these chosen options to the settings.

