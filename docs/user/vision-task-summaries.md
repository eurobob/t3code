# AI task summaries in T3 Vision

T3 Vision opens each task in Summary view. The brief answers three questions:

- What did you ask for?
- What was done?
- Is a decision or action waiting on you?

The T3 server generates the brief from the task's messages, relevant status
events, plans, and recent checkpoints. It uses the text-generation model chosen
in T3 Code Settings, so selecting Claude Sonnet there also selects it for task
summaries.

Summaries refresh after a running turn finishes and are cached locally per
environment and task revision for fast context switching. Use the refresh
button to regenerate one manually. While a turn is running, the previous brief
remains visible and exact approval or input requests continue to come from live
task state.

Use the Summary/Chat switch in the task header to open the full conversation.
T3 Vision remembers that choice separately for each task; new tasks default to
Summary.
