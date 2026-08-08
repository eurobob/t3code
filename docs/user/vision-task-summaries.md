# AI task summaries in T3 Vision

T3 Vision opens each task in Conversation view. Turn on the global **Show
Summary** control to open an AI brief beside the conversation. The brief answers
three questions:

- What did you ask for?
- What was done?
- Is a decision or action waiting on you?

The T3 server generates the brief from the task's messages, relevant status
events, plans, and recent checkpoints. It uses the text-generation model chosen
in T3 Code Settings, so selecting Claude Sonnet there also selects it for task
summaries.

Opening the panel generates a summary from the conversation as it currently
exists, even while an agent is working. That snapshot remains stable while the
turn streams, then refreshes when the turn finishes. Summaries are cached locally
per environment and task revision for fast context switching. Use the refresh
button to regenerate one manually. Exact approval or input requests continue to
come from live task state.

The summary setting applies across the task workspace rather than to one task.
When enabled, switching tasks keeps the summary panel open and refreshes it for
the selected conversation. Opening the panel also widens the visionOS window so
the task sidebar, conversation, and summary retain comfortable reading widths;
closing it restores the compact conversation window.
