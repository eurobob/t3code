import type { OrchestrationThread } from "@t3tools/contracts";

import { limitSection } from "./TextGenerationUtils.ts";

const MESSAGE_BUDGET = 32_000;

function formatMessage(message: OrchestrationThread["messages"][number]): string {
  return `${message.role.toUpperCase()} (${message.createdAt}):\n${limitSection(message.text, 8_000)}`;
}

function formatMessages(thread: OrchestrationThread): string {
  const formatted = thread.messages.map((message) => ({
    id: message.id,
    text: formatMessage(message),
  }));
  const fullTranscript = formatted.map(({ text }) => text).join("\n\n");
  if (fullTranscript.length <= MESSAGE_BUDGET) {
    return fullTranscript || "(no messages)";
  }

  const firstUser = formatted.find((_, index) => thread.messages[index]?.role === "user");
  const recent: Array<(typeof formatted)[number]> = [];
  let remaining = MESSAGE_BUDGET - (firstUser?.text.length ?? 0) - 64;
  for (const message of formatted.toReversed()) {
    if (message.id === firstUser?.id) continue;
    if (message.text.length > remaining && recent.length > 0) break;
    recent.push(message);
    remaining -= message.text.length + 2;
    if (remaining <= 0) break;
  }

  return [
    ...(firstUser ? [firstUser.text] : []),
    "[Earlier messages omitted]",
    ...recent.toReversed().map(({ text }) => text),
  ].join("\n\n");
}

export function buildTaskSummaryContext(input: {
  readonly thread: OrchestrationThread;
  readonly projectTitle: string;
}): string {
  const { thread } = input;
  const activities = limitSection(
    thread.activities
      .filter(
        (activity) =>
          activity.tone === "approval" ||
          activity.tone === "error" ||
          activity.kind.includes("user-input") ||
          activity.kind.includes("plan") ||
          activity.kind.endsWith(".failed"),
      )
      .slice(-40)
      .map((activity) => `- ${activity.createdAt} · ${activity.kind}: ${activity.summary}`)
      .join("\n"),
    6_000,
  );
  const plans = limitSection(
    thread.proposedPlans
      .slice(-3)
      .map(
        (plan) =>
          `- ${plan.implementedAt === null ? "proposed" : "implemented"}: ${limitSection(plan.planMarkdown, 4_000)}`,
      )
      .join("\n"),
    8_000,
  );
  const checkpoints = limitSection(
    thread.checkpoints
      .slice(-5)
      .map((checkpoint) => {
        const files = checkpoint.files
          .slice(0, 40)
          .map((file) => `${file.path} (+${file.additions} -${file.deletions})`)
          .join(", ");
        return `- ${checkpoint.completedAt} · ${checkpoint.status}: ${files || "no file changes"}`;
      })
      .join("\n"),
    8_000,
  );

  return [
    `Project: ${input.projectTitle}`,
    `Task title: ${thread.title}`,
    `Current turn state: ${thread.latestTurn?.state ?? "none"}`,
    `Session status: ${thread.session?.status ?? "not bound"}`,
    "",
    "Messages:",
    formatMessages(thread),
    "",
    "Pending/relevant activity:",
    activities || "(none)",
    "",
    "Plans:",
    plans || "(none)",
    "",
    "Recent checkpoints:",
    checkpoints || "(none)",
  ].join("\n");
}
