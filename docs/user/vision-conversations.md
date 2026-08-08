# Conversations in T3 Vision

Selecting a task opens its full conversation and keeps it live while the agent
works. T3 Vision keeps recently viewed conversations in memory for the current
environment, so switching back to a task restores its transcript immediately
instead of showing another loading screen.

The app resumes live updates from the cached conversation's last known position.
If the server can no longer replay from that position, it replaces the cache with
a fresh conversation automatically. First visits and conversations outside the
recent cache still load from the server.
